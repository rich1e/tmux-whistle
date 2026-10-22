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
#
# 退出码恒为 0，stdout 必须为空（Claude Code 会把 stdout 当 JSON 解析）。

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WHISTLE_CLI="$WHISTLE_ROOT/bin/tmux-whistle"

# -- JSON 取值：jq → python3 → sed 逐级降级 -------------------------------
# 只需要顶层扁平字符串字段，sed 启发式够用（转义的 \" 会截断，仅影响显示）。

whistle_json_get() {
  _j="$1"
  _k="$2"

  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$_j" | jq -r --arg k "$_k" '.[$k] // empty' 2> /dev/null
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    printf '%s' "$_j" | python3 -c \
      'import json,sys
try:
    v = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else "")' "$_k" 2> /dev/null
    return 0
  fi
  printf '%s' "$_j" | sed -n "s/.*\"$_k\":\"\\([^\"]*\\)\".*/\\1/p" 2> /dev/null
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

# -- 主流程 -----------------------------------------------------------------

_input=$(cat)

# 不在 tmux 里就没有 pane 可标记（也没有状态栏可显示）—— 静默退出。
# hook 进程继承 pane 的环境变量，TMUX_PANE 天然带过来。
if [ -z "${TMUX_PANE:-}" ] && [ -z "${WHISTLE_TMUX_SOCKET:-}" ]; then
  exit 0
fi

[ -x "$WHISTLE_CLI" ] || exit 0

_event=$(whistle_json_get "$_input" hook_event_name)
_state=''
_msg=''

case "$_event" in
Stop)
  # 主 agent 一轮工作结束 = 工作完成。
  # 官方明确建议用 last_assistant_message 而不是读 transcript：
  # transcript 是异步写的，Stop 时不保证包含最后一条消息。
  _msg=$(whistle_json_get "$_input" last_assistant_message)
  _state='done'
  ;;
StopFailure)
  # 回合因 API 错误结束（限流 / 过载 / 认证失败 / 服务端错误 ...）。
  # 官方文档：StopFailure 在 API 错误时**替代** Stop 触发 —— 两者互斥，
  # 所以这里不会和上面的 done 打架。
  # 这个事件里的 last_assistant_message 是"渲染出来的错误文本本身"
  # （如 "API Error: Rate limit reached"），不是 agent 的回复；
  # 取不到时回落到错误类型名，至少能看出是哪一类故障。
  _err=$(whistle_json_get "$_input" error)
  _msg=$(whistle_json_get "$_input" last_assistant_message)
  [ -n "$_msg" ] || _msg="API 错误${_err:+: ${_err}}"
  _state='error'
  ;;
Notification)
  _ntype=$(whistle_json_get "$_input" notification_type)
  _state=$(whistle_notify_state "$_ntype")
  [ -n "$_state" ] || exit 0
  _msg=$(whistle_json_get "$_input" message)
  ;;
SessionStart | UserPromptSubmit)
  # 用户开始交互 → 之前那条"完成"徽章该熄了
  _state=running
  ;;
*)
  exit 0
  ;;
esac

# 只取消息首行：last_assistant_message 是整段最终回复全文，
# 徽章位置只有一行宽度。
_msg=$(printf '%s' "$_msg" | head -n 1)

WHISTLE_SRC=hook "$WHISTLE_CLI" "$_state" "$_msg" > /dev/null 2>&1 || true

exit 0
