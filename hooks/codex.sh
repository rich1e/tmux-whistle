#!/bin/sh
# tmux-whistle 的 Codex CLI hook 适配器。
#
# Codex 在每个生命周期事件点 spawn 本脚本，把事件 JSON 从 stdin 传进来。
# 我们把事件翻译成 whistle 的两条正交通道：
#   @whistle        running / idle / gone
#   @whistle_notice done / wait / error
#
# 退出码恒为 0，stdout 恒为空：
#   · Stop / SubagentStop 在 exit 0 时会把 stdout 当 JSON 解析
#   · 其余事件即使忽略 stdout，也不该让 tmux 的杂音污染 agent 的输出
#
# 事件映射（依据 OpenAI 官方 Codex Hooks 文档，2026-11-13）：
#
#   SessionStart      startup/resume/clear → idle；compact/fork 不动
#   UserPromptSubmit  真正的用户输入 → running，并清掉上一轮未读通知
#   PermissionRequest 等批准 → wait（即时，不依赖 idle_prompt）
#   PostToolUse       工具已跑起来 → 只清 wait，活动态不动
#   SubagentStart     有子 agent 在跑 → 子 agent 标记（推导层合成 running）
#   SubagentStop      子 agent 结束 → 只清标记，绝不动主 agent 的活动态
#   Stop              主回合结束 → idle + done（子 agent 标记仍由推导层处理）
#   Interrupt         用户打断当前回合 → idle，并清掉 wait
#   SessionEnd        Codex 会话结束 → gone
#
# 与 Claude Code 的关键差别：
#   · Codex 没有 Notification / StopFailure，权限等待走 PermissionRequest
#   · Codex 的 Stop 输入没有 background_tasks；子 agent 用独立事件表达
#   · Codex 的 hook 默认同步执行，只有 PostToolUse 设为 async（高频且只清通知）
#   · 新 hook 需要在 Codex 的 /hooks 里审核并信任，安装器无法代做

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WHISTLE_CLI="$WHISTLE_ROOT/bin/tmux-whistle"

# POSIX sh 没有局部变量：本文件所有临时变量统一使用 _cx_ 前缀。

# episodic-memory 用这个稳定前缀标记“给历史会话生成摘要”的临时 Codex
# fork。它不是用户回合，不能进入 pane 状态机，也不能发完成通知。
_CX_INTERNAL_PROMPT_MARKER='Context: This summary will be shown in a list to help users and Claude choose which conversations are relevant'
_CX_QUIET_OPT='@whistle_cx_quiet'
_CX_TARGET_PANE=''
_CX_PANE_SOURCE='none'

# -- tmux 定位 --------------------------------------------------------------
#
# managed daemon 下 TMUX_PANE 可能是启动快照，因此只作为 legacy fallback；
# 默认 strict 模式只信 tmux-whistle-codex 注入的 PaneBinding。
_cx_tmux() {
  if [ -n "${WHISTLE_TMUX_SOCKET:-}" ]; then
    tmux -S "$WHISTLE_TMUX_SOCKET" "$@"
  elif [ -n "${TMUX:-}" ]; then
    tmux -S "${TMUX%%,*}" "$@"
  elif [ -n "${TMUX_SOCKET:-}" ]; then
    tmux -S "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# -- JSON 取值 --------------------------------------------------------------
#
# jq → python3 → sed 逐级降级。顶层字段用于 hook_event_name / source /
# tool_name / message；嵌套字段只用于 PermissionRequest 的
# tool_input.description 与 tool_input.command。
whistle_cx_json_get() {
  _cx_j="$1"
  _cx_k="$2"

  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$_cx_j" | jq -r --arg k "$_cx_k" '.[$k] // empty' 2> /dev/null
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    printf '%s' "$_cx_j" | python3 -c \
      'import json,sys
try:
    v = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else "")' "$_cx_k" 2> /dev/null
    return 0
  fi
  printf '%s' "$_cx_j" | sed -n "s/.*\"$_cx_k\":\"\\([^\"]*\\)\".*/\\1/p" 2> /dev/null
}

whistle_cx_json_nested_get() {
  _cx_nj="$1"
  _cx_na="$2"
  _cx_nb="$3"

  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$_cx_nj" | jq -r --arg a "$_cx_na" --arg b "$_cx_nb" \
      '.[$a][$b] // empty' 2> /dev/null
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    printf '%s' "$_cx_nj" | python3 -c \
      'import json,sys
try:
    v = json.load(sys.stdin).get(sys.argv[1], {}).get(sys.argv[2])
except Exception:
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else "")' "$_cx_na" "$_cx_nb" 2> /dev/null
    return 0
  fi
  # 没有结构化解析器时只做启发式提取。字段名足够独特；转义引号会截断，
  # 但只影响显示，不影响状态写入。
  printf '%s' "$_cx_nj" | sed -n "s/.*\"$_cx_nb\":\"\\([^\"]*\\)\".*/\\1/p" 2> /dev/null
}

