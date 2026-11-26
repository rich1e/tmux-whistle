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

# 允许被 source（L1 单测直接加载这里的纯状态机）；直接执行时才自己推根目录。
if [ -z "${WHISTLE_ROOT:-}" ]; then
	WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fi
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
# 允许外部（单测）用 WHISTLE_DETECT_STATE_DIR 指定隔离目录。
if [ -z "${WHISTLE_DETECT_STATE_DIR:-}" ]; then
	_ds_sock="${WHISTLE_TMUX_SOCKET:-${TMUX:-}}"
	_ds_sock=${_ds_sock%%,*}
	_ds_tag=$(printf '%s' "$_ds_sock" | cksum | cut -d' ' -f1)
	WHISTLE_DETECT_STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-whistle-$(id -u)-${_ds_tag}"
fi
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

# whistle_detect_forget <pane>
# 丢掉这个 pane 的防抖状态。agent 退出、状态槽被清空、tmux option 与状态文件
# 对不上时都要调 —— 留下的 .last 会让下一次分类被当成「没有变化」而不写。
whistle_detect_forget() {
	_daf_id="${1#%}"
	command rm -f "$WHISTLE_DETECT_STATE_DIR/$_daf_id.last" \
		"$WHISTLE_DETECT_STATE_DIR/$_daf_id.pending" \
		"$WHISTLE_DETECT_STATE_DIR/$_daf_id.count"
}

# whistle_detect_apply <pane> <running|idle>
# exit 0 = 这一次应当真正写状态槽（状态变了）；exit 1 = 再等等。
#
# 防抖规则（D6）：
#   → running  **立即生效**。晚一拍才亮 ▶ 会让人以为 agent 没反应，
#              而且 running 本来就是「确认发生了」的那一侧。
#   其余切换   **连续两次**相同分类才生效。TUI 每帧重绘、光标闪烁都会让
#              屏幕瞬时看起来「空下来了」，一次就信会让 ▶ / ◉ 反复闪。
#
# 状态放文件而不是 tmux option：这是「连续次数」的进程内状态，
# 守护重启后从头计也无害（最坏多等一拍）。
whistle_detect_apply() {
	_dap_id="${1#%}"
	_dap_state="$2"

	_dap_last_file="$WHISTLE_DETECT_STATE_DIR/$_dap_id.last"
	_dap_pend_file="$WHISTLE_DETECT_STATE_DIR/$_dap_id.pending"
	_dap_cnt_file="$WHISTLE_DETECT_STATE_DIR/$_dap_id.count"

	_dap_last=''
	if [ -f "$_dap_last_file" ]; then
		_dap_last=$(cat "$_dap_last_file" 2>/dev/null)
	fi
	if [ "$_dap_state" = "$_dap_last" ]; then
		# 又看到了与已生效状态一致的分类 —— 中间那次「想切换」的观察作废。
		# 不清的话，running / idle 交替闪烁时 pending 计数会被攒起来，
		# 下一次 idle 直接命中阈值，防抖等于没做。
		command rm -f "$_dap_pend_file" "$_dap_cnt_file"
		return 1
	fi

	if [ "$_dap_state" = running ]; then
		printf '%s' "$_dap_state" >"$_dap_last_file"
		command rm -f "$_dap_pend_file" "$_dap_cnt_file"
		return 0
	fi

	_dap_pend=''
	if [ -f "$_dap_pend_file" ]; then
		_dap_pend=$(cat "$_dap_pend_file" 2>/dev/null)
	fi
	_dap_cnt=0
	if [ -f "$_dap_cnt_file" ]; then
		_dap_cnt=$(cat "$_dap_cnt_file" 2>/dev/null)
	fi
	case "$_dap_cnt" in
	'' | *[!0-9]*) _dap_cnt=0 ;;
	esac

	if [ "$_dap_state" = "$_dap_pend" ]; then
		_dap_cnt=$((_dap_cnt + 1))
	else
		_dap_pend="$_dap_state"
		_dap_cnt=1
	fi
	printf '%s' "$_dap_pend" >"$_dap_pend_file"
	printf '%s' "$_dap_cnt" >"$_dap_cnt_file"

	[ "$_dap_cnt" -ge 2 ] || return 1

	printf '%s' "$_dap_state" >"$_dap_last_file"
	command rm -f "$_dap_pend_file" "$_dap_cnt_file"
	return 0
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
	command rm -f "$WHISTLE_DETECT_STATE_DIR/agent_seen"

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
				whistle_detect_forget "$_dv_pane"
				whistle_detect_sync "$_dv_pane"
			fi
			continue
		fi

		# 有 agent 在跑 → 告诉循环这一轮该按 1 秒的节奏接着扫
		: >"$WHISTLE_DETECT_STATE_DIR/agent_seen"

		# tmux option 是内存态（server 重启就没了），状态文件却留在 /tmp 里。
		# 两者对不上时以 tmux 为准 —— 留着 .last 会让下一次分类被当成
		# 「没有变化」，于是一个刚重启的 server 永远等不到 live 写入。
		if [ -z "${_dv_live:-}" ] && [ -f "$WHISTLE_DETECT_STATE_DIR/${_dv_pane#%}.last" ]; then
			whistle_detect_forget "$_dv_pane"
		fi

		_dv_screen=$(whistle_tmux capture-pane -p -J -t "$_dv_pane" 2>/dev/null)
		_dv_state=$(printf '%s\n' "$_dv_screen" | whistle_classify_screen "$_dv_kind")

		case "$_dv_state" in
		running | idle)
			# 防抖：running 立即生效，其余要连续两次（见 whistle_detect_apply）
			whistle_detect_apply "$_dv_pane" "$_dv_state" || continue
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
		# 有 agent 在跑时按 1 秒扫（用户正盯着状态栏等这一轮结束）；
		# 没有 agent 就回到用户配的间隔 —— 别为一个纯 shell 的 server 每秒 fork。
		if [ -f "$WHISTLE_DETECT_STATE_DIR/agent_seen" ]; then
			sleep 1
		else
			_interval=$(whistle_conf '@whistle_detect_interval')
			sleep "${_interval:-15}"
		fi
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
# ⚠️ 只有**直接执行**时才起循环。被 source（L1 单测加载纯状态机）时，
# `$1` 是测试框架自己的参数，照原样分派会误起守护 —— 而守护在开头就装了
# EXIT trap（清 pidfile），那个 trap 会打断 bats 的结果统计，
# 症状是「Executed N instead of expected M」，且失败的用例连一行都不打印。
if [ "${0##*/}" = detect.sh ]; then
	case "${1:-}" in
	loop) whistle_detect_loop ;;
	once) whistle_detect_once ;;
	*) whistle_detect_loop ;;
	esac
fi
