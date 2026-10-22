#!/bin/sh
# tmux-whistle 四渠道投递。
#
# 只读状态，不写状态（唯一写入点是 core.sh）。
# 四条通道互不依赖，各自留开关；投递永远排在状态写入之后。

# -- 调试日志 --------------------------------------------------------------
# @whistle_debug on 时写这里。KP-9 的静默失败就是靠它才能被看见。

whistle_log() {
  [ "$(whistle_conf '@whistle_debug')" = on ] || return 0
  _lf="${WHISTLE_LOG:-${TMPDIR:-/tmp}/tmux-whistle.log}"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >> "$_lf"
}

# -- 通道 A：破状态栏重画门控（KP-15） --------------------------------------
#
# man page：状态栏是 "automatically refreshed at interval if it has changed"。
# 改 @whistle 只把状态栏标脏，真正重画要等下一个 status-interval tick。
# 不显式 refresh 的话徽章会延迟最多 status-interval 秒出现 —— 那是功能缺陷。

whistle_refresh_sessions() {
  _win="${1:-}"
  if [ -z "$_win" ]; then
    whistle_refresh_all
    return 0
  fi

  _sess=$(whistle_tmux display-message -p -t "$_win" '#{session_name}' 2> /dev/null)
  [ -z "$_sess" ] && return 0

  _clients=$(whistle_tmux list-clients -F '#{client_name} #{client_session}' 2> /dev/null \
    | awk -v want="$_sess" '$2 == want { print $1 }')
  # 没有 attached client 时没人需要看，跳过
  for _c in $_clients; do
    whistle_tmux refresh-client -t "$_c" -S 2> /dev/null || true
  done
}

whistle_refresh_all() {
  _clients=$(whistle_tmux list-clients -F '#{client_name}' 2> /dev/null)
  for _c in $_clients; do
    whistle_tmux refresh-client -t "$_c" -S 2> /dev/null || true
  done
}

# -- 通道 B：pane 边框变色（KP-6 可还原） -----------------------------------

whistle_border_color() {
  case "${1:-}" in
  done) whistle_conf '@whistle_color_done' ;;
  wait) whistle_conf '@whistle_color_wait' ;;
  error) whistle_conf '@whistle_color_error' ;;
  *) printf '' ;;
  esac
}

whistle_border_paint() {
  _win="$1"
  _color=$(whistle_border_color "$2")
  [ -n "$_color" ] || return 0
  [ "$(whistle_conf '@whistle_border')" = on ] || return 0

  # 首次着色才记录原值。重复着色不能覆盖记录，否则会把我们的颜色当成"原值"。
  if [ -z "$(whistle_tmux show -wv -t "$_win" @whistle_border_painted 2> /dev/null)" ]; then
    _orig=$(whistle_tmux show -wv -t "$_win" pane-border-style 2> /dev/null) || _orig=''
    whistle_tmux setw -t "$_win" @whistle_border_orig "$_orig" \
      \; setw -t "$_win" @whistle_border_painted 1
  fi

  # 只染 inactive 边框：pane-active-border-style 不动，
  # 否则当前 pane 和其它 pane 无法区分，反而更乱。
  whistle_tmux setw -t "$_win" pane-border-style "fg=$_color"
}

whistle_border_release() {
  _win="${1:-}"
  [ -n "$_win" ] || return 0
  [ -n "$(whistle_tmux show -wv -t "$_win" @whistle_border_painted 2> /dev/null)" ] || return 0

  _orig=$(whistle_tmux show -wv -t "$_win" @whistle_border_orig 2> /dev/null) || _orig=''
  if [ -n "$_orig" ]; then
    whistle_tmux setw -t "$_win" pane-border-style "$_orig"
  else
    # 原值本来就是继承自全局（oh-my-tmux 用 setw -g），
    # 删掉窗口级覆盖即回到主题值
    whistle_tmux setw -t "$_win" -u pane-border-style
  fi

  whistle_tmux setw -t "$_win" -u @whistle_border_orig \
    \; setw -t "$_win" -u @whistle_border_painted
}

