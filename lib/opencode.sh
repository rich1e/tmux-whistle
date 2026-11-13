#!/bin/sh
# tmux-whistle 的 OpenCode 事件映射 —— **纯函数层**。
#
# 这一层只做「输入 → 该干什么」的判定，**一个 tmux 调用都没有**，
# 所以 L1 单测可以直接 source 它（test/unit/opencode.bats）。
# 真正的 IO（读 stdin、定位 tmux、调 CLI）在 hooks/opencode.sh。
#
# 为什么不把映射写进 hooks/opencode.sh：那个文件照 claude-code.sh 同构会有
# `_oc_input=$(cat)`（source 时阻塞读 stdin）与结尾 `exit 0`（source 会退出测试
# 进程），根本没法被单测覆盖。这是刻意的拆分，不是随手分层。
#
# 与 claude-code.sh 顶部「hook 不 source 状态机」那条约定**不冲突**：
# 本文件不含任何 tmux 调用与状态机逻辑，只是五十来行查表，blast radius 远小于
# source lib/core.sh。
#
# POSIX sh：没有 local，临时变量一律带 _oc 前缀。

# -- JSON 取值：jq → python3 → sed 逐级降级 -------------------------------
#
# 与 hooks/claude-code.sh 的 whistle_json_get 同构。这里只取顶层扁平字符串字段 ——
# TUI 插件已经把事件载荷压成扁平结构（见 hooks/opencode/tui.js），
# 所以 sed 启发式够用。
whistle_oc_json_get() {
  _oc_j="$1"
  _oc_k="$2"

  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$_oc_j" | jq -r --arg k "$_oc_k" '.[$k] // empty' 2> /dev/null
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    printf '%s' "$_oc_j" | python3 -c \
      'import json,sys
try:
    v = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else "")' "$_oc_k" 2> /dev/null
    return 0
  fi
  printf '%s' "$_oc_j" | sed -n "s/.*\"$_oc_k\":\"\\([^\"]*\\)\".*/\\1/p" 2> /dev/null
}

# -- 多行消息取首行 --------------------------------------------------------
#
# 徽章只有一行宽度，首行以外的内容无处可寻 → 全文进 --body，首行进 --title。
# 与 claude-code.sh 对 last_assistant_message 的处理一致。
whistle_oc_first_line() {
  printf '%s' "${1:-}" | head -n 1
}

# -- 事件 → 动作 ------------------------------------------------------------
#
# 输出若干行，每行一个动作，调用方按顺序执行：
#   activity:<running|idle|gone>   写活动通道
#   notice:<done|wait|error>       写通知通道
#   read-notice                    清该 pane 的通知（已读），绝不动活动通道
#   shell-add / shell-del          后台 shell 的在飞集合增删（id 由调用方给）
#   notice:done-guarded            **仅当没有后台在飞时**才写 done
#
# 为什么用「输出动作列表」而不是「返回一个状态」：一个事件常常同时动两条通道
# （succeeded = 活动 idle + 通知 done），拆成两次查询必然分叉。
#
# 参数：<event> [reason] [reply] [shell_status]
#
#   reason        只对 session.execution.interrupted 有意义
#   reply         只对 permission.replied 有意义
#   shell_status  只对 session.shell.* 有意义（running/exited/timeout/killed）
whistle_oc_actions() {
  _oc_ev="${1:-}"
  _oc_reason="${2:-}"
  _oc_reply="${3:-}"
  _oc_sstatus="${4:-}"

  case "$_oc_ev" in
  # 一轮开始 / 工具调用 = 真的在干活。running 只有这两个入口，
  # 对应 Claude 侧的 UserPromptSubmit 与 PreToolUse。
  session.execution.started | session.tool.called)
    printf 'activity:running\n'
    ;;

  # 一轮正常结束：活动回落 idle，通知亮 done。
  # done 要走 guarded 版本 —— 后台还有活在飞时**不能**报 done，
  # 否则 done(3) > running(2) 会把后台的 ▶ 盖成 ◆（TODO-18 的现场）。
  session.execution.succeeded)
    printf 'activity:idle\n'
    printf 'notice:done-guarded\n'
    ;;

  # 回合因 API 错误结束。error 的 rank 最高，后台在飞也要报。
  session.execution.failed)
    printf 'activity:idle\n'
    printf 'notice:error\n'
    ;;

  # 中断必须按 reason 分派 —— 一律映 idle 是错的，见方案 §2.2。
  session.execution.interrupted)
    case "$_oc_reason" in
    # 被新一轮取代 = **现在正在跑新的一轮**。写 idle 会把 ▶ 打成 ◉，
    # 而下一个事件可能很久才来。不动活动通道。
    superseded) ;;
    # 正在关闭：写 idle 会留一盏 ◉ 等 cleanup 覆盖；cleanup 若没跑（R7）
    # 就是永久残留。gone 才是「这个 pane 的 agent 走了」。
    shutdown) printf 'activity:gone\n' ;;
    # user / inactivity / 未知 —— 都回到提示符前等着。
    *) printf 'activity:idle\n' ;;
    esac
    ;;

  # 权限请求 = 有事等你，**即时**。这是相对 Claude 侧 idle_prompt 的实质简化：
  # 不需要等 60 秒，也不需要那两道守卫。
  permission.asked)
    printf 'notice:wait\n'
    ;;

  # 用户答了。once/always 表示执行继续（活动态不动，仍是 running）；
  # reject 结束当前 step，官方文档说「A plain rejection ends the current step」，
  # 之后可能没有 succeeded/failed 来收尾 —— 不写 idle 就会留下永不灭的 ▶。
  permission.replied)
    printf 'read-notice\n'
    case "$_oc_reply" in
    reject) printf 'activity:idle\n' ;;
    esac
    ;;

  # 后台 shell：只有 status=running 才算「在飞」。
  # ended 的载荷里也带 status（exited/timeout/killed），同样按 id 移除。
  session.shell.started)
    case "$_oc_sstatus" in
    '' | running) printf 'shell-add\n' ;;
    esac
    ;;
  session.shell.ended)
    printf 'shell-del\n'
    ;;

  # 刻意不映射，理由见方案 §2.6：
  #   retry.scheduled 不是终态（重试常自动成功，报 error 是噪音）；
  #   idle 是瞬时 UI 信号，持久语义已由 execution.succeeded 覆盖。
  session.retry.scheduled | session.idle) ;;

  # 未知事件不猜，静默忽略（调用方仍会记 debug 日志）。
  *) ;;
  esac
}

