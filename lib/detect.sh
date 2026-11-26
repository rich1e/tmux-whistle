#!/bin/sh
# tmux-whistle 的读屏降级通道。
#
# 这是唯一「从屏幕文字里猜状态」的地方，也是**补充**而不是真源：
#   @whistle       agent 自己上报的活动态（hook）      ← 真源
#   @whistle_live  读屏分类出来的活动态（本文件）      ← 只在真源为空时生效
#   @whistle_notice 有没有事等你（wait 也走这里）
#
# 与 hooks 路径的关系：hook / migration 接管过的 pane 一律跳过 —— 一旦某个
# pane 被 hook 接管过，这里的轮询就再也不碰它，不会覆盖更准确的语义。
#
# 单实例：pidfile 守卫。进程由 tmux 的 run-shell -b 拉起，
# 常驻循环本身就是被 run-shell 托管的那条命令。

set -u

# 常驻轮询必须**关掉配置快照缓存**：它靠每轮重读 @whistle_detect 来感知用户关闭
# 检测（`while :; do [ "$(whistle_conf @whistle_detect)" = on ] || break`）。
WHISTLE_CONF_NO_CACHE=1
export WHISTLE_CONF_NO_CACHE

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export WHISTLE_ROOT

# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/core.sh"
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/detect-rules.sh"

# 状态目录按 **socket** 隔离。
#
# 早先只按 uid 命名（/tmp/tmux-whistle-<uid>）：同一个用户同时跑着真 server
# 与测试的隔离 server 时，两边共用同一个 pidfile —— 隔离 server 的守护先起来，
# 真 server 的就被 pidfile 挡在门外（或反过来），其中一边的状态永远不更新，
# 而界面上完全看不出原因。凡「按 server 隔离」的状态都不该落按用户命名的文件。
_ds_sock="${WHISTLE_TMUX_SOCKET:-${TMUX:-}}"
_ds_sock=${_ds_sock%%,*}
_ds_tag=$(printf '%s' "$_ds_sock" | cksum | cut -d' ' -f1)
WHISTLE_DETECT_STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-whistle-$(id -u)-${_ds_tag}"
WHISTLE_DETECT_PIDFILE="$WHISTLE_DETECT_STATE_DIR/detect.pid"

# pane 前台进程的完整命令行。
#
# `#{pane_current_command}` 只给得出进程名，而 `codex exec` 与交互 TUI 的
# 进程名是同一个 —— 「是不是一次性子命令」只能看 argv。
# 前台进程 = pid 等于该 tty 的 tpgid 的那个。
whistle_detect_argv() {
	_da_tty="${1#/dev/}"
	ps -o pid=,tpgid=,command= -t "$_da_tty" 2>/dev/null |
		awk '$1 == $2 { sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, ""); print; exit }'
}

whistle_detect_pid_alive() {
	_pid="$1"
	[ -n "$_pid" ] || return 1
	kill -0 "$_pid" 2>/dev/null
}

# 写完之后的重算与投递。
# 只有**真的变了**才走到这里：每秒每 pane 全量重算会把 tmux 命令队列压满。
whistle_detect_sync() {
	_dsv_win=$(whistle_pane_window "$1")
	if [ -n "$_dsv_win" ]; then
		whistle_recompute_window "$_dsv_win"
		whistle_refresh_sessions "$_dsv_win"
	fi
	whistle_recompute_global
}

