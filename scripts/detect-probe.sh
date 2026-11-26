#!/bin/sh
# 读屏分类探针：逐 agent pane 打印「屏幕被分类成什么」。**只读**，
# 不写任何 tmux option —— 它的用途是**证伪**，不是驱动状态。
#
# 用法：sh scripts/detect-probe.sh
#
# 判据链：探针说 wait，状态栏也该是 ◔；探针说 running，状态栏也该是 ▶。
# 两边不一致就说明规则还差一条，回到 lib/detect-rules.sh 补规则后重跑。
# 「eligible=no」表示这个 pane 不会被轮询接管（非交互进程或被摘出名单）。
set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export WHISTLE_ROOT

# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/core.sh"
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/detect-rules.sh"

_agent_cmds=$(whistle_conf '@whistle_agent_cmds')

whistle_tmux list-panes -a \
	-F '#{pane_id}|#{pane_current_command}|#{@whistle_src}|#{pane_tty}' 2>/dev/null |
	while IFS='|' read -r _pp_pane _pp_cmd _pp_src _pp_tty; do
		case "${_pp_pane:-}" in
		%*) ;;
		*) continue ;;
		esac

		_pp_kind=$(whistle_agent_kind "$_pp_cmd")
		[ -n "$_pp_kind" ] || continue

		# 前台进程组 = pid 等于 tpgid 的那个。tmux 只给得出进程名
		# （#{pane_current_command}），而「是不是 exec 子命令」只能从完整 argv 看。
		_pp_argv=$(ps -o pid=,tpgid=,command= -t "${_pp_tty#/dev/}" 2>/dev/null |
			awk '$1 == $2 { sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, ""); print; exit }')

		_pp_note=''
		whistle_detect_eligible "$_pp_cmd" "$_pp_argv" "$_agent_cmds" || _pp_note=' eligible=no'

		_pp_screen=$(whistle_tmux capture-pane -p -J -t "$_pp_pane" 2>/dev/null)
		_pp_state=$(printf '%s\n' "$_pp_screen" | whistle_classify_screen "$_pp_kind")
		_pp_rows=$(printf '%s\n' "$_pp_screen" | awk 'NF' | wc -l | tr -d ' ')

		[ -n "$_pp_state" ] || _pp_state='—'
		[ -n "${_pp_src:-}" ] || _pp_src='-'

		printf '%s  %-8s %-6s → %-9s (rows=%s%s)\n' \
			"$_pp_pane" "$_pp_kind" "$_pp_src" "$_pp_state" "$_pp_rows" "$_pp_note"
	done
