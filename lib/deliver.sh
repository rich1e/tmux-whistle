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

# 只有「有事等你」的状态才染边框。running / idle 不染：
# 它们是"agent 活着"的背景信息，每敲一次 prompt 就把边框换个颜色纯属噪声。
#
# ⚠️ 入参是**有效态**（@whistle_eff），但判定仍然正确，不需要改：
# 通知通道有值时 rank（done 3 / wait 4 / error 5）必然高过 running(2) / idle(1)，
# 所以「有效态是通知态」⟺「通知通道有事等你」。反过来有效态是 running / idle
# 时通知通道一定是空的 —— 不会漏染一条真通知。
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
  running) printf '运行中' ;;
  idle) printf '空闲' ;;
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

# terminal-notifier 的通知身份：socket 隔离 server，pane ID 隔离来源。
# 发送与撤回都必须走这里，不能各自拼一份，更不能用 -remove ALL。
whistle_os_group() {
  _og_pane="${1:-}"
  _og_socket=$(whistle_tmux display-message -p -t "$_og_pane" '#{socket_path}' 2> /dev/null)
  printf 'tmux-whistle:%s:%s' "$_og_socket" "$_og_pane"
}

# NSUserDefaults 会把这些首字符当成 property list 语法；上游约定加前导反斜杠。
whistle_tn_value() {
  case "${1:-}" in
  \[* | \(* | \{* | \"* | \'*) printf '\\%s' "$1" ;;
  *) printf '%s' "${1:-}" ;;
  esac
}

# -execute 会交给 /bin/sh -c。每个拼接值都独立 single-quote，
# whistle_sanitize 是 tmux format 消毒，不能拿来代替 shell quoting。
whistle_shell_quote() {
  printf "'"
  printf '%s' "${1:-}" | sed "s/'/'\"'\"'/g"
  printf "'"
}

# 只接受显式配置或可靠环境信息；未知终端宁可省略，也不猜 bundle ID。
whistle_os_app() {
  _oa_app=$(whistle_conf '@whistle_os_app')
  if [ -z "$_oa_app" ] && [ -n "${__CFBundleIdentifier:-}" ]; then
    _oa_app="$__CFBundleIdentifier"
  fi
  if [ -z "$_oa_app" ]; then
    case "${TERM_PROGRAM:-}" in
    iTerm.app) _oa_app='com.googlecode.iterm2' ;;
    Apple_Terminal) _oa_app='com.apple.Terminal' ;;
    esac
  fi
  printf '%s' "$_oa_app"
}