# prefix r 之后主题已重刷，此时残留的着色必须清掉，否则徽章永远消不掉
whistle_border_release_all() {
  _wins=$(whistle_tmux list-windows -a -F '#{window_id}' 2> /dev/null)
  for _w in $_wins; do
    whistle_border_release "$_w"
  done
}

# -- 通道 B2：pane 边框状态行（分屏时能分清是哪个 pane） --------------------

# 应用/还原 pane-border-status。它占每个 pane 顶部（或底部）一行，
# 所以默认关；打开时 @whistle_border_status 设为 top 或 bottom。
#
# 原值必须记录并还原：pane-border-status / pane-border-format 都是 window option，
# 一改就盖住用户主题（KP-6 同理）。
whistle_border_status_apply() {
  _win="${1:-}"
  [ -n "$_win" ] || return 0

  _mode=$(whistle_conf '@whistle_border_status')
  case "$_mode" in
  top | bottom) ;;
  *) return 0 ;;
  esac

  if [ -z "$(whistle_tmux show -wv -t "$_win" @whistle_bs_painted 2> /dev/null)" ]; then
    _os=$(whistle_tmux show -wv -t "$_win" pane-border-status 2> /dev/null) || _os=''
    _of=$(whistle_tmux show -wv -t "$_win" pane-border-format 2> /dev/null) || _of=''
    whistle_tmux setw -t "$_win" @whistle_bs_orig_status "$_os" \
      \; setw -t "$_win" @whistle_bs_orig_format "$_of" \
      \; setw -t "$_win" @whistle_bs_painted 1
  fi

  whistle_tmux setw -t "$_win" pane-border-status "$_mode" \
    \; setw -t "$_win" pane-border-format '#{pane_index}#{E:@whistle_pane_mark}'
}

whistle_border_status_release() {
  _win="${1:-}"
  [ -n "$_win" ] || return 0
  [ -n "$(whistle_tmux show -wv -t "$_win" @whistle_bs_painted 2> /dev/null)" ] || return 0

  _os=$(whistle_tmux show -wv -t "$_win" @whistle_bs_orig_status 2> /dev/null) || _os=''
  _of=$(whistle_tmux show -wv -t "$_win" @whistle_bs_orig_format 2> /dev/null) || _of=''

  if [ -n "$_os" ]; then
    whistle_tmux setw -t "$_win" pane-border-status "$_os"
  else
    whistle_tmux setw -t "$_win" -u pane-border-status
  fi
  if [ -n "$_of" ]; then
    whistle_tmux setw -t "$_win" pane-border-format "$_of"
  else
    whistle_tmux setw -t "$_win" -u pane-border-format
  fi

  whistle_tmux setw -t "$_win" -u @whistle_bs_orig_status \
    \; setw -t "$_win" -u @whistle_bs_orig_format \
    \; setw -t "$_win" -u @whistle_bs_painted
}

# prefix r 之后主题已重刷，残留必须清掉
whistle_border_status_release_all() {
  for _w in $(whistle_tmux list-windows -a -F '#{window_id}' 2> /dev/null); do
    whistle_border_status_release "$_w"
  done
}

# -- 通道 C：状态栏瞬时提示 -------------------------------------------------

whistle_state_label() {
  case "${1:-}" in
  done) printf '完成' ;;
  wait) printf '等待' ;;
  error) printf '错误' ;;
  *) printf '%s' "${1:-}" ;;
  esac
}

# 往一个 session 发瞬时提示。
#
# display-time 为 0 时不传 -d，让 tmux 用它自己的 display-time。
# -d 0 是"一直显示到被覆盖"，会和新消息互相顶掉，不能用。
whistle_display_to() {
  _dt_sess="$1"
  _dt_body="$2"
  _dt_dur=$(whistle_conf '@whistle_display_ms')
  if [ "$_dt_dur" != 0 ]; then
    whistle_tmux display-message -d "$_dt_dur" -t "$_dt_sess" "$_dt_body" 2> /dev/null || true
  else
    whistle_tmux display-message -t "$_dt_sess" "$_dt_body" 2> /dev/null || true
  fi
}

