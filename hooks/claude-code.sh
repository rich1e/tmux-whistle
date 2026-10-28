#!/bin/sh
# tmux-whistle 的 Claude Code hook 适配器。
#
# Claude Code 在语义事件点 spawn 本脚本，把事件 JSON 从 stdin 传进来，
# 我们把事件翻译成 whistle 状态并写入当前 tmux pane。
#
# 这是整个插件的"推送源"：没有轮询、没有关键词猜测，
# "我在等你" 与 "我做完了" 都是 agent 自己告诉我们的。
#
# 配置里必须写 "async": true —— 整条链路都不该阻塞 agent。
# 例外是 SessionEnd：Claude Code 退出时会带走后台子进程，异步的清除可能被
# 杀在半路，留下一个永远灭不掉的 ▶ —— 它必须同步（见 lib/install-hooks.sh）。
#
# ⚠️ 状态是**两条正交通道**，不是一个槽：
#      活动通道 @whistle        running / idle / gone  ← 这个 pane 有没有 agent 在干活
#      通知通道 @whistle_notice done / wait / error    ← 有没有事等你
#   一个 pane 可以同时是 running + done（主 agent 在跑，后台 agent 交了个结果）。
#   子 agent 的事件**只写通知通道**，绝不碰活动通道 —— 早先它们无条件写
#   @whistle=done，把主 agent 的 running 顶掉，用户一读就降级成「空闲」。
#
# 退出码恒为 0，stdout 必须为空（Claude Code 会把 stdout 当 JSON 解析）。

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WHISTLE_CLI="$WHISTLE_ROOT/bin/tmux-whistle"

# ⚠ 本文件所有临时变量都带 _hk_ 前缀：POSIX sh 没有局部变量，
#   同名变量会**静默**互相覆盖（历史上踩过 session 名那次）。

# -- tmux 定位 --------------------------------------------------------------
#
# 优先级与 lib/core.sh 的 whistle_tmux 一致：显式 WHISTLE_TMUX_SOCKET（测试用）
# > $TMUX > $TMUX_SOCKET。
#
# 为什么 $TMUX 排在 $TMUX_SOCKET 前面：TMUX_SOCKET 是 oh-my-tmux 写进 tmux
# 全局环境变量的，会被子进程**跨 server 继承** —— 在一个新起的隔离 server 里，
# 它可能仍指向用户正在用的那个 server，拿它定位会写错地方。
# $TMUX 由 tmux 按 server 写好，是权威值（格式 <socket-path>,<pid>,<session>）。
#
# 这里**不** source lib/core.sh：hook 只需要读一个开关，而 source 整个状态机
# 会让「状态机改坏了」直接变成「hook 整个不跑」—— blast radius 太大。

_hk_tmux() {
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

# -- JSON 取值：jq → python3 → sed 逐级降级 -------------------------------
# 只需要顶层扁平字符串字段，sed 启发式够用（转义的 \" 会截断，仅影响显示）。

whistle_json_get() {
  _hk_j="$1"
  _hk_k="$2"

  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$_hk_j" | jq -r --arg k "$_hk_k" '.[$k] // empty' 2> /dev/null
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    printf '%s' "$_hk_j" | python3 -c \
      'import json,sys
try:
    v = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else "")' "$_hk_k" 2> /dev/null
    return 0
  fi
  printf '%s' "$_hk_j" | sed -n "s/.*\"$_hk_k\":\"\\([^\"]*\\)\".*/\\1/p" 2> /dev/null
}

# -- 通知类型 → whistle 状态 ------------------------------------------------
#
# 只处理"需要用户做点什么"的类型，其余（auth_success / elicitation_complete /
# quota_* / plugin_notification）一律忽略，否则状态栏会被无关事件刷满。

whistle_notify_state() {
  case "${1:-}" in
  permission_prompt | elicitation_dialog | elicitation_url_dialog | agent_needs_input)
    printf 'wait'
    ;;
  agent_completed)
    printf 'done'
    ;;
  *)
    printf ''
    ;;
  esac
}