whistle_os_notify() {
  _on_win="$1"
  _on_state="$2"
  _on_msg="$3"
  _on_pane="${4:-}"

  [ "$(whistle_conf '@whistle_os')" = on ] || return 0
  case "$_on_state" in
  running | idle) return 0 ;;
  esac

  _on_sess=$(whistle_tmux display-message -p -t "$_on_win" '#{session_name}' 2> /dev/null)
  _on_wname=$(whistle_tmux display-message -p -t "$_on_win" '#{window_name}' 2> /dev/null)
  _on_title="tmux · $_on_sess"
  _on_body="$(whistle_state_label "$_on_state")"
  [ -n "$_on_msg" ] && _on_body="$_on_body: $_on_msg"
  _on_found=0

  if command -v terminal-notifier > /dev/null 2>&1; then
    _on_found=1
    # 优先：不经 Script Editor 中转，归属可控（KP-9 第 2 条问题不存在）。
    # POSIX sh 没有数组，先保存入参，再用 set -- 累积原始 argv。
    set -- -title "$(whistle_tn_value "$_on_title")" \
      -subtitle "$(whistle_tn_value "$_on_wname")" \
      -message "$(whistle_tn_value "$_on_body")"

    if [ -n "$_on_pane" ]; then
      _on_socket=$(whistle_tmux display-message -p -t "$_on_pane" '#{socket_path}' 2> /dev/null)
      _on_group=$(whistle_os_group "$_on_pane")
      set -- "$@" -group "$(whistle_tn_value "$_on_group")"

      # 老调用方可省略 pane；生产路径必须同时有绝对 CLI 与 socket 才生成点击回调。
      case "${WHISTLE_SELF:-}" in
      /*)
        if [ -n "$_on_socket" ]; then
          _on_tmux=$(command -v tmux 2> /dev/null)
          _on_tmux_dir=${_on_tmux%/*}
          _on_path="$_on_tmux_dir:/usr/bin:/bin:/usr/sbin:/sbin"
          _on_execute="PATH=$(whistle_shell_quote "$_on_path") WHISTLE_TMUX_SOCKET=$(whistle_shell_quote "$_on_socket") $(whistle_shell_quote "$WHISTLE_SELF") --desktop-jump $(whistle_shell_quote "$_on_pane")"
          set -- "$@" -execute "$(whistle_tn_value "$_on_execute")"
        fi
        ;;
      esac
    fi

    _on_app=$(whistle_os_app)
    if [ -n "$_on_app" ]; then
      set -- "$@" -activate "$(whistle_tn_value "$_on_app")"
    fi

    if terminal-notifier "$@" > /dev/null 2>&1; then
      return 0
    fi
    whistle_log "terminal-notifier 失败，尝试降级"
  fi

  if command -v osascript > /dev/null 2>&1; then
    _on_found=1
    # 注意：osascript 经系统的 Script Editor 应用路由通知。
    # 若 Script Editor 未获通知权限，这里会静默失败（KP-9）。
    if osascript -e "display notification \"$(whistle_osa_escape "$_on_body")\" with title \"$(whistle_osa_escape "$_on_title")\"" \
      > /dev/null 2>&1; then
      return 0
    fi
    whistle_log "osascript 失败（Script Editor 可能未授权，见 doctor），尝试降级"
  fi

  if command -v notify-send > /dev/null 2>&1; then
    _on_found=1
    if notify-send "$_on_title" "$_on_body" > /dev/null 2>&1; then
      return 0
    fi
    whistle_log "notify-send 失败"
  fi

  [ "$_on_found" -eq 1 ] || whistle_log "没有可用的桌面通知命令（terminal-notifier / osascript / notify-send）"
  # 桌面通道永远 fire-and-forget，失败不能影响状态写入或命令退出码。
  return 0
}

# 撤回只针对精确 group；@whistle_os off 也要能清掉此前已经送达的通知。
whistle_os_forget() {
  _of_pane="${1:-}"
  [ -n "$_of_pane" ] || return 0
  command -v terminal-notifier > /dev/null 2>&1 || return 0

  _of_group=$(whistle_os_group "$_of_pane")
  if ! terminal-notifier -remove "$(whistle_tn_value "$_of_group")" > /dev/null 2>&1; then
    whistle_log "terminal-notifier 撤回失败: $_of_group"
  fi
  return 0
}

# -- 编排 ------------------------------------------------------------------

# whistle_deliver <window> <有效态> <消息> <pane>
#
# 第二个参数是**有效态**（pane 的 @whistle_eff）—— 活动通道 @whistle 与
# 通知通道 @whistle_notice 按 rank 合成后的那一个值，由调用方（CLI）在写完状态
# 并重算之后读出来传入。第三个参数是**与它对应的消息**：有效态是通知态时是
# 通知消息，否则是活动消息。
#
# 第四个参数是触发本条通知的精确 pane，桌面 group 与点击跳转都直接使用它；
# 不能从 @whistle_win_pane 反推，那是窗口聚合赢家，不一定是本次来源。
# 空 pane 只保留普通通知能力，不生成猜测目标的回调。
#
# 徽章通道没有独立步骤：badge 的数据来自 window 上的 @whistle_win，
# 真正要做的是"让状态栏立刻重画"，即 whistle_refresh_sessions。
whistle_deliver() {
  [ "$(whistle_conf '@whistle_enabled')" = on ] || return 0

  # 自愈：主题重载可能把我们的状态栏补丁覆盖掉。
  # 在真正要显示的那一刻确保它在位 —— 这是唯一不依赖加载顺序的可靠时机。
  whistle_ensure_status_line

  whistle_border_paint "$1" "$2"
  whistle_border_status_apply "$1"
  whistle_refresh_sessions "$1"

  # 只有待处理状态才"打扰"用户：瞬时提示与桌面通知都会打断注意力。
  # running 是「agent 刚开始干活」，徽章亮一下就够了 —— 每敲一次 prompt
  # 就朝所有 session 推一条「运行中」纯属噪声。
  #
  # ⚠️ 换成有效态之后这个判定依然等价，因为 rank 里通知态永远高于活动态：
  # 「有事等你」⟺「有效态是通知态」。所以这里不需要再读 @whistle_notice ——
  # 多读一次反而会把「同一条通知」判成两种口径。
  if whistle_is_notified "$2"; then
    whistle_display_fanout "$1" "$2" "$3"
    whistle_os_notify "$1" "$2" "$3" "${4:-}"
  fi
}
