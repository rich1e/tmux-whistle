#!/bin/sh
# tmux-whistle 核心状态机。
#
# 由 bin/tmux-whistle 与 hooks/claude-code.sh source，不单独执行。
#
# 唯一状态写入点。所有 pane / window / global 的 user option 变更都从这里出去，
# 渲染（status-line.sh）与投递（deliver.sh）只读不写。
#
# 可测性约束：§4.0 的三个纯函数不得出现任何 tmux 调用。

# -- tmux 调用包装 ---------------------------------------------------------
#
# 优先级：显式 WHISTLE_TMUX_SOCKET（测试用）> $TMUX > $TMUX_SOCKET > 默认 socket。
#
# 为什么 $TMUX 排在 $TMUX_SOCKET 前面：TMUX_SOCKET 是 oh-my-tmux 写进 tmux
# 全局环境变量的，会被子进程**跨 server 继承**。在一个新起的隔离 server 里，
# 它可能仍指向用户正在用的那个 server —— 拿它定位会写错地方。
# $TMUX 由 tmux 在每个 pane 的进程环境里按 server 写好，是权威值
# （格式：<socket-path>,<pid>,<session-index>）。

whistle_tmux() {
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

whistle_now() {
  date +%s
}

# -- 状态常量 --------------------------------------------------------------

WHISTLE_STATES='running done wait error'

# window 聚合优先级：error > wait > done > running > ''
# 已读通知 = done / wait / error 三种
WHISTLE_NOTIFIED_STATES='done wait error'

# 消息进入 tmux format 前的最大长度（字符）
WHISTLE_MSG_MAX=80

# 正文（--body）的最大长度。它不进徽章，只进 @whistle_body，
# 所以可以比标题长得多 —— 但仍是有限额，pane option 不是垃圾桶。
WHISTLE_BODY_MAX=400

# -- running 的 Braille 动画帧 ------------------------------------------------
#
# 为什么需要动画：徽章与 status-right 里的串是**预先算好存在 global option 里**
# 的纯 format（原理 2：零 fork）。format 本身是静态的，tmux 没有「每 N 帧换一个
# 字符」的原生能力 —— 所以必须有个东西去改 @whistle_spin 这个帧号，
# 由 lib/spin.sh 负责（它只在真有 running 时活着，跑完自己退出）。
#
# 帧用四个独立变量而不是一个连写字符串：POSIX sh 里从多字节字符串里切出
# 第 N 个字符很不可靠（cut 按字节还是按字符取决于 locale）。加一帧要同时
# 加变量、加 whistle_spin_frame 的一支、加 WHISTLE_SPIN_FRAMES 的计数。

WHISTLE_SPIN_FRAMES=4
WHISTLE_SPIN_FRAME_0='◐'
WHISTLE_SPIN_FRAME_1='◓'
WHISTLE_SPIN_FRAME_2='◑'
WHISTLE_SPIN_FRAME_3='◒'

# whistle_spin_frame <序号> → 该帧的字符。越界一律回落到 0 帧。
#
# 纯函数（不碰 tmux）—— L1 单测能直接跑。
whistle_spin_frame() {
  case "${1:-0}" in
  0) printf '%s' "$WHISTLE_SPIN_FRAME_0" ;;
  1) printf '%s' "$WHISTLE_SPIN_FRAME_1" ;;
  2) printf '%s' "$WHISTLE_SPIN_FRAME_2" ;;
  3) printf '%s' "$WHISTLE_SPIN_FRAME_3" ;;
  *) printf '%s' "$WHISTLE_SPIN_FRAME_0" ;;
  esac
}

