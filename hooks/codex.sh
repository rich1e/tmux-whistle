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
#   SessionStart      startup/resume/clear/fork → idle；compact 不动
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

# -- tmux 定位 --------------------------------------------------------------
#
# 优先级与 hooks/claude-code.sh 保持一致。hook 进程在 Codex 进程树里，
# TMUX_PANE 由 tmux 注入，可信。
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

  _cx_line="$(date '+%Y-%m-%d %H:%M:%S') [$$] agent=codex hook_event_name=$_cx_evt TMUX_PANE=${TMUX_PANE:-}"
  [ -n "$_cx_key" ] && _cx_line="$_cx_line $_cx_key=$_cx_val"
  { printf '%s\n' "$_cx_line" >> "$_cx_lf"; } 2> /dev/null
  return 0
}

# -- 写入封装 ---------------------------------------------------------------

_cx_cli() {
  WHISTLE_SRC=hook "$WHISTLE_CLI" "$@" > /dev/null 2>&1 || true
}

_cx_notice() {
  [ -n "${TMUX_PANE:-}" ] || return 0
  _cx_tmux show -pqv -t "$TMUX_PANE" '@whistle_notice' 2> /dev/null || true
}

_cx_clear_wait() {
  [ "$(_cx_notice)" = wait ] || return 0
  _cx_cli --read-pane "$TMUX_PANE"
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
whistle_cx_log "$_cx_event" "$_cx_input"

[ -x "$WHISTLE_CLI" ] || exit 0

case "$_cx_event" in
SessionStart)
  # compact 发生在一轮中间，不能把正在转的 ▶ 掐掉。
  _cx_source=$(whistle_cx_json_get "$_cx_input" source)
  [ "$_cx_source" = compact ] && exit 0

  # 恢复/新开会话都只是停在提示符前等着，不能报 running。
  _cx_cli --agent-idle "$TMUX_PANE"
  ;;
UserPromptSubmit)
  # 真正的用户输入才算开始干活，并顺手把上一轮未读通知标为已读。
  _cx_cli --prompt-start "$TMUX_PANE"
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

  _cx_cli --notice 'wait' "$_cx_msg" --body "$_cx_body"
  ;;
PostToolUse)
  # 工具真正跑起来说明授权已经解决。只清 wait，绝不碰活动通道：
  # 高频事件如果改活动态，异步写入可能晚于 Stop，留下灭不掉的 ▶。
  _cx_clear_wait
  ;;
SubagentStart)
  _cx_cli --sub-agent-start
  ;;
SubagentStop)
  # 只清标记。主 agent 那一轮通常还在跑，写 idle 会把它标错。
  _cx_cli --sub-agent-stop
  ;;
Stop)
  # 主回合结束：活动回落 idle，通知亮 done。
  # 子 agent 若仍在跑，推导层会把该 pane 合成 running；通知 rank 更高，
  # 所以用户先看到 ◆，读掉后再看到 ▶，子 agent 结束自然回落 idle。
  _cx_msg=$(whistle_cx_json_get "$_cx_input" last_assistant_message)
  _cx_body="$_cx_msg"
  _cx_msg=$(_cx_first_line "$_cx_msg")

  _cx_cli --turn-end 'done' --title "$_cx_msg" --body "$_cx_body" "$TMUX_PANE"
  ;;
Interrupt)
  # 用户主动打断：当前回合不会再发 Stop，必须在这里收掉 running。
  _cx_cli --turn-interrupt "$TMUX_PANE"
  ;;
SessionEnd)
  # 同步执行（安装器不设 async）。hook 跑时 Codex 进程可能还没退出，
  # 所以写 gone 而不是清空，避免推导层立刻按前台进程重新认成 idle。
  [ -n "${TMUX_PANE:-}" ] || exit 0
  _cx_cli --clear-pane "$TMUX_PANE"
  ;;
*)
  exit 0
  ;;
esac

exit 0