# 扇出到所有该看到的 session。
#
# @whistle_self 只管**发起方自己所在的**那个 session：on 才提示它。
# 扇出给其它 attached session 与该开关无关（原理 5：按 session 广播而非按
# client，这样同一 session 的多个 client 都能收到）。
whistle_display_fanout() {
  _win="$1"
  _state="$2"
  _msg="$3"

  [ "$(whistle_conf '@whistle_display')" = on ] || return 0

  _origin=$(whistle_tmux display-message -p -t "$_win" '#{session_name}' 2> /dev/null)
  _body="[$_origin] $(whistle_state_label "$_state")"
  [ -n "$_msg" ] && _body="$_body: $_msg"

  if [ "$(whistle_conf '@whistle_self')" = on ]; then
    whistle_display_to "$_origin" "$_body"
  fi

  for _s in $(whistle_tmux list-clients -F '#{client_session}' 2> /dev/null | sort -u); do
    [ "$_s" = "$_origin" ] && continue
    whistle_display_to "$_s" "$_body"
  done
}

# -- 通道 D：桌面系统通知（KP-9） -------------------------------------------

# AppleScript 字符串字面量转义
whistle_osa_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

whistle_os_notify() {
  _win="$1"
  _state="$2"
  _msg="$3"

  [ "$(whistle_conf '@whistle_os')" = on ] || return 0

  _sess=$(whistle_tmux display-message -p -t "$_win" '#{session_name}' 2> /dev/null)
  _title="tmux · $_sess"
  _body="$(whistle_state_label "$_state")"
  [ -n "$_msg" ] && _body="$_body: $_msg"

  if command -v terminal-notifier > /dev/null 2>&1; then
    # 优先：不经 Script Editor 中转，归属可控（KP-9 第 2 条问题不存在）
    terminal-notifier -title "$_title" -message "$_body" -group tmux-whistle \
      > /dev/null 2>&1 || whistle_log "terminal-notifier 失败"
  elif command -v osascript > /dev/null 2>&1; then
    # 注意：osascript 经系统的 Script Editor 应用路由通知。
    # 若 Script Editor 未获通知权限，这里会静默失败（KP-9）。
    osascript -e "display notification \"$(whistle_osa_escape "$_body")\" with title \"$(whistle_osa_escape "$_title")\"" \
      > /dev/null 2>&1 || whistle_log "osascript 失败（Script Editor 可能未授权，见 doctor）"
  elif command -v notify-send > /dev/null 2>&1; then
    notify-send "$_title" "$_body" > /dev/null 2>&1 || whistle_log "notify-send 失败"
  else
    whistle_log "没有可用的桌面通知命令（terminal-notifier / osascript / notify-send）"
  fi
}

# -- 编排 ------------------------------------------------------------------

# whistle_deliver <window> <state> <msg>
#
# 徽章通道没有独立步骤：badge 的数据来自 window 上的 @whistle，
# 真正要做的是"让状态栏立刻重画"，即 whistle_refresh_sessions。
whistle_deliver() {
  [ "$(whistle_conf '@whistle_enabled')" = on ] || return 0

  # 自愈：主题重载可能把我们的状态栏补丁覆盖掉。
  # 在真正要显示的那一刻确保它在位 —— 这是唯一不依赖加载顺序的可靠时机。
  whistle_ensure_status_line

  whistle_border_paint "$1" "$2"
  whistle_border_status_apply "$1"
  whistle_refresh_sessions "$1"
  whistle_display_fanout "$1" "$2" "$3"
  whistle_os_notify "$1" "$2" "$3"
}