# -- 在飞 shell 的 id 集合 --------------------------------------------------
#
# 为什么不只是计数器：同一条 started 重复到达（重试）不该把计数加两次，
# ended 又必须能精确摘掉**对应的那一条**。用 id 集合天然幂等。
#
# 集合用空格分隔的字符串表示，存在 pane 自己的 option 里
# （@whistle_oc_shell）—— 凡是「按 server / 按 pane 隔离」的状态都别落磁盘，
# 那是 spin pidfile 踩过的坑（CLAUDE.md）。

# whistle_oc_set_add <集合> <id> → 新集合
whistle_oc_set_add() {
  _oca_set="${1:-}"
  _oca_id="${2:-}"
  [ -n "$_oca_id" ] || {
    printf '%s' "$_oca_set"
    return 0
  }
  case " $_oca_set " in
  *" $_oca_id "*)
    printf '%s' "$_oca_set"
    return 0
    ;;
  esac
  if [ -n "$_oca_set" ]; then
    printf '%s %s' "$_oca_set" "$_oca_id"
  else
    printf '%s' "$_oca_id"
  fi
}

# whistle_oc_set_del <集合> <id> → 新集合
whistle_oc_set_del() {
  _ocd_set="${1:-}"
  _ocd_id="${2:-}"
  _ocd_out=''

  [ -n "$_ocd_id" ] || {
    printf '%s' "$_ocd_set"
    return 0
  }

  # 词分割（不加引号）是刻意的：集合本身是空格分隔的 id 列表。
  for _ocd_it in $_ocd_set; do
    [ "$_ocd_it" = "$_ocd_id" ] && continue
    if [ -n "$_ocd_out" ]; then
      _ocd_out="$_ocd_out $_ocd_it"
    else
      _ocd_out="$_ocd_it"
    fi
  done
  printf '%s' "$_ocd_out"
}

# whistle_oc_set_has <集合> → 0 = 非空（有后台在飞）
whistle_oc_set_has() {
  case "${1:-}" in
  '' | ' ') return 1 ;;
  *) return 0 ;;
  esac
}

# whistle_oc_set_count <集合> → 在飞个数（空格分隔的 id 列表）
#
# **刻意不用 `for it in $set`**：那是按调用方的 IFS 切词的。hooks 里一旦有人
# 在循环里临时改 IFS（历史上很容易顺手这么写），这里就会把 "a b c" 当成一项，
# 静默数成 1。改用显式的 `IFS=' '` 子 shell，与本函数被谁调用无关。
whistle_oc_set_count() {
  _occ_out=$(
    IFS=' '
    _occ_n=0
    for _occ_it in ${1:-}; do
      [ -n "$_occ_it" ] || continue
      _occ_n=$((_occ_n + 1))
    done
    printf '%s' "$_occ_n"
  )
  printf '%s' "$_occ_out"
}

# whistle_oc_bg_title <在飞个数> → 徽章上的短标题
whistle_oc_bg_title() {
  _ocb_n="${1:-0}"
  case "$_ocb_n" in
  '' | *[!0-9]*) _ocb_n=0 ;;
  esac
  if [ "$_ocb_n" -gt 1 ]; then
    printf '后台: %s 个任务' "$_ocb_n"
  elif [ "$_ocb_n" -eq 1 ]; then
    printf '后台: 1 个任务'
  fi
}

# whistle_oc_is_child_action <动作名>
#
# 子 session 的事件**只许写通知通道**，不许动活动通道。
# 理由与 Claude 侧的 SubagentStop 完全一样：主 agent 那一轮通常还在跑
# （它派了子 agent、正等结果），被子 agent 报成 idle 会把正在干活的主 agent
# 标成「空闲」，而且全程零报错。
whistle_oc_action_is_activity() {
  case "${1:-}" in
  activity:*) return 0 ;;
  *) return 1 ;;
  esac
}

# whistle_oc_action_is_notice <动作名>
whistle_oc_action_is_notice() {
  case "${1:-}" in
  notice:*) return 0 ;;
  *) return 1 ;;
  esac
}

# whistle_oc_action_is_done <动作名>
#
# 只把 done 类动作挑出来 —— 子 session 的 done 必须走"先看 pane 上有没有
# 未读通知"的守卫，不能像普通通知那样无条件覆盖。见 hooks/opencode.sh。
whistle_oc_action_is_done() {
  case "${1:-}" in
  notice:done | notice:done-guarded) return 0 ;;
  *) return 1 ;;
  esac
}

# whistle_oc_child_done_msg <子 session 标题>
#
# 子 session 通常没有 title：拿不到标题时给一句固定文案，
# 否则落库的 msg 是空串 —— 徽章只剩一个图标、通知只剩状态标签。
whistle_oc_child_done_msg() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
  else
    printf '子 agent 完成'
  fi
}
