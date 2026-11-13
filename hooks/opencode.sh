#!/bin/sh
# tmux-whistle 的 OpenCode 适配器（薄壳）。
#
# 由 hooks/opencode/tui.js 在 OpenCode TUI 进程里 spawn，把事件 JSON 从 stdin
# 传进来，翻译成 whistle 状态并写进**本 TUI 所在的 pane**。
#
# ⚠️ 与 Claude Code 的**根本差别**：OpenCode 是「TUI 进程 + 共享后台服务」双进程，
# 事件里**没有 pane 信息**（99 个 V2 事件一个都没有）。所以 pane 归属必须由 TUI
# 侧提供 —— 本脚本只信 $TMUX_PANE，**绝不按 cwd / 目录猜**。同目录下可能既有
# opencode 又有 claude，猜必错（见 docs/opencode-integration-plan.md §1）。
#
# 分工：
#   lib/opencode.sh   纯函数（事件 → 动作列表），可被 L1 单测 source
#   本文件             IO：读 stdin、定位 tmux、执行动作、调 CLI
#
# 退出码恒为 0，stdout 恒为空 —— 与 claude-code.sh 保持一致，防未来的坑
# （OpenCode 本身不解析 hook 的 stdout，但静默失败是这条链的基本礼貌）。
#
# 用法：
#   opencode.sh            从 stdin 读一个事件 JSON
#   opencode.sh --tui-exit  TUI 正在退出（同步收尾，写 gone）

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WHISTLE_CLI="$WHISTLE_ROOT/bin/tmux-whistle"

# 纯函数层。它不含 tmux 调用，source 它是安全的 —— 与 claude-code.sh 顶部
# 「hook 不 source 状态机」那条约定不冲突（那是针对 lib/core.sh）。
# shellcheck source=../lib/opencode.sh
. "$WHISTLE_ROOT/lib/opencode.sh"

# ⚠ 本文件所有临时变量都带 _oc_ 前缀：POSIX sh 没有局部变量。