# -- 事件追踪日志 -----------------------------------------------------------
#
# @whistle_debug on 时，把每个收到的 hook 事件记一行到日志文件。
#
# 为什么要有它：上一次线上问题（后台 agent 在跑、状态栏却显示「空闲」）
# 就是因为插件**一行日志都没有** —— hook 收到什么事件、写了什么状态，全靠猜。
#
# 两条硬约束：
#   1. **必须在状态映射之前写**。未知事件（走 *) 分支直接 exit 0）也要留痕
#      —— 否则「收到了但没处理」的事件永远查不到。
#   2. **stdout 必须恒为空**。Claude Code 把 hook 的 stdout 当 JSON 解析。
#      日志只进文件，绝不进 stdout。
#
# 追加写用 >>（单次 write 小于 PIPE_BUF，多个 hook 进程并发写不会互相穿插），
# 绝不先读后写。
#
# 路径可被 WHISTLE_HOOK_LOG 覆盖（测试用），默认
# ${TMPDIR:-/tmp}/tmux-whistle-hooks.log —— 与插件自身的 tmux-whistle.log
# 分开：那是投递层的日志，这是接入层的。

# 日志字段取值：只留首行 + 截断到 80 字符。
#
# 首行是硬要求：last_assistant_message / prompt 是整段正文，
# 完整正文进徽章与 @whistle_body，不进日志（也不该进：可能含敏感内容）。
#
# 不复用 lib/core.sh 的 whistle_sanitize：那个把 \n 拍平成空格再截断 ——
# 于是"第一行"变成"第一行 + 第二行开头"，与这里要的语义不同。
# 也不剔 # { } | —— 日志文件不进 tmux format，剔了只是让排查时看不到原文。
#
# cut 放在最后：按字符切可能把多字节字符切成半个，后面再处理它就可能报
# Illegal byte sequence（CLAUDE.md 里记过这个坑）。
_hk_log_value() {
  printf '%s' "${1:-}" \
    | head -n 1 \
    | tr '\n\r\t' '   ' \
    | tr -d '[:cntrl:]' \
    | tr -s ' ' \
    | sed -e 's/^ *//' -e 's/ *$//' \
    | cut -c "1-80"
}