# whistle_spin_build → 供 tmux format 用的帧选择器
#
# ⚠️ 帧号是 **@whistle_spin_frame**，不是 @whistle_spin。
#    后者是 on/off 开关，用户可配；两者曾经撞成一个名字，结果开关被自己
#    写成 0、动画被永久判成「关」，而且界面上完全看不出异常。
#    凡是「用户可配的开关」与「插件自己写的状态」都必须用不同的 option 名。
#
# 输出形如：
#   #{?#{==:#{@whistle_spin_frame},0},◐,#{?#{==:#{@whistle_spin_frame},1},◓,…}}
#
# 三层嵌套条件式，结尾必须配平三个 '}' —— 少一个就是畸形 format，
# tmux 会**静默渲染成空字符串**。badge.bats 有配平用例守着。
#
# ⚠️ 这段**不能过 whistle_sanitize**（它会剔掉 # { } |，把整个 format 毁掉）。
#   输出直接拼进 format 串，不消毒 —— 它不是用户输入。
whistle_spin_build() {
  _sb0=$(whistle_spin_frame 0)
  _sb1=$(whistle_spin_frame 1)
  _sb2=$(whistle_spin_frame 2)
  _sb3=$(whistle_spin_frame 3)
  printf '#{?#{==:#{@whistle_spin_frame},%s},%s,#{?#{==:#{@whistle_spin_frame},%s},%s,#{?#{==:#{@whistle_spin_frame},%s},%s,%s}}}' \
    "$_sb0" "$_sb0" "$_sb1" "$_sb1" "$_sb2" "$_sb2" "$_sb3"
}

# 当前的帧号（读 option，非纯函数）
whistle_spin_index() {
  _si=$(whistle_tmux show -gqv '@whistle_spin_frame' 2> /dev/null) || _si=''
  case "$_si" in
  '' | *[!0-9]*) printf '0' ;;
  *) printf '%s' "$_si" ;;
  esac
}

# 下一个帧号（0 → 1 → 2 → 3 → 0 …）
whistle_spin_next() {
  _sn=$(($(whistle_spin_index) + 1))
  [ "$_sn" -lt "$WHISTLE_SPIN_FRAMES" ] || _sn=0
  printf '%s' "$_sn"
}

# 默认配置。option 未被显式设置时回落到这里；
# 用户用 `set -g @whistle_xxx` 覆盖后即以用户值为准。
# 派生值（@whistle_mark / @whistle_pending）不在表内，由插件生成。
WHISTLE_DEFAULTS='@whistle_enabled on
@whistle_badge on
@whistle_border on
@whistle_border_status off
@whistle_display on
@whistle_os off
@whistle_self off
@whistle_clear_on_focus on
@whistle_color_done #00af00
@whistle_color_wait #af8700
@whistle_color_error #d70000
@whistle_color_running #00af00
@whistle_icon_pending 🔔
@whistle_icon_done ✓
@whistle_icon_wait ◷
@whistle_icon_error ✗
@whistle_icon_running ▶
@whistle_spin on
@whistle_spin_interval 0.5
@whistle_display_ms 0
@whistle_debug off
@whistle_detect off
@whistle_detect_interval 15
@whistle_detect_idle 180'

# whistle_conf_default <option 名> → 默认表里的值（不查 tmux）
whistle_conf_default() {
  printf '%s\n' "$WHISTLE_DEFAULTS" | grep "^$1 " | head -1 | cut -d' ' -f2-
}

# whistle_conf <option 名> → 生效值（option 优先，缺省回落默认表）
whistle_conf() {
  _cv=$(whistle_tmux show -gqv "$1" 2> /dev/null) || _cv=''
  if [ -n "$_cv" ]; then
    printf '%s' "$_cv"
    return 0
  fi
  whistle_conf_default "$1"
}

# -- 纯函数（§4.0：不碰 tmux） ---------------------------------------------