# -- tmux 定位 --------------------------------------------------------------
#
# 优先级与 lib/core.sh 的 whistle_tmux 一致：显式 WHISTLE_TMUX_SOCKET（测试用）
# > $TMUX > $TMUX_SOCKET。
#
# 为什么 $TMUX 排在 $TMUX_SOCKET 前面：TMUX_SOCKET 会被子进程**跨 server 继承**，
# 可能指向用户正在用的另一个 server；$TMUX 才是 tmux 按 server 写好的权威值。
_oc_tmux() {
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

# -- 写入封装 ---------------------------------------------------------------
#
# stdout / stderr 一律吞掉、返回码一律忽略：
# 某次写入没成功也不该让 agent 报错，更不该影响 OpenCode 本身。
_oc_cli() {
  WHISTLE_SRC=hook "$WHISTLE_CLI" "$@" > /dev/null 2>&1 || true
}

# 读一个 pane option（拿不到就是空）
_oc_opt() {
  _oc_o_name="$1"
  _oc_tmux show -pqv -t "$TMUX_PANE" "$_oc_o_name" 2> /dev/null || true
}

# -- 事件日志（@whistle_debug on 时） ---------------------------------------
#
# 与 claude-code.sh 的 whistle_hook_log 同构：**必须在映射之前写**，
# 未知事件（走 * 分支）也要留痕 —— 否则「收到了但没处理」永远查不到。
#
# 与投递层日志（tmux-whistle.log）分开：那是 IO，这是接入层。
whistle_oc_log() {
  _ocl_evt="${1:-}"
  _ocl_json="${2:-}"

  [ "$(_oc_tmux show -gqv '@whistle_debug' 2> /dev/null || true)" = on ] || return 0

  _ocl_lf="${WHISTLE_HOOK_LOG:-${TMPDIR:-/tmp}/tmux-whistle-hooks.log}"

  case "$_ocl_lf" in
  */*) _ocl_dir="${_ocl_lf%/*}" ;;
  *) _ocl_dir='.' ;;
  esac
  [ -n "$_ocl_dir" ] || _ocl_dir='/'
  [ -d "$_ocl_dir" ] && [ -w "$_ocl_dir" ] || return 0

  # 只留关键字段；取值截到 80 字符。整行先拼好再一次性追加 ——
  # 分多次 write 会被并发写交叉撕开。
  _ocl_sid=$(whistle_oc_json_get "$_ocl_json" sessionID)
  _ocl_child=$(whistle_oc_json_get "$_ocl_json" child)
  _ocl_line="$(date '+%Y-%m-%d %H:%M:%S') [$$] agent=opencode event=$_ocl_evt TMUX_PANE=${TMUX_PANE:-}"
  [ -n "$_ocl_sid" ] && _ocl_line="$_ocl_line session=$_ocl_sid"
  [ -n "$_ocl_child" ] && _ocl_line="$_ocl_line child=$_ocl_child"

  { printf '%s\n' "$_ocl_line" >> "$_ocl_lf"; } 2> /dev/null
  return 0
}

# -- 主流程 -----------------------------------------------------------------

# 不在 tmux 里就没有 pane 可标记（也没有状态栏可显示）—— 静默退出。
# hook 进程继承 pane 的环境变量，TMUX_PANE 天然带过来。
if [ -z "${TMUX_PANE:-}" ] && [ -z "${WHISTLE_TMUX_SOCKET:-}" ]; then
  exit 0
fi

[ -x "$WHISTLE_CLI" ] || exit 0

# -- TUI 启动：报 idle ------------------------------------------------------
#
# 「TUI 起来了」不等于「agent 在干活」—— 刚打开、--continue 恢复出来的会话，
# 都是停在提示符前**等着**。所以报 idle（空闲 ◉），不是 running。
# 与 Claude 侧的 SessionStart 完全同一个理由。
#
# ⚠️ 这一条不能省：上次退出写的是 gone（rank 0，不显示、不计数），
# 而推导层只会把**空**状态推成 idle —— gone 不是空，救不回来。
# 少了它，重启 TUI 后那个 pane 在状态栏上就是彻底不存在，
# 用户会以为「插件没装上」。
if [ "${1:-}" = --tui-start ]; then
  [ -n "${TMUX_PANE:-}" ] || exit 0
  # 已经报过 running / idle 就不覆盖：同一 pane 可能开了第二个 TUI，
  # 或者插件被热重载（reconciliation），此时不该把正在干活的状态打回空闲。
  case "$(_oc_opt '@whistle')" in
  running | idle) exit 0 ;;
  esac
  _oc_cli --activity idle "$TMUX_PANE"
  exit 0
fi

# -- 调试开关查询：给 TUI 侧决定要不要写 trace ------------------------------
#
# TUI 插件没有直接读 tmux option 的 API，所以由这里代查一次。
# 退出码 0 = debug 开。只在 setup 时调一次，代价可忽略。
if [ "${1:-}" = --debug-on ]; then
  [ "$(_oc_tmux show -gqv '@whistle_debug' 2> /dev/null || true)" = on ] || exit 1
  exit 0
fi

# -- TUI 侧 trace：把「收到了什么、被哪一步过滤掉」写进同一个 debug 日志 -----
#
# 为什么需要：事件订阅失败时是**完全静默**的 —— 探针能证明插件加载了，
# 但证明不了「订阅建立了几条」。2026-11-13 的现场就是这样：探针有记录、
# 状态栏却一直是 ◉，因为某条 data.on() 抛了异常把整个订阅循环打断。
#
# 只在 JS 侧判定 @whistle_debug=on 时才调（那边查一次 --debug-on 缓存结论）。
if [ "${1:-}" = --trace ]; then
  shift
  _oc_tf="${WHISTLE_HOOK_LOG:-${TMPDIR:-/tmp}/tmux-whistle-hooks.log}"
  case "$_oc_tf" in
  */*) _oc_td="${_oc_tf%/*}" ;;
  *) _oc_td='.' ;;
  esac
  [ -n "$_oc_td" ] || _oc_td='/'
  if [ -d "$_oc_td" ] && [ -w "$_oc_td" ]; then
    { printf '%s [%s] agent=opencode event=js-trace TMUX_PANE=%s %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "${TMUX_PANE:-none}" "$*" >> "$_oc_tf"; } 2> /dev/null
  fi
  exit 0
fi

# -- TUI 加载探针：验证「插件真的在 TUI 进程里跑起来了」 --------------------
#
# 这条不是状态写入，是**自检**。它一次验证四件事，缺任何一件插件都是静默失效：
#   1. TUI part 被加载了（没加载 → 这条日志根本不会出现）
#   2. 加载进的是 TUI 进程（日志里带 TMUX_PANE，且 role=cli）
#   3. spawn 到本脚本可行（路径对、可执行）
#   4. TMUX_PANE 可读（为空说明 TUI 不在 tmux 里）
#
# 只在 @whistle_debug=on 时真的写日志（与事件日志同一个开关），
# 默认不产生任何文件。doctor 就是读这一行来判断插件跑没跑。
if [ "${1:-}" = --probe ]; then
  _oc_pf="${WHISTLE_HOOK_LOG:-${TMPDIR:-/tmp}/tmux-whistle-hooks.log}"
  # 第二、三个参数是 TUI 侧的订阅结果：成功几条、失败哪些。
  # 没有它们时只报 loaded=ok（老行为）。
  _oc_subs="${2:-}"
  _oc_fail="${3:-}"
  if [ "$(_oc_tmux show -gqv '@whistle_debug' 2> /dev/null || true)" = on ]; then
    case "$_oc_pf" in
    */*) _oc_pd="${_oc_pf%/*}" ;;
    *) _oc_pd='.' ;;
    esac
    [ -n "$_oc_pd" ] || _oc_pd='/'
    if [ -d "$_oc_pd" ] && [ -w "$_oc_pd" ]; then
      _oc_extra=''
      [ -n "$_oc_subs" ] && _oc_extra=" subs=${_oc_subs}"
      [ -n "$_oc_fail" ] && _oc_extra="${_oc_extra} failed=${_oc_fail}"
      { printf '%s [%s] agent=opencode event=tui-probe TMUX_PANE=%s loaded=ok%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "${TMUX_PANE:-none}" "$_oc_extra" >> "$_oc_pf"; } 2> /dev/null
    fi
  fi
  exit 0
fi

# -- TUI 退出：同步收尾写 gone ----------------------------------------------
#
# ⚠️ 与 SessionEnd 同一个竞态，理由见 cmd_forget_agent 的注释：
# 收尾跑的时候进程还没退，pane_current_command 仍是 opencode —— 若把状态清空，
# 紧接着的重算会按「前台跑着 agent」又认成 ◉ idle，留下一盏灭不掉的空闲标记。
# 写 gone 就绕开了。
#
# 必须同步（不加后台）：TUI 退出会带走子进程，异步的清除可能被杀在半路。
# --clear-pane 一次调用干完「gone + 清子 agent 标记 + 重算」。
if [ "${1:-}" = --tui-exit ]; then
  [ -n "${TMUX_PANE:-}" ] || exit 0
  _oc_cli --clear-pane "$TMUX_PANE"
  exit 0
fi

_oc_input=$(cat)

_oc_event=$(whistle_oc_json_get "$_oc_input" event)

# 事件追踪日志必须在动作映射**之前**写。
whistle_oc_log "$_oc_event" "$_oc_input"

# TUI 插件算好的三个辅助字段（都来自本地缓存，不发请求）：
#   reason        interrupted 的 reason
#   reply         permission.replied 的 reply
#   shell_status  session.shell.* 的 shell.status
#   shellID       后台 shell 的 id（进在飞集合）
#   child         "1" = 这个事件来自子 session（只许写通知通道）
_oc_reason=$(whistle_oc_json_get "$_oc_input" reason)
_oc_reply=$(whistle_oc_json_get "$_oc_input" reply)
_oc_sstatus=$(whistle_oc_json_get "$_oc_input" shellStatus)
_oc_shell_id=$(whistle_oc_json_get "$_oc_input" shellID)
_oc_child=$(whistle_oc_json_get "$_oc_input" child)

# 消息：通知类事件取正文首行进徽章，全文进 --body。
_oc_msg=$(whistle_oc_json_get "$_oc_input" message)
_oc_body="$_oc_msg"
_oc_msg=$(whistle_oc_first_line "$_oc_body")

# 后台在飞集合（按 pane 自己的 option 隔离，不落磁盘）。
_oc_set=$(_oc_opt '@whistle_oc_shell')

# 逐条执行动作。为什么用「判定与执行分离」：一个事件常常同时动两条通道
# （succeeded = idle + done），L1 才能只测判定。
#
# ⚠️ 遍历动作列表**不要改 IFS**：`for x in $var` 会按当前 IFS 切词，而默认 IFS
# 已经包含空格/制表/换行，动作列表本就是换行分隔的。改 IFS 反而会让
# whistle_oc_set_count 里的 `for it in $set` 按换行切词、数错个数且不报错。
_oc_actions=$(whistle_oc_actions "$_oc_event" "$_oc_reason" "$_oc_reply" "$_oc_sstatus")

[ -n "$_oc_actions" ] || exit 0

for _oc_act in $_oc_actions; do
  # 子 session 的事件只许写通知通道。活动态由 @whistle_sub 的标记 + 推导层合成，
  # 不能让子 agent 把主 agent 的 running 顶成 idle（零报错的那种错）。
  if [ "$_oc_child" = 1 ] && whistle_oc_action_is_activity "$_oc_act"; then
    continue
  fi

  # 子 session 的 done 单独走一条路：主 session 的 done / wait / error
  # 绝不能被刚结束的子 agent 改写（多 session 时这是最常见的串台）。
  # 这个 pane 完全没有未读通知、也没有后台在飞时，才补一条 —— 子 session
  # 通常没有 title，用固定文案兜底，保证徽章与通知里始终有字。
  if [ "$_oc_child" = 1 ] && whistle_oc_action_is_done "$_oc_act"; then
    [ -n "$(_oc_opt '@whistle_notice')" ] && continue
    whistle_oc_set_has "$_oc_set" && continue
    _oc_cli --notice 'done' "$(whistle_oc_child_done_msg "$_oc_msg")" --body "$_oc_body" "$TMUX_PANE"
    continue
  fi

  case "$_oc_act" in
  activity:running) _oc_cli --activity running --title "$_oc_msg" --body "$_oc_body" "$TMUX_PANE" ;;
  activity:idle) _oc_cli --activity idle --title "$_oc_msg" --body "$_oc_body" "$TMUX_PANE" ;;
  activity:gone) _oc_cli --activity gone --title "$_oc_msg" --body "$_oc_body" "$TMUX_PANE" ;;

  notice:wait) _oc_cli --notice wait "$_oc_msg" --body "$_oc_body" "$TMUX_PANE" ;;
  notice:error) _oc_cli --notice error "$_oc_msg" --body "$_oc_body" "$TMUX_PANE" ;;

  # done 要看后台是否还在飞：有活就保持 running 且**不写 done**，
  # 否则 done(3) > running(2) 会把后台的 ▶ 盖成 ◆（TODO-18 的现场）。
  notice:done-guarded)
    if whistle_oc_set_has "$_oc_set"; then
      _oc_n=$(whistle_oc_set_count "$_oc_set")
      _oc_cli --activity running --title "$(whistle_oc_bg_title "$_oc_n")" --body "$_oc_body" "$TMUX_PANE"
    else
      _oc_cli --notice 'done' "$_oc_msg" --body "$_oc_body" "$TMUX_PANE"
    fi
    ;;

  notice:done) _oc_cli --notice 'done' "$_oc_msg" --body "$_oc_body" "$TMUX_PANE" ;;

  # 已读：只清通知通道，绝不动活动通道。
  read-notice) _oc_cli --read-pane "$TMUX_PANE" ;;

  shell-add)
    _oc_set=$(whistle_oc_set_add "$_oc_set" "$_oc_shell_id")
    _oc_tmux set -p -t "$TMUX_PANE" @whistle_oc_shell "$_oc_set" 2> /dev/null || true
    ;;
  shell-del)
    _oc_set=$(whistle_oc_set_del "$_oc_set" "$_oc_shell_id")
    _oc_tmux set -p -t "$TMUX_PANE" @whistle_oc_shell "$_oc_set" 2> /dev/null || true
    ;;
  *) ;;
  esac
done

exit 0