# 一次扫描。返回 0 表示做了至少一次状态变更。
whistle_detect_once() {
	_dv_cmds=$(whistle_conf '@whistle_agent_cmds')

	mkdir -p "$WHISTLE_DETECT_STATE_DIR" 2>/dev/null || return 0

	_dv_panes=$(whistle_tmux list-panes -a \
		-F '#{pane_id}|#{pane_current_command}|#{@whistle_src}|#{@whistle_live}|#{@whistle_notice}|#{pane_tty}' 2>/dev/null)

	printf '%s\n' "$_dv_panes" | while IFS='|' read -r _dv_pane _dv_cmd _dv_src _dv_live _dv_notice _dv_tty; do
		case "${_dv_pane:-}" in
		'%'*) ;;
		*) continue ;;
		esac

		# 仲裁：只跳过 hook / migration 真正接管过的 pane。
		# 早先是「src 非空就跳过」，把 deliver 之类的旁路写入也一起挡掉了。
		case "${_dv_src:-}" in
		hook | migration) continue ;;
		esac

		_dv_argv=$(whistle_detect_argv "$_dv_tty")
		_dv_name=$(whistle_detect_name "$_dv_cmd" "$_dv_argv")
		_dv_kind=$(whistle_agent_kind "$_dv_name")

		# 不是认识的 agent，或不是交互式进程 → 清掉可能残留的 live 就收工。
		# 读屏对它没有任何可信结论，留着旧值就是一盏永不熄灭的 ▶。
		if [ -z "$_dv_kind" ] || ! whistle_detect_eligible "$_dv_cmd" "$_dv_argv" "$_dv_cmds"; then
			if [ -n "${_dv_live:-}" ]; then
				whistle_live_set '' "$_dv_pane" >/dev/null
			fi
			continue
		fi

		_dv_screen=$(whistle_tmux capture-pane -p -J -t "$_dv_pane" 2>/dev/null)
		_dv_state=$(printf '%s\n' "$_dv_screen" | whistle_classify_screen "$_dv_kind")

		case "$_dv_state" in
		running | idle)
			# 没变化就什么都不做 —— 否则每秒都会重算一遍 window / global
			[ "$_dv_state" = "${_dv_live:-}" ] && continue
			whistle_live_set "$_dv_state" "$_dv_pane" >/dev/null || continue
			;;
		wait)
			[ -n "${_dv_notice:-}" ] && continue
			WHISTLE_SRC=detect whistle_state_set "wait" '检测到等待输入' "$_dv_pane" >/dev/null || continue
			;;
		*)
			# freeze 与「认不出来」都不动状态：滚动冻结只是视线离开底部，
			# 不代表 agent 停了；认不出来时宁可保持上一次的结论。
			continue
			;;
		esac

		whistle_detect_sync "$_dv_pane"
	done

	return 0
}

whistle_detect_loop() {
	mkdir -p "$WHISTLE_DETECT_STATE_DIR" 2>/dev/null || exit 1

	if [ -f "$WHISTLE_DETECT_PIDFILE" ]; then
		_old=$(cat "$WHISTLE_DETECT_PIDFILE" 2>/dev/null)
		if whistle_detect_pid_alive "$_old"; then
			exit 0 # 已有实例
		fi
	fi
	printf '%s' "$$" >"$WHISTLE_DETECT_PIDFILE"

	trap 'command rm -f "$WHISTLE_DETECT_PIDFILE" 2>/dev/null; exit 0' INT TERM EXIT

	while :; do
		[ "$(whistle_conf '@whistle_detect')" = on ] || break
		whistle_detect_once
		_interval=$(whistle_conf '@whistle_detect_interval')
		sleep "${_interval:-15}"
	done
}

# 由 setup.sh 调用：确保守护在跑，但不阻塞
whistle_detect_ensure_daemon() {
	[ "$(whistle_conf '@whistle_detect')" = on ] || return 0

	if [ -f "$WHISTLE_DETECT_PIDFILE" ]; then
		whistle_detect_pid_alive "$(cat "$WHISTLE_DETECT_PIDFILE" 2>/dev/null)" && return 0
	fi

	whistle_tmux run-shell -b "'$WHISTLE_ROOT/lib/detect.sh' loop"
}

# 直接执行时（例如 tmux run-shell 拉起的常驻进程）跑循环
case "${1:-}" in
loop) whistle_detect_loop ;;
once) whistle_detect_once ;;
*) whistle_detect_loop ;;
esac