# -- 事件日志 ---------------------------------------------------------------
#
# @whistle_debug on 时记录每个事件，且必须在映射之前写 —— 未知事件也要留痕。
# 日志只进文件，绝不进 stdout。

_cx_log_value() {
  printf '%s' "${1:-}" \
    | head -n 1 \
    | tr '\n\r\t' '   ' \
    | tr -d '[:cntrl:]' \
    | tr -s ' ' \
    | sed -e 's/^ *//' -e 's/ *$//' \
    | cut -c "1-80"
}

whistle_cx_log() {
  _cx_evt="${1:-}"
  _cx_json="${2:-}"

  [ "$(_cx_tmux show -gqv '@whistle_debug' 2> /dev/null || true)" = on ] || return 0

  case "$_cx_evt" in
  SessionStart) _cx_key=source ;;
  UserPromptSubmit) _cx_key=prompt ;;
  PermissionRequest | PostToolUse) _cx_key=tool_name ;;
  SubagentStart | SubagentStop) _cx_key=agent_type ;;
  Stop) _cx_key=last_assistant_message ;;
  Interrupt) _cx_key=turn_id ;;
  *) _cx_key='' ;;
  esac

  _cx_val=''
  if [ -n "$_cx_key" ]; then
    _cx_raw=$(whistle_cx_json_get "$_cx_json" "$_cx_key")
    _cx_val=$(_cx_log_value "$_cx_raw")
  fi

  _cx_lf="${WHISTLE_HOOK_LOG:-${TMPDIR:-/tmp}/tmux-whistle-hooks.log}"
  case "$_cx_lf" in
  */*) _cx_dir="${_cx_lf%/*}" ;;
  *) _cx_dir='.' ;;
  esac
  [ -n "$_cx_dir" ] || _cx_dir='/'
  [ -d "$_cx_dir" ] && [ -w "$_cx_dir" ] || return 0

  _cx_log_sid=$(whistle_cx_json_get "$_cx_json" session_id)
  _cx_line="$(date '+%Y-%m-%d %H:%M:%S') [$$] agent=codex hook_event_name=$_cx_evt TMUX_PANE=${TMUX_PANE:-} target_pane=${_CX_TARGET_PANE:-} pane_source=${_CX_PANE_SOURCE:-none} binding=${WHISTLE_CODEX_BINDING:-none} client=${WHISTLE_CODEX_CLIENT:-} session_id=${_cx_log_sid:-}"
  [ -n "$_cx_key" ] && _cx_line="$_cx_line $_cx_key=$_cx_val"
  { printf '%s\n' "$_cx_line" >> "$_cx_lf"; } 2> /dev/null
  return 0
}

# -- 写入封装 ---------------------------------------------------------------

_cx_cli() {
  WHISTLE_SRC=hook "$WHISTLE_CLI" "$@" > /dev/null 2>&1 || true
}

_cx_notice() {
  [ -n "$_CX_TARGET_PANE" ] || return 0
  _cx_tmux show -pqv -t "$_CX_TARGET_PANE" '@whistle_notice' 2> /dev/null || true
}

_cx_clear_wait() {
  [ "$(_cx_notice)" = wait ] || return 0
  _cx_cli --read-pane "$_CX_TARGET_PANE"
}

# -- PaneBinding ------------------------------------------------------------
#
# managed daemon 的 TMUX_PANE 是启动快照。有 binding 时只信 binding；没有
# binding 时按 @whistle_codex_pane_mode 决定 legacy fallback 或 fail closed。

_cx_pane_mode() {
  _cx_pm=$(_cx_tmux show -gqv '@whistle_codex_pane_mode' 2> /dev/null || true)
  case "$_cx_pm" in
  auto | strict | legacy) printf '%s' "$_cx_pm" ;;
  *) printf 'strict' ;;
  esac
}

_cx_valid_pane() {
  _cx_vp="${1:-}"
  [ -n "$_cx_vp" ] || return 1
  _cx_vp_live=$(_cx_tmux display-message -p -t "$_cx_vp" '#{pane_id}' 2> /dev/null) || return 1
  [ "$_cx_vp_live" = "$_cx_vp" ]
}

_cx_resolve_target() {
  _CX_TARGET_PANE=''
  _CX_PANE_SOURCE='none'

  if [ -n "${WHISTLE_CODEX_BINDING:-}" ]; then
    if [ "$WHISTLE_CODEX_BINDING" != v1 ] \
      || [ -z "${WHISTLE_CODEX_PANE:-}" ] \
      || [ -z "${WHISTLE_TMUX_SOCKET:-}" ]; then
      _CX_PANE_SOURCE='invalid'
      return 1
    fi
    if ! _cx_valid_pane "$WHISTLE_CODEX_PANE"; then
      _CX_PANE_SOURCE='invalid'
      return 1
    fi
    _CX_TARGET_PANE=$WHISTLE_CODEX_PANE
    _CX_PANE_SOURCE='binding'
    return 0
  fi

  case "$(_cx_pane_mode)" in
  strict)
    return 1
    ;;
  auto | legacy)
    if _cx_valid_pane "${TMUX_PANE:-}"; then
      _CX_TARGET_PANE=$TMUX_PANE
      _CX_PANE_SOURCE='legacy'
      return 0
    fi
    return 1
    ;;
  esac
  return 1
}

# -- 内部 Codex 会话隔离 ----------------------------------------------------
#
# 后台摘要等 ephemeral fork 与真实交互共用同一个 TMUX_PANE，但拥有独立的
# session_id。记录这些 id 后，Stop / SessionEnd 等后续事件可直接跳过，避免
# 覆盖父会话状态或产生系统通知。

_cx_quiet_ids() {
  [ -n "$_CX_TARGET_PANE" ] || return 0
  _cx_tmux show -pqv -t "$_CX_TARGET_PANE" "$_CX_QUIET_OPT" 2> /dev/null || true
}

_cx_quiet_has() {
  _cx_qh_sid="${1:-}"
  [ -n "$_cx_qh_sid" ] || return 1
  for _cx_qh_id in $(_cx_quiet_ids); do
    [ "$_cx_qh_id" = "$_cx_qh_sid" ] && return 0
  done
  return 1
}

_cx_quiet_add() {
  _cx_qa_sid="${1:-}"
  [ -n "$_cx_qa_sid" ] || return 1
  _cx_qa_ids=$(_cx_quiet_ids)
  for _cx_qa_id in $_cx_qa_ids; do
    [ "$_cx_qa_id" = "$_cx_qa_sid" ] && return 0
  done
  _cx_tmux set -p -t "$_CX_TARGET_PANE" "$_CX_QUIET_OPT" \
    "${_cx_qa_ids:+$_cx_qa_ids }$_cx_qa_sid" > /dev/null 2>&1 || true
}

_cx_quiet_remove() {
  _cx_qr_sid="${1:-}"
  [ -n "$_cx_qr_sid" ] || return 0
  _cx_qr_ids=''
  for _cx_qr_id in $(_cx_quiet_ids); do
    [ "$_cx_qr_id" = "$_cx_qr_sid" ] && continue
    _cx_qr_ids="${_cx_qr_ids:+$_cx_qr_ids }$_cx_qr_id"
  done
  if [ -n "$_cx_qr_ids" ]; then
    _cx_tmux set -p -t "$_CX_TARGET_PANE" "$_CX_QUIET_OPT" "$_cx_qr_ids" \
      > /dev/null 2>&1 || true
  else
    _cx_tmux set -p -t "$_CX_TARGET_PANE" -u "$_CX_QUIET_OPT" \
      > /dev/null 2>&1 || true
  fi
}

_cx_first_line() {
  printf '%s' "${1:-}" | head -n 1
}

# -- 主流程 -----------------------------------------------------------------

_cx_input=$(cat)

if [ -z "${TMUX_PANE:-}" ] && [ -z "${WHISTLE_TMUX_SOCKET:-}" ]; then
  exit 0
fi

_cx_event=$(whistle_cx_json_get "$_cx_input" hook_event_name)
_cx_sid=$(whistle_cx_json_get "$_cx_input" session_id)
_cx_resolve_target || true
whistle_cx_log "$_cx_event" "$_cx_input"

[ -x "$WHISTLE_CLI" ] || exit 0

[ -n "$_CX_TARGET_PANE" ] || exit 0
if [ -n "$_cx_sid" ]; then
  WHISTLE_CX_SESSION_ID="$_cx_sid"
  export WHISTLE_CX_SESSION_ID
fi

# 内部会话的后续事件不参与 pane 状态机。SessionEnd 同时回收 id，失败/中断
# 留下的陈旧 id 最多只影响它自己的 session_id，不会静默其它真实会话。
if _cx_quiet_has "$_cx_sid"; then
  [ "$_cx_event" = SessionEnd ] && _cx_quiet_remove "$_cx_sid"
  exit 0
fi

case "$_cx_event" in
SessionStart)
  # compact 发生在一轮中间，不能把正在转的 ▶ 掐掉。
  _cx_source=$(whistle_cx_json_get "$_cx_input" source)
  [ "$_cx_source" = compact ] && exit 0

  # fork 既可能是用户主动分支，也可能是后台 ephemeral 摘要。SessionStart
  # 本身不足以判断，先不动父会话状态；真实用户回合会由 UserPromptSubmit
  # 正常点亮 running，内部摘要则会命中下面的标记。
  [ "$_cx_source" = fork ] && exit 0

  # 恢复/新开会话都只是停在提示符前等着，不能报 running。
  _cx_cli --agent-idle "$_CX_TARGET_PANE"
  ;;
UserPromptSubmit)
  _cx_prompt=$(whistle_cx_json_get "$_cx_input" prompt)
  case "$_cx_prompt" in
  "$_CX_INTERNAL_PROMPT_MARKER"*)
    # 先记 session_id 再退出；Stop / SessionEnd 只凭 id 判断，不解析摘要正文。
    _cx_quiet_add "$_cx_sid"
    exit 0
    ;;
  esac

  # 真正的用户输入才算开始干活，并顺手把上一轮未读通知标为已读。
  _cx_cli --prompt-start "$_CX_TARGET_PANE"
  ;;
PermissionRequest)
  # 权限提示是即时 wait，不依赖 Claude 那套 60 秒 idle_prompt。
  _cx_tool=$(whistle_cx_json_get "$_cx_input" tool_name)
  _cx_desc=$(whistle_cx_json_nested_get "$_cx_input" tool_input description)
  _cx_cmd=$(whistle_cx_json_nested_get "$_cx_input" tool_input command)

  _cx_body="${_cx_desc:-$_cx_cmd}"
  _cx_msg=$(_cx_first_line "${_cx_desc:-$_cx_cmd}")
  if [ -z "$_cx_msg" ]; then
    if [ -n "$_cx_tool" ]; then
      _cx_msg="需要批准: $_cx_tool"
    else
      _cx_msg='需要批准'
    fi
  fi

  _cx_cli --notice 'wait' "$_cx_msg" --body "$_cx_body" "$_CX_TARGET_PANE"
  ;;
PostToolUse)
  # 工具真正跑起来说明授权已经解决。只清 wait，绝不碰活动通道：
  # 高频事件如果改活动态，异步写入可能晚于 Stop，留下灭不掉的 ▶。
  _cx_clear_wait
  ;;
SubagentStart)
  WHISTLE_CX_SUB_AGENT_ID=$(whistle_cx_json_get "$_cx_input" agent_id)
  export WHISTLE_CX_SUB_AGENT_ID
  _cx_cli --sub-agent-start "$_CX_TARGET_PANE"
  ;;
SubagentStop)
  # 只清标记。主 agent 那一轮通常还在跑，写 idle 会把它标错。
  WHISTLE_CX_SUB_AGENT_ID=$(whistle_cx_json_get "$_cx_input" agent_id)
  export WHISTLE_CX_SUB_AGENT_ID
  _cx_cli --sub-agent-stop "$_CX_TARGET_PANE"
  ;;
Stop)
  # 主回合结束：活动回落 idle，通知亮 done。
  # 子 agent 若仍在跑，推导层会把该 pane 合成 running；通知 rank 更高，
  # 所以用户先看到 ◆，读掉后再看到 ▶，子 agent 结束自然回落 idle。
  _cx_msg=$(whistle_cx_json_get "$_cx_input" last_assistant_message)
  _cx_body="$_cx_msg"
  _cx_msg=$(_cx_first_line "$_cx_msg")

  _cx_cli --turn-end 'done' --title "$_cx_msg" --body "$_cx_body" "$_CX_TARGET_PANE"
  ;;
Interrupt)
  # 用户主动打断：当前回合不会再发 Stop，必须在这里收掉 running。
  _cx_cli --turn-interrupt "$_CX_TARGET_PANE"
  ;;
SessionEnd)
  # 同步执行（安装器不设 async）。hook 跑时 Codex 进程可能还没退出，
  # 所以写 gone 而不是清空，避免推导层立刻按前台进程重新认成 idle。
  _cx_cli --codex-session-end "$_CX_TARGET_PANE"
  ;;
*)
  exit 0
  ;;
esac

exit 0