whistle_hook_log() {
  _hk_evt="${1:-}"
  _hk_json="${2:-}"

  # 开关与 lib/deliver.sh 的 whistle_log 同一个：@whistle_debug（全局 option）。
  # 读不到 / 不是 on 就直接返回 —— 默认是 off，不写日志。
  [ "$(_hk_tmux show -gqv '@whistle_debug' 2> /dev/null || true)" = on ] || return 0

  # 事件 → 关键字段。字段取不到就留空 —— 字段缺失本身也是信息。
  case "$_hk_evt" in
  Notification) _hk_key=notification_type ;;
  SessionStart) _hk_key=source ;;
  PreToolUse | PostToolUse) _hk_key=tool_name ;;
  Stop | StopFailure) _hk_key=last_assistant_message ;;
  UserPromptSubmit) _hk_key=prompt ;;
  SessionEnd) _hk_key=reason ;;
  *) _hk_key='' ;;
  esac

  _hk_val=''
  if [ -n "$_hk_key" ]; then
    _hk_raw=$(whistle_json_get "$_hk_json" "$_hk_key")
    _hk_val=$(_hk_log_value "$_hk_raw")
  fi

  _hk_lf="${WHISTLE_HOOK_LOG:-${TMPDIR:-/tmp}/tmux-whistle-hooks.log}"

  # 目录不可写就放弃写日志 —— 绝不能因为写日志失败而让 hook 报错。
  case "$_hk_lf" in
  */*) _hk_dir="${_hk_lf%/*}" ;;
  *) _hk_dir='.' ;;
  esac
  [ -n "$_hk_dir" ] || _hk_dir='/'
  [ -d "$_hk_dir" ] && [ -w "$_hk_dir" ] || return 0

  # 整行先拼好再一次性追加：分成多次 write 会被并发写交叉撕开。
  # 行格式与 lib/deliver.sh 的 whistle_log 对齐：<时间戳> [pid] <正文>。
  # 字段名用 JSON 里的原名（hook_event_name / TMUX_PANE / tool_name ...），
  # 方便直接 grep 定位。
  _hk_line="$(date '+%Y-%m-%d %H:%M:%S') [$$] hook_event_name=$_hk_evt TMUX_PANE=${TMUX_PANE:-}"
  [ -n "$_hk_key" ] && _hk_line="$_hk_line $_hk_key=$_hk_val"

  { printf '%s\n' "$_hk_line" >> "$_hk_lf"; } 2> /dev/null
  return 0
}

# -- 写入封装 ---------------------------------------------------------------
#
# 一个事件常常要同时写两条通道（Stop = 活动 idle + 通知 done），所以把每次
# CLI 调用包一层：stdout / stderr 一律吞掉、返回码一律忽略。
#
#   为什么丢掉输出：Claude Code 把 hook 的 stdout 当 JSON 解析。
#   为什么忽略返回码：hook 恒返回 0 —— 某次写入没成功也不该让 agent 报错，
#   更不该把它变成 Claude Code 眼里的「hook 失败」。
#
# 用到的内部子命令（只给 hook 用，不是用户语法）：
#   --activity <running|idle|gone>                    写活动通道
#   --notice <done|wait|error> [msg] --body <body>    写通知通道
#   --sub-agent-start / --sub-agent-stop              子 agent 标记
#   --read-pane <pane>                                清该 pane 的通知（本轮已读）
#   --clear-pane <pane>                               SessionEnd 专用：gone + 清标记 + 重算

_hk_cli() {
  WHISTLE_SRC=hook "$WHISTLE_CLI" "$@" > /dev/null 2>&1 || true
}

# 读当前活动的原始值。PreToolUse 要靠它判断是不是已经 gone。
_hk_activity() {
  [ -n "${TMUX_PANE:-}" ] || return 0
  _hk_tmux show -pqv -t "$TMUX_PANE" @whistle 2> /dev/null || true
}

# -- 主流程 -----------------------------------------------------------------

_hk_input=$(cat)

# 不在 tmux 里就没有 pane 可标记（也没有状态栏可显示）—— 静默退出。
# hook 进程继承 pane 的环境变量，TMUX_PANE 天然带过来。
if [ -z "${TMUX_PANE:-}" ] && [ -z "${WHISTLE_TMUX_SOCKET:-}" ]; then
  exit 0
fi

_hk_event=$(whistle_json_get "$_hk_input" hook_event_name)

# 事件追踪日志必须在状态映射**之前**写。
# 未知事件（走 *) 分支）也要留一行，否则「收到了但没处理」永远查不到。
whistle_hook_log "$_hk_event" "$_hk_input"

[ -x "$WHISTLE_CLI" ] || exit 0

case "$_hk_event" in
Stop | StopFailure)
  # 一轮工作结束：活动通道回落 idle，通知通道亮 done / error。
  #
  # 「子 agent 还在跑就不降级」由 core 负责 —— whistle_activity_set 写 idle 时
  # 若 @whistle_sub 还有效，实际写的是 running。
  #
  # 官方明确建议用 last_assistant_message 而不是读 transcript：
  # transcript 是异步写的，Stop 时不保证包含最后一条消息。
  _hk_msg=$(whistle_json_get "$_hk_input" last_assistant_message)

  if [ "$_hk_event" = StopFailure ]; then
    # 回合因 API 错误结束（限流 / 过载 / 认证失败 / 服务端错误 ...）。
    # 官方文档：StopFailure 在 API 错误时**替代** Stop 触发 —— 两者互斥，
    # 所以这里不会和 Stop 的 done 打架。
    #
    # 这个事件里的 last_assistant_message 是"渲染出来的错误文本本身"
    # （如 "API Error: Rate limit reached"），不是 agent 的回复；
    # 取不到时回落到错误类型名，至少能看出是哪一类故障。
    _hk_state=error
    if [ -z "$_hk_msg" ]; then
      _hk_err=$(whistle_json_get "$_hk_input" error)
      _hk_msg="API 错误${_hk_err:+: ${_hk_err}}"
    fi
  else
    _hk_state='done'
  fi

  # 只取消息首行进徽章（那一格只有一行宽度），全文进正文 ——
  # 否则首行以外的内容无处可寻。
  _hk_body="$_hk_msg"
  _hk_msg=$(printf '%s' "$_hk_msg" | head -n 1)

  _hk_cli --activity idle
  _hk_cli --notice "$_hk_state" "$_hk_msg" --body "$_hk_body"
  ;;
PreToolUse)
  # 任意工具调用 = agent 真的在干活。
  #
  # 这条是 plan 模式的关键补丁：plan 批准是一个回合边界，之后没有新的
  # UserPromptSubmit，只有工具调用 —— 靠它把 running 点回来。
  #
  # gone 时不动：SessionEnd 已经宣告 agent 走了（进程还没退，但会话已结束）。
  # 把 gone 改回 running 会让一盏已经灭掉的 ▶ 重新亮起，而它再也没人灭。
  _hk_tool=$(whistle_json_get "$_hk_input" tool_name)

  if [ "$(_hk_activity)" = gone ]; then
    exit 0
  fi

  if [ "$_hk_tool" = Agent ] || [ "$_hk_tool" = Task ]; then
    # 派了子 agent：一次调用即可 —— --sub-agent-start 同时把活动态置 running。
    # 分两次调没有意义，只是多 fork 一次。
    _hk_cli --sub-agent-start
  else
    _hk_cli --activity running
  fi
  ;;
SubagentStop)
  # 子 agent 结束。
  #
  # ⚠️ 顺序：**先清标记，再报 idle**。反过来的话，报 idle 时标记还有效，
  # core 会把它写成 running；而 @whistle 上的 running 没有 TTL ——
  # 那正是「永久 ▶」，这个项目最恨的一类缺陷。
  _hk_cli --sub-agent-stop
  _hk_cli --activity idle
  ;;
Notification)
  # 只处理"需要用户做点什么"的类型，其余（auth_success / elicitation_complete /
  # quota_* / plugin_notification）一律忽略，否则状态栏会被无关事件刷满。
  _hk_ntype=$(whistle_json_get "$_hk_input" notification_type)
  _hk_state=$(whistle_notify_state "$_hk_ntype")
  [ -n "$_hk_state" ] || exit 0
  _hk_msg=$(whistle_json_get "$_hk_input" message)

  # 后台 / 子 agent 完成 → 标记也该清掉，否则推导层会一直把活动态钉在 running。
  if [ "$_hk_ntype" = agent_completed ]; then
    _hk_cli --sub-agent-stop
  fi

  # **只写通知通道，绝不碰活动通道**。
  # 后台 agent 完成时主 agent 很可能正在跑 —— 早先这里无条件写 done 把
  # running 顶掉，用户一读又降级成「空闲」，整条 bug 链就是这么来的。
  _hk_cli --notice "$_hk_state" "$_hk_msg"
  ;;
UserPromptSubmit)
  # 用户发了 prompt = agent **真的**开始干活（running 的主要点亮入口）。
  # 上一轮的通知在这里压掉：用户就在这个 pane 里输入，显然已经看过。
  _hk_cli --activity running
  _hk_cli --read-pane "$TMUX_PANE"
  ;;
SessionStart)
  # 「会话开始了」不等于「agent 在干活」：--continue / --resume 恢复出来的
  # agent、以及刚敲 claude 起的新会话，都停在提示符前面**等着**。
  # 所以报 idle（空闲），而不是 running。
  #
  # compact 是唯一例外：它发生在**一轮还没结束**的时候，agent 确实还在干活，
  # 这时写 idle 会把正在转的 ▶ 掐掉 —— 两条通道都不动，原样退出。
  #
  # 顺带清掉子 agent 标记：上一个会话残留的标记会让推导层继续把活动态
  # 钉在 running 上。idle 也不会顶掉上一轮没读的通知（守卫在 core 里）。
  _hk_source=$(whistle_json_get "$_hk_input" source)
  [ "$_hk_source" = compact ] && exit 0
  _hk_cli --sub-agent-stop
  _hk_cli --activity idle
  ;;
SessionEnd)
  # agent 退出了：活动通道收成 gone。
  #
  # ⚠️ 不是**清空**：钩子跑的时候 agent 进程还没退出，pane_current_command
  # 仍是 claude —— 清空的话紧接着的重算会按「前台跑着 agent」又认成空闲，
  # 留下一盏灭不掉的 ◉。写成 gone 就绕开了。
  #
  # 通知通道一律不动：agent 退出不代表你已经看过，那几条要留到你处理。
  #
  # ⚠️ 这里是本文件唯一**同步**执行的路径（其余 hook 都是 async）：Claude Code
  # 退出会带走后台子进程，异步的清除可能被杀在半路。官方给 SessionEnd 的预算
  # 是 1.5 秒，所以走一条子命令干完三件事（gone + 清子 agent 标记 + 重算）的
  # --clear-pane，而不是 --activity gone 后再调 --sub-agent-stop ——
  # 实测后者两次调用约 1.6 秒，会踩线。
  [ -n "${TMUX_PANE:-}" ] || exit 0
  _hk_cli --clear-pane "$TMUX_PANE"
  ;;
*)
  exit 0
  ;;
esac

exit 0