# whistle_sanitize <任意字符串> [最大长度]
#
# 消息会被塞进 tmux format（display-menu 条目、window-status-format），
# 所以必须剔掉会破坏 format 的字符：
#   # { }   —— "#{...}" 会被二次展开；"{" "}" 在条件式里截断参数
#   |       —— 聚合时它是字段分隔符
#   控制字符 —— 会破坏状态栏单行渲染
# 逗号保留：它在 display-menu 的引号标签内是安全的，而消息里很常用。
#
# 第二参是长度上限，不传则用 WHISTLE_MSG_MAX —— **所有既有调用点不传第二参，
# 行为逐字不变**。正文（--body）传 WHISTLE_BODY_MAX。
#
# 输出最多 <最大长度> 个字符（依赖 UTF-8 locale 下 cut -c 按字符切）。
whistle_sanitize() {
  printf '%s' "${1:-}" \
    | tr '\n\r\t' '   ' \
    | tr -d '[:cntrl:]' \
    | tr -d '#{}|' \
    | tr -s ' ' \
    | cut -c "1-${2:-$WHISTLE_MSG_MAX}" \
    | sed -e 's/^ *//' -e 's/ *$//'
}

# whistle_rank <状态> → 0..4
# 未知状态一律当 0（等价于"无状态"），这样脏数据不会把徽章顶到高优先级。
whistle_rank() {
  case "${1:-}" in
  error) printf '4' ;;
  wait) printf '3' ;;
  done) printf '2' ;;
  running) printf '1' ;;
  *) printf '0' ;;
  esac
}

# 注意：POSIX sh 没有局部变量，函数里的临时变量会覆盖调用方的同名变量。
# 所以这里的循环变量用 _ws 前缀，与其它函数里读出来的 _s/_state 等隔离开。
whistle_is_state() {
  for _ws in $WHISTLE_STATES; do
    [ "$_ws" = "${1:-}" ] && return 0
  done
  unset _ws
  return 1
}

# whistle_is_notified <状态> → 该状态算不算"待用户处理"
whistle_is_notified() {
  for _ws in $WHISTLE_NOTIFIED_STATES; do
    [ "$_ws" = "${1:-}" ] && return 0
  done
  unset _ws
  return 1
}

# whistle_aggregate
#
# stdin  = tmux list-panes -F '#{pane_id}|#{@whistle}|#{@whistle_msg}' 的输出
# stdout = "<聚合态>|<消息>|<待处理数>|<胜出状态的 pane id>"
#
# 分隔符用 '|'（非空白），否则 read 会把连续分隔符折叠掉，
# 导致 @whistle 为空时后面的字段整体错位。消息在中间列，
# 所以即便含 '|' 也只会污染消息本身——而 sanitize 已经剔掉了它。
#
# 聚合规则：取 rank 最高的 pane 的状态与消息；全部为空时输出空状态。
#
# 第 4 列（pane id）放**末位**，不是第 2 位：whistle_recompute_global 用
# `cut -d'|' -f3` 取待处理数，放末位那里就不用改。
#
# pane 与状态必须由同一个循环产出，不能另扫一遍算 pane —— 「窗口显示哪个状态」
# 和「pane id 是谁」来自同一次判断；两次扫描可能选出不同的 pane。
whistle_aggregate() {
  _best_rank=0
  _best_state=''
  _best_msg=''
  _best_pane=''
  _pending=0
  while IFS='|' read -r _pane_id _state _msg || [ -n "${_pane_id:-}" ]; do
    # 合法 pane id 以 % 开头；跳过空行与解析失败的行
    case "${_pane_id:-}" in
    '%'*) ;;
    *) continue ;;
    esac
    _rank=$(whistle_rank "$_state")
    if whistle_is_notified "$_state"; then
      _pending=$((_pending + 1))
    fi
    if [ "$_rank" -gt "$_best_rank" ]; then
      _best_rank=$_rank
      _best_state=$_state
      _best_msg=$_msg
      _best_pane=$_pane_id
    fi
  done
  printf '%s|%s|%s|%s\n' "$_best_state" "$_best_msg" "$_pending" "$_best_pane"
}

# whistle_count_states
#
# stdin  = 与 whistle_aggregate 同一份 list-panes 输出
# stdout = "<running>|<done>|<wait>|<error>" 四态各有多少个 pane
#
# 与 whistle_aggregate 的分工：它算「窗口该显示哪个状态」+ 待处理总数，
# 这里算四态分布，给 status-right 的汇总段用。纯函数，不碰 tmux（§4.0）。
whistle_count_states() {
  awk -F'|' '
    $1 !~ /^%/ { next }
    $2 == "running" { r++ }
    $2 == "done"    { d++ }
    $2 == "wait"    { w++ }
    $2 == "error"   { e++ }
    END { printf "%d|%d|%d|%d\n", r, d, w, e }
  '
}

# -- 状态读写 --------------------------------------------------------------

# 解析目标 pane：显式 -t > $TMUX_PANE > 当前 client 的活动 pane
whistle_resolve_pane() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  whistle_tmux display-message -p '#{pane_id}' 2> /dev/null
}

# pane 所属窗口 id
whistle_pane_window() {
  whistle_tmux display-message -p -t "$1" '#{window_id}' 2> /dev/null
}

# whistle_state_set <state> <msg> [pane] [body]
#
# 一次 tmux 调用写完 5 个 pane option（KP-16：这条链里不能出现 run-shell，
# 否则会阻塞 tmux 命令队列）。
#
# @whistle_body 空值也要写 —— 否则上一轮的正文会留在 pane 上，
# 变成「这次没写正文，却显示着上次的」。
#
# stdout = 目标 pane id。诊断信息一律走 stderr，方便调用方做命令替换。
# 重算与投递由调用方编排（CLI），本函数只负责写。
whistle_state_set() {
  _state="$1"
  _msg=$(whistle_sanitize "$2")
  _pane=$(whistle_resolve_pane "$3")
  _body=$(whistle_sanitize "${4:-}" "$WHISTLE_BODY_MAX")

  if [ -z "$_pane" ]; then
    printf 'tmux-whistle: 找不到目标 pane（在 tmux 外运行时请用 -t <pane>）\n' >&2
    return 1
  fi
  if ! whistle_is_state "$_state"; then
    printf 'tmux-whistle: 未知状态 [%s]（可选：%s）\n' "$_state" "$WHISTLE_STATES" >&2
    return 1
  fi

  whistle_tmux set -p -t "$_pane" @whistle "$_state" \
    \; set -p -t "$_pane" @whistle_msg "$_msg" \
    \; set -p -t "$_pane" @whistle_at "$(whistle_now)" \
    \; set -p -t "$_pane" @whistle_src "${WHISTLE_SRC:-manual}" \
    \; set -p -t "$_pane" @whistle_body "$_body" || return 1

  printf '%s' "$_pane"
}

# whistle_state_clear <pane> → stdout = pane id
#
# 不用清 @whistle_win_pane：那是 window 级派生值，调用方随后会跑
# whistle_recompute_window 重算覆盖它（窗口内没有 pane 时重写成空串）。
# 这里多清一遍反而可能在窗口已不存在时报错。
whistle_state_clear() {
  _pane=$(whistle_resolve_pane "$1")
  [ -z "$_pane" ] && return 1

  whistle_tmux set -p -t "$_pane" -u @whistle \
    \; set -p -t "$_pane" -u @whistle_msg \
    \; set -p -t "$_pane" -u @whistle_at \
    \; set -p -t "$_pane" -u @whistle_src \
    \; set -p -t "$_pane" -u @whistle_body || return 1

  printf '%s' "$_pane"
}

# 只清除指定 pane 上指定的那一个状态（不匹配就什么都不做），并重算
#
# 用途：SessionEnd —— agent 退出了，`running` 这个"正在干活"的标记就该灭，
# 否则窗口会一直亮 ● 。**只清 running**：done/wait/error 是待处理通知，
# agent 退出不代表你已经看过。
#
# 返回值：真的清了就打印所属 window id（调用方据此释放边框/重绘），否则返回 1。
whistle_clear_pane_state() {
  _cps_pane=$(whistle_resolve_pane "${1:-}")
  [ -z "$_cps_pane" ] && return 1
  _cps_want="${2:-}"
  [ -n "$_cps_want" ] || return 1

  _cps_have=$(whistle_tmux show -pqv -t "$_cps_pane" @whistle 2> /dev/null) || _cps_have=''
  [ "$_cps_have" = "$_cps_want" ] || return 1

  whistle_state_clear "$_cps_pane" > /dev/null
  _cps_win=$(whistle_pane_window "$_cps_pane")
  [ -n "$_cps_win" ] && whistle_recompute_window "$_cps_win"
  whistle_recompute_global

  printf '%s' "$_cps_win"
  return 0
}

# 清除整个 window 内所有处于"待处理"状态的 pane（已读语义），并重算
#
# 分层约定：core 只管状态，不碰边框与重绘（那属于 deliver 层）。
# 所以这里不调 whistle_border_release / whistle_refresh_*，由调用方补上。
whistle_clear_window() {
  _win="${1:-}"
  [ -z "$_win" ] && return 1

  _pids=$(whistle_tmux list-panes -t "$_win" -F '#{pane_id}' 2> /dev/null)
  for _p in $_pids; do
    _s=$(whistle_tmux show -pqv -t "$_p" @whistle 2> /dev/null) || _s=''
    whistle_is_notified "$_s" && whistle_state_clear "$_p" > /dev/null
  done

  whistle_recompute_window "$_win"
  whistle_recompute_global
}

# 清除整个 server 内所有待处理状态
whistle_clear_all() {
  _pids=$(whistle_tmux list-panes -a -F '#{pane_id}' 2> /dev/null)
  for _p in $_pids; do
    _s=$(whistle_tmux show -pqv -t "$_p" @whistle 2> /dev/null) || _s=''
    whistle_is_notified "$_s" && whistle_state_clear "$_p" > /dev/null
  done

  _wins=$(whistle_tmux list-windows -a -F '#{window_id}' 2> /dev/null)
  for _w in $_wins; do
    whistle_recompute_window "$_w"
  done
  whistle_recompute_global
}

# -- 聚合重算 --------------------------------------------------------------

whistle_recompute_window() {
  _win="$1"
  _lines=$(whistle_tmux list-panes -t "$_win" \
    -F '#{pane_id}|#{@whistle}|#{@whistle_msg}' 2> /dev/null)

  _agg=$(printf '%s' "$_lines" | whistle_aggregate)
  _state=${_agg%%|*}
  _rest=${_agg#*|}
  _msg=${_rest%%|*}
  # 剩下 "<待处理数>|<胜出 pane>"：先摘数再摘 pane。
  # 窗口内没有 pane 时 list-panes 无输出 → 四列全空 → @whistle_win_pane
  # 被写成空串，自愈，不需要额外兜底。
  _rest=${_rest#*|}
  _count=${_rest%%|*}
  _pane=${_rest#*|}

  # window 级刻意用与 pane 级不同的名字（@whistle_win vs @whistle）。
  # 同名会造成影子遮蔽：清掉 pane 的 @whistle 后，查找会回退到 window 上的
  # 聚合值，于是 pane 看起来"清不掉"。
  #
  # @whistle_win_pane 记的是「这个窗口该亮的状态来自哪一格」。
  # 消费者是 jump（先判存活再 select-pane）。
  # 菜单**不读它** —— 菜单走 whistle_agent_windows 的第 5 列，那份数据更新鲜。
  # 两处用途不同，别把「测了 @whistle_win_pane」当成「测了菜单」。
  # 它由重算覆盖，所以 whistle_state_clear 不必清它。
  whistle_tmux setw -t "$_win" @whistle_win "$_state" \
    \; setw -t "$_win" @whistle_win_msg "$_msg" \
    \; setw -t "$_win" @whistle_win_count "$_count" \
    \; setw -t "$_win" @whistle_win_pane "$_pane"
}

whistle_recompute_global() {
  # 必须带 pane_id：whistle_aggregate 会跳过不以 '%' 开头的行，
  # 只传 @whistle 的话每一行都被丢掉，计数恒为 0。
  # 全局计数用不到消息，消息列留空。
  #
  # 一次 list-panes 喂两个纯函数：聚合态 / 待处理总数 + 四态分布。
  _cg_rows=$(whistle_tmux list-panes -a -F '#{pane_id}|#{@whistle}' 2> /dev/null)

  _n=$(printf '%s\n' "$_cg_rows" | whistle_aggregate | cut -d'|' -f3)
  _c=$(printf '%s\n' "$_cg_rows" | whistle_count_states)

  # 纯 shell 拆 "r|d|w|e"，避免四次 cut 子进程
  _cr=${_c%%|*}
  _rest=${_c#*|}
  _cd=${_rest%%|*}
  _rest=${_rest#*|}
  _cw=${_rest%%|*}
  _ce=${_rest#*|}

  whistle_tmux set -g @whistle_pending "${_n:-0}" \
    \; set -g @whistle_count_running "${_cr:-0}" \
    \; set -g @whistle_count_done "${_cd:-0}" \
    \; set -g @whistle_count_wait "${_cw:-0}" \
    \; set -g @whistle_count_error "${_ce:-0}"
}

# -- 查询 ------------------------------------------------------------------

# whistle_list_lines：输出 "<session>|<window>|<pane>|<state>|<msg>|<age>"
#
# 分隔符一律用 '|'（非空白）。若用 TAB/空格，read 会折叠连续分隔符，
# 消息为空时后面的列会整体前移一格。消息在倒数第二列且末列 age 恒有值，
# 仍不如 '|' 稳妥。
whistle_list_lines() {
  # 临时变量一律用 _l 前缀：whistle_is_notified 等被调函数也会用通用短名，
  # POSIX sh 里同名会被覆盖（曾经把 session 名覆盖成状态名）。
  whistle_tmux list-panes -a \
    -F '#{session_name}|#{window_name}|#{pane_id}|#{@whistle}|#{@whistle_msg}|#{@whistle_at}' \
    2> /dev/null | while IFS='|' read -r _ls _lwn _lpid _lst _lmsg _lat; do
    whistle_is_notified "$_lst" || continue
    _lage='-'
    if [ -n "${_lat:-}" ]; then
      _lage=$(($(whistle_now) - _lat))s
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$_ls" "$_lwn" "$_lpid" "$_lst" "$_lmsg" "$_lage"
  done
}

# 所有上报过状态的 (session, window_id, window_name, window_index, pane_id, state, msg)
#
# 与 whistle_pending_windows 的区别：**不过滤** whistle_is_notified，
# 所以 running 也在内 —— 菜单要能列出「哪些窗口有 agent」，而不只是「哪些在等我」。
#
# 按 window_id 去重，保留 rank 最高的那一行：list-panes -a 是 pane 粒度，
# 一个窗口开了多个 pane 时同一窗口会出现多次，菜单里就是重复条目。
# 第 5 列是那一行所属的 pane id，菜单据此 select-pane —— 窗口切成多格时
# 才不会落在隔壁格子。
whistle_agent_windows() {
  whistle_tmux list-panes -a \
    -F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{pane_id}|#{@whistle}|#{@whistle_msg}' \
    2> /dev/null | awk -F'|' '
    $6 == "" { next }
    {
      r = ($6 == "error") ? 4 : ($6 == "wait") ? 3 : ($6 == "done") ? 2 : 1
      if (!($2 in best)) order[++n] = $2
      if (!($2 in best) || r > best[$2]) {
        best[$2] = r
        line[$2] = $0
      }
    }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  '
}

# 待处理的 (session, window_id, window_name, window_index, state, msg)
# 供 display-menu 与 jump 使用。
whistle_pending_windows() {
  whistle_tmux list-panes -a \
    -F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{@whistle}|#{@whistle_msg}' \
    2> /dev/null | while IFS='|' read -r _ps _pwid _pwn _pwi _pst _pmsg; do
    whistle_is_notified "$_pst" || continue
    printf '%s|%s|%s|%s|%s|%s\n' "$_ps" "$_pwid" "$_pwn" "$_pwi" "$_pst" "$_pmsg"
  done
}

# -- running 动画帧的启停 ----------------------------------------------------
#
# 这些函数由 whistle_deliver 调用（每次状态变化都会经过那里）。
# 它们**不常驻**：真有 running 才拉起 lib/spin.sh，running 归零时它自己退出。
#
# pidfile 路径不含 $(id -u) —— 那是命令替换，会在每次 CLI 调用时 fork 一个进程。
# 用 $USER（环境变量，零 fork）。

whistle_spin_pidfile() {
  printf '%s/tmux-whistle-spin-%s.pid' \
    "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "${USER:-whistle}"
}

# 推进器脚本的位置。优先环境变量（测试用），其次 tmux 的 @whistle_root。
whistle_spin_script() {
  if [ -n "${WHISTLE_SPIN_SCRIPT:-}" ]; then
    printf '%s' "$WHISTLE_SPIN_SCRIPT"
    return 0
  fi
  _sss_root=$(whistle_tmux show -gqv '@whistle_root' 2> /dev/null) || _sss_root=''
  [ -n "$_sss_root" ] || return 1
  printf '%s/lib/spin.sh' "$_sss_root"
}

# 有 running 就确保推进器在跑；没有就停掉并把帧号复位。
#
# ⚠️ 复位写的是 **@whistle_spin_frame**（帧号），不是 @whistle_spin（开关）。
# 曾经写成后者，等于把开关自己置 0 —— 此后 whistle_conf 永远读不到 on，
# 动画被永久判成「关」，而界面上完全看不出异常（退回静态图标而已）。
# 「用户可配的开关」与「插件自己写的状态」必须用不同的 option 名。
whistle_spin_sync() {
  if [ "$(whistle_conf '@whistle_spin')" != on ]; then
    whistle_spin_stop
    whistle_tmux set -g @whistle_spin_frame 0 2> /dev/null || true
    return 0
  fi

  _sy_n=$(whistle_tmux show -gqv '@whistle_count_running' 2> /dev/null)
  case "$_sy_n" in
  '' | *[!0-9]*) _sy_n=0 ;;
  esac

  if [ "$_sy_n" -gt 0 ]; then
    whistle_spin_ensure
  else
    whistle_spin_stop
    # 复位成 0 帧：下次开始转时从头开始，位置可预期
    whistle_tmux set -g @whistle_spin_frame 0 2> /dev/null || true
  fi
}

# 单实例守卫：pidfile 里的进程还活着就什么都不做。
whistle_spin_ensure() {
  _se_f=$(whistle_spin_pidfile)
  if [ -f "$_se_f" ]; then
    _se_old=''
    # 用 read 而不是 $(cat ...)：后者每次都要 fork
    read -r _se_old < "$_se_f" 2> /dev/null || true
    if [ -n "$_se_old" ] && kill -0 "$_se_old" 2> /dev/null; then
      return 0
    fi
  fi

  _se_script=$(whistle_spin_script) || return 0
  [ -f "$_se_script" ] || return 0
  # 把 socket 显式带进去。run-shell 拉起的子进程继承的是 **tmux server 的环境**，
  # 而 setup.sh 导出的 WHISTLE_TMUX_SOCKET 只对 setup.sh 自己有效 ——
  # 不带的话 spin.sh 会回落到 $TMUX/$TMUX_SOCKET，可能连到别的 server，
  # 读不到 @whistle_count_running 就判定「没有 running」，起来即退。
  _se_sock=$(whistle_tmux display -p '#{socket_path}' 2> /dev/null) || _se_sock=''
  _se_cmd="sh '$_se_script' loop"
  [ -z "$_se_sock" ] || _se_cmd="WHISTLE_TMUX_SOCKET='$_se_sock' $_se_cmd"
  whistle_tmux run-shell -b "$_se_cmd" 2> /dev/null || true
}

whistle_spin_stop() {
  _sx_f=$(whistle_spin_pidfile)
  [ -f "$_sx_f" ] || return 0
  _sx_pid=''
  read -r _sx_pid < "$_sx_f" 2> /dev/null || true
  [ -n "$_sx_pid" ] && kill "$_sx_pid" 2> /dev/null
  rm -f "$_sx_f" 2> /dev/null || true
  return 0
}
