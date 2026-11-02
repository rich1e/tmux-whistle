#!/bin/sh
# tmux-whistle 核心状态机。
#
# 由 bin/tmux-whistle 与 hooks/claude-code.sh source，不单独执行。
#
# 唯一状态写入点。所有 pane / window / global 的 user option 变更都从这里出去，
# 渲染（status-line.sh）与投递（deliver.sh）只读不写。
#
# -- 状态模型：两条正交通道 -----------------------------------------------
#
#   活动通道   @whistle          running | idle | gone | ''
#     回答「这个 pane 里有没有 agent 在干活」
#   通知通道   @whistle_notice   done | wait | error | ''
#     回答「有没有事等你」
#
# 两条通道**互不排斥**：一个 pane 可以同时 running + done。
# 「有效显示状态」（@whistle_eff / @whistle_win）= 两者按 rank 取高者：
#   error 5 > wait 4 > done 3 > running 2 > idle 1 > 空 0
#
# 为什么拆两条：单槽模型下，任何一个事件到达都会把另一个覆盖掉 ——
# 后台 agent 结束时的 agent_completed 通知会把主 agent 的 running 顶成 done，
# 用户读完通知后整格被清空，再被「按进程发现空闲」判成 idle，
# 一个正在干活的 agent 就此显示成「空闲」，且零报错。
#
# 可测性约束：§4.0 的纯函数不得出现任何 tmux 调用。

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

# 活动通道的状态集合：这个 pane 里有没有 agent 在干活。
# running = 有 agent 正在干活；idle = 进程在、但闲着。
WHISTLE_ACTIVITY_STATES='running idle'

# 通知通道的状态集合：有没有事等你（done / wait / error）。
#
# ⚠️ 语义变了：以前这三个状态和 running/idle 挤在同一个槽里，
# 现在它们是**独立的一条通道**，与活动通道互不排斥。
WHISTLE_NOTIFIED_STATES='done wait error'

# 用户能报的全部状态（CLI 校验用）。gone 不在里面 ——
# 它不是用户能报的状态，只有 SessionEnd 会写它。
WHISTLE_STATES='running idle done wait error'

# gone = 这个 pane 上曾有 agent，现在已经退出。**不是**用户能报的状态，
# 只有 SessionEnd 会写它。
#
# 为什么需要它：SessionEnd 钩子跑的时候，agent 进程**还没退出**，
# pane_current_command 仍是 claude —— 那一刻若把状态清空，紧接着的重算会
# 又把它当成「空闲」，留下一盏永远灭不掉的 ◉。写成 gone 就不会：
# 「发现」只看空状态，gone 不是空的。
#
# 它的 rank 是 0（不算任何优先级）、不算待处理、徽章不显示、菜单不列。
# ⚠️ 它住在**活动通道**（@whistle），通知通道不受影响 ——
# agent 走了不等于你已经看过那条通知。
WHISTLE_GONE_STATE=gone

# 「临时」状态：跟着 agent 进程活，进程没了就该清。SessionEnd 只清这两种，
# 待处理通知一律留着等你处理。
WHISTLE_TRANSIENT_STATES='running idle'

# 消息进入 tmux format 前的最大长度（字符）
WHISTLE_MSG_MAX=80

# 正文（--body）的最大长度。它不进徽章，只进 @whistle_body，
# 所以可以比标题长得多 —— 但仍是有限额，pane option 不是垃圾桶。
WHISTLE_BODY_MAX=400

# -- running 的 Braille 动画帧 ------------------------------------------------
#
# 为什么需要动画：徽章与 status-right 里的串是**预先算好存在 global option 里**
# 的纯 format（原理 2：零 fork）。format 本身是静态的，tmux 没有「每 N 帧换一个
# 字符」的原生能力 —— 所以必须有个东西去改写「当前帧」，由 lib/spin.sh 负责
# （它只在真有 running 时活着，跑完自己退出）。
#
# 设计：插件把**当前帧字符本身**写进 @whistle_spin_char，format 里只写
#   #{@whistle_spin_char}
# 一层都不嵌套。早先的版本存帧号、再用 N 层嵌套条件式把帧号翻成字符 ——
# 4 帧还勉强，10 帧就要嵌 9 层，大括号必然配错；而配错了 tmux 只会
# **静默渲染成空字符串**，不报错。存字符而不是序号，帧数随便加。
#
# 三个 option 分工（别混，撞过一次名）：
#   @whistle_spin           on/off 开关，用户可配
#   @whistle_spin_char      当前帧字符，插件写
#   @whistle_spin_interval  帧间隔，用户可配
#
# 帧表用 for 循环遍历字面量，不切多字节字符串 —— POSIX sh 里从多字节串切
# 第 N 个字符不可靠（按字节还是按字符取决于 locale）。加帧只需往
# whistle_spin_next_char 的表里加一个字符。

# 第一帧。表异常时的兜底，也是复位时写入的值。
whistle_spin_first() {
  printf '%s' '⠋'
}

# whistle_spin_next_char <当前帧> → 下一帧
#
# 不在表里（未初始化 / 被手改坏）→ 回到第一帧；已是最后一帧 → 回到第一帧。
#
# 纯函数（不碰 tmux）—— L1 单测能直接跑。
whistle_spin_next_char() {
  _snc_seen=0
  for _snc_ch in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do
    if [ "$_snc_seen" = 1 ]; then
      printf '%s' "$_snc_ch"
      return 0
    fi
    [ "$_snc_ch" = "${1:-}" ] && _snc_seen=1
  done
  whistle_spin_first
}

# 当前帧字符（读 option，非纯函数）
whistle_spin_char() {
  _sc=$(whistle_tmux show -gqv '@whistle_spin_char' 2> /dev/null) || _sc=''
  [ -n "$_sc" ] || _sc=$(whistle_spin_first)
  printf '%s' "$_sc"
}

# whistle_spin_build → 供 tmux format 用的片段
#
# 只有一个条件式：option 为空时回落到第一帧，免得整格渲染成空白。
# ⚠️ 不要过 whistle_sanitize —— 它会剔掉 # { } |，把 format 毁成空串。
whistle_spin_build() {
  printf '#{?#{@whistle_spin_char},#{@whistle_spin_char},%s}' "$(whistle_spin_first)"
}

# -- 默认配置 --------------------------------------------------------------

# 默认配置。option 未被显式设置时回落到这里；
# 用户用 `set -g @whistle_xxx` 覆盖后即以用户值为准。
# 派生值（@whistle_mark / @whistle_pending / @whistle_eff …）不在表内，
# 由插件生成 —— 「用户可配的开关」与「插件自己写的状态」必须用不同的 option 名。
WHISTLE_DEFAULTS='@whistle_enabled on
@whistle_badge on
@whistle_border on
@whistle_border_status off
@whistle_display on
@whistle_os off
@whistle_os_app
@whistle_self off
@whistle_clear_on_focus on
@whistle_color_done #af5fff
@whistle_color_wait #af8700
@whistle_color_error #d70000
@whistle_color_running #00af00
@whistle_color_idle #8a8a8a
@whistle_color_pending #5fd7d7
@whistle_icon_pending ⚑
@whistle_icon_done ◆
@whistle_icon_wait ◔
@whistle_icon_error ⚠
@whistle_icon_running ▶
@whistle_icon_idle ◉
@whistle_spin on
@whistle_spin_interval 0.5
@whistle_recompute_every 60
@whistle_display_ms 0
@whistle_debug off
@whistle_agent_cmds claude claude.exe
@whistle_detect off
@whistle_detect_interval 15
@whistle_detect_idle 180
@whistle_sub_ttl 1800'

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

# whistle_rank <状态> → 0..5
# 未知状态一律当 0（等价于"无状态"），这样脏数据不会把徽章顶到高优先级。
#
# idle 必须严格低于 running：一个窗口里既有在跑的、又有空闲的 pane 时，
# 徽章要显示 ▶ 而不是 ◉。但它又必须 > 0 —— 否则「整个窗口的 agent 都空闲」
# 时 rank 赢不过初始的 0，徽章就什么都不显示了。
#
# ⚠️ 这个 rank 表同时被推导层（awk）与 whistle_effective_state 抄了一份，
# 两处必须一致 —— awk 里没法调 shell 函数。
whistle_rank() {
  case "${1:-}" in
  error) printf '5' ;;
  wait) printf '4' ;;
  done) printf '3' ;;
  running) printf '2' ;;
  idle) printf '1' ;;
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

# whistle_is_activity <状态> → 该状态是不是活动通道的状态
whistle_is_activity() {
  for _ws in $WHISTLE_ACTIVITY_STATES; do
    [ "$_ws" = "${1:-}" ] && return 0
  done
  unset _ws
  return 1
}

# whistle_is_notified <状态> → 该状态是不是通知通道的状态（「有事等你」）
whistle_is_notified() {
  for _ws in $WHISTLE_NOTIFIED_STATES; do
    [ "$_ws" = "${1:-}" ] && return 0
  done
  unset _ws
  return 1
}

# whistle_is_transient <状态> → 该状态算不算"跟着 agent 进程活"
whistle_is_transient() {
  for _ws in $WHISTLE_TRANSIENT_STATES; do
    [ "$_ws" = "${1:-}" ] && return 0
  done
  unset _ws
  return 1
}

# whistle_effective_state <活动态> <通知态> → 有效显示状态
#
# 取 rank 高者。两者都为空（或都是 gone 这种 rank 0 的值）→ 空串。
#
# 纯函数（不碰 tmux）。
whistle_effective_state() {
  _es_act="${1:-}"
  _es_not="${2:-}"
  _es_ra=$(whistle_rank "$_es_act")
  _es_rn=$(whistle_rank "$_es_not")
  if [ "$_es_rn" -gt "$_es_ra" ]; then
    printf '%s' "$_es_not"
  elif [ "$_es_ra" -gt 0 ]; then
    printf '%s' "$_es_act"
  else
    printf ''
  fi
}

# whistle_aggregate
#
# stdin  = 推导层（whistle_resolve_idle_panes）的输出，5 列：
#          <pane_id>|<有效态>|<通知态>|<活动态>|<消息>
# stdout = 6 列：
#          <有效态>|<消息>|<待处理数>|<胜出 pane>|<通知态>|<通知消息>
#
# 分隔符用 '|'（非空白），否则 read 会把连续分隔符折叠掉，
# 导致 @whistle 为空时后面的字段整体错位。
#
# ⚠️ **只读 5 个变量**：POSIX 的 read 在字段数多于变量数时，会把余下的
# （含分隔符）全塞进最后一个变量。消息列在**末位**，读满 5 个变量时它拿到的是
# 「余下的全部」——消息里带 '|' 也不会被截断。反过来若只读 4 个变量，
# 状态列就变成了「消息|别的」，消息会顶掉状态。
#
# 聚合规则：取**有效态** rank 最高的 pane 的有效态与消息；
# 全部为空时输出空状态。
#
# 第 4 列（pane id）放**末位那一段的第 4 位**，不是第 2 位：
# whistle_recompute_global 用 `cut -d'|' -f3` 取待处理数，位置不能变。
#
# 第 5、6 列是通知通道的态与消息：窗口徽章用有效态（@whistle_win），
# 而「这个窗口有没有事等我」看 @whistle_win_notice / @whistle_win_notice_msg。
#
# pane 与状态必须由同一个循环产出，不能另扫一遍算 pane —— 「窗口显示哪个状态」
# 和「pane id 是谁」来自同一次判断；两次扫描可能选出不同的 pane。
whistle_aggregate() {
  _best_rank=0
  _best_eff=''
  _best_msg=''
  _best_pane=''
  _best_notice=''
  _pending=0
  while IFS='|' read -r _pane_id _eff _notice _activity _msg || [ -n "${_pane_id:-}" ]; do
    # 合法 pane id 以 % 开头；跳过空行与解析失败的行
    case "${_pane_id:-}" in
    '%'*) ;;
    *) continue ;;
    esac
    _rank=$(whistle_rank "$_eff")
    if whistle_is_notified "$_notice"; then
      _pending=$((_pending + 1))
    fi
    if [ "$_rank" -gt "$_best_rank" ]; then
      _best_rank=$_rank
      _best_eff=$_eff
      _best_msg=$_msg
      _best_pane=$_pane_id
      _best_notice=$_notice
    fi
  done
  # 通知消息：胜出的 pane 有通知时，推导层选中的那条消息就是它的通知消息
  # （推导层「通知消息优先」）；没有通知就没有通知消息。
  _best_notice_msg=''
  if [ -n "$_best_notice" ]; then
    _best_notice_msg=$_best_msg
  fi
  printf '%s|%s|%s|%s|%s|%s\n' \
    "$_best_eff" "$_best_msg" "$_pending" "$_best_pane" "$_best_notice" "$_best_notice_msg"
}

# whistle_count_states
#
# stdin  = 与 whistle_aggregate 同一份推导输出（5 列或 9 列：
#          9 列的是菜单那份，pane id 在第 5 列）
# stdout = "<running>|<idle>|<done>|<wait>|<error>" 各有多少个 pane
#
# 与 whistle_aggregate 的分工：它算「窗口该显示哪个状态」+ 待处理总数，
# 这里算各状态分布，给 status-right 的汇总段用。纯函数，不碰 tmux（§4.0）。
#
# ⚠️ **分通道计数**：running / idle 数**活动通道**，done / wait / error 数
# **通知通道**。两组**互不排斥** —— 同一个 pane 一边在跑、一边有事找你，
# running 与 done 各计一次（▶1 ◆1 说的可能就是同一个 pane）。
#
# 字段顺序跟汇总段的显示顺序一致（running、idle、done、wait、error）——
# 两边对不上时最难看懂，调用方是按位置 cut 的。
#
# 列定位：pane id（以 % 开头的那一列）之后依次是有效态、通知态、活动态。
# 5 列那份 pane id 在第 1 列，9 列那份在第 5 列 —— 所以不写死列号，
# 按 pane id 那一列定位，两种布局都能吃。
whistle_count_states() {
  awk -F'|' '
    function pane_col(  k) {
      for (k = 1; k <= NF; k++) if ($k ~ /^%[0-9]+$/) return k
      return 0
    }
    {
      p = pane_col()
      if (p == 0) next
      notice = $(p + 2)
      activity = $(p + 3)
      if (activity == "running") _r++
      else if (activity == "idle") _i++
      if (notice == "done") _d++
      else if (notice == "wait") _w++
      else if (notice == "error") _e++
    }
    END { printf "%d|%d|%d|%d|%d\n", _r + 0, _i + 0, _d + 0, _w + 0, _e + 0 }
  '
}

# whistle_resolve_idle_panes <agent 命令名清单> <状态列号> [前导列数]
#
# stdin  = list-panes 的输出（字段用 | 分隔），每行一个 pane
#          **最后一列是前台进程名**（`#{pane_current_command}`）
#          状态块从第 <sc> 列开始：
#            $sc    活动态（@whistle）
#            $sc+1  通知态（@whistle_notice）
#            $sc+2  活动消息（@whistle_msg）
#            $sc+3  通知消息（@whistle_notice_msg）
#            $sc+4  子 agent 标记的过期时间戳（**可选列**，见下）
#          最后一列（$NF）始终是命令名。
# stdout = 状态块被重写成四列，前导列原样：
#            $sc    有效态（活动态与通知态取 rank 高者）
#            $sc+1  通知态（原样）
#            $sc+2  活动态（推导后）
#            $sc+3  选中的消息（通知消息优先，空则活动消息）—— **必须在末位**
#
# 为什么要有这一层：插件是推送式的，只认 hook 上报过的东西。可是一个刚被
# resurrect 拉起来的 `claude --continue`，它的 SessionStart 还没送到时，
# 那个 pane 看起来是「空的」；同理，一轮做完、通知被读掉之后那一格也会变空 ——
# 而 agent 其实还活着、还在提示符前等着。
#
# 「哪些进程算 agent」由用户自己配（@whistle_agent_cmds）。判据是 tmux 自己的
# 事实（这个 pane 的前台跑着谁），不是从屏幕文字里猜提示符。
#
# 纯函数：agent 清单由调用方传进来 —— 读 tmux option 是 tmux 调用，不能进纯
# 函数（L1 单测要能脱离 tmux 跑）。同理，now 由调用方用环境变量 WHISTLE_NOW
# 注入（不注入则取当前时间；date 不是 tmux 调用，但注入后 L1 单测才可复现）。
#
# ⚠️ **命令列取最后一列（$(NF)），不是某个固定的列号**。固定列号会被消息里的
# '|' 带偏（消息本身不该有 '|，但那不是这里该依赖的保证）；而最后一列永远是
# 命令名 —— 状态列在消息之前、命令列在消息之后，两边都不受消息内容影响。
#
# ⚠️ **命令列被整列去掉，不是留在流里**。下游（whistle_aggregate、菜单的
# `read`）按固定列数读，而 POSIX 的 read 在字段数多于变量数时会把余下的
# （含分隔符）全塞进最后一个变量 —— 留着这一列，消息列就会变成
# 「消息|进程名」，而 @whistle_win_msg 与菜单标签会把它原样显示出去。
#
# ⚠️ **子 agent 标记列（$sc+4）是可选的**：给了就用（没给就是没有子 agent）。
# 它存的是**过期时间戳**，0 表示永不过期。过期不需要写回 —— 推导层按时间戳
# 判断即可，这样漏报「子 agent 结束」时标记会自己过期回落，
# 而不会永久亮着 ▶。
whistle_resolve_idle_panes() {
  _rip_cmds="${1:-}"
  _rip_sc="${2:-}"
  _rip_lead="${3:-0}"

  [ "$_rip_sc" -gt 0 ] 2> /dev/null || return 1

  _rip_now="${WHISTLE_NOW:-}"
  [ -n "$_rip_now" ] || _rip_now=$(whistle_now)

  # ⚠️ OFS 必须显式设成 '|'：awk 里**给字段赋值会把 $0 重建一遍**，分隔符用
  # OFS（默认是空格）。不设的话输出会变成空格分隔，下游按 '|' 切列全错位。
  #
  # 去掉整列是无损的：按 '|' 切开再按 '|' 拼回去，消息里的 '|' 原样还在。
  awk -F'|' -v OFS='|' -v cmds="$_rip_cmds" -v sc="$_rip_sc" \
    -v lead="$_rip_lead" -v now="$_rip_now" '
    # ⚠️ 这个 rank 表必须与 whistle_rank 逐项一致（awk 里没法调 shell 函数）。
    function rank(s) {
      if (s == "error") return 5
      if (s == "wait") return 4
      if (s == "done") return 3
      if (s == "running") return 2
      if (s == "idle") return 1
      return 0
    }
    BEGIN {
      n = split(cmds, a, " ")
      for (j = 1; j <= n; j++) if (a[j] != "") list[a[j]] = 1
      # 前导列数：给了就用给的，没给就按「状态块前面全是前导列」算。
      # 状态块必须落在 $sc，所以前导列最多 sc-1 列。
      if (lead <= 0) lead = sc - 1
      if (lead > sc - 1) lead = sc - 1
    }
    {
      # 命令列永远是最后一列
      cmd = $NF
      # 子 agent 标记列（可选）：过期时间戳，0 = 永不过期。
      # 只认纯数字 —— 消息里带 | 时列数会飘，宁可漏判也不能把消息当时间戳。
      subexp = ""
      if (NF >= sc + 5 && $(sc + 4) ~ /^[0-9]+$/) subexp = $(sc + 4)
      notice = $(sc + 1)
      amsg = $(sc + 2)
      nmsg = $(sc + 3)
      act = $sc

      # 活动态推导：没上报过、但前台跑着 agent → idle
      if (act == "" && (cmd in list)) act = "idle"
      # 子 agent 还在跑 → 活动态强制 running（哪怕主回合已经结束）
      if (subexp != "" && (subexp + 0 == 0 || now + 0 < subexp + 0)) act = "running"

      # 有效态 = rank 高者（与 whistle_effective_state 一致）
      ra = rank(act)
      rn = rank(notice)
      if (rn > ra) eff = notice
      else if (ra > 0) eff = act
      else eff = ""

      # 选中的消息：通知消息优先，空则活动消息
      msg = (nmsg != "") ? nmsg : amsg

      # 重建输出：前导列原样 + 有效态 + 通知态 + 活动态 + 消息
      m = 0
      for (k = 1; k <= lead; k++) { m++; f[m] = $k }
      m++; f[m] = eff
      m++; f[m] = notice
      m++; f[m] = act
      m++; f[m] = msg
      out = f[1]
      for (k = 2; k <= m; k++) out = out OFS f[k]
      print out
    }
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

# whistle_desktop_jump <pane>
#
# 桌面通知点击后的严格跳转：先验证 pane，再在点击当下选择最近活动的 client，
# 依次 switch-client → select-window → select-pane。任何一步失败都原样保留通知，
# 由调用方决定后续清除；本函数自身绝不清状态。
whistle_desktop_jump() {
  _dj_pane="${1:-}"
  _dj_target=''
  if [ -n "$_dj_pane" ]; then
    _dj_target=$(whistle_tmux display-message -p -t "$_dj_pane" \
      '#{window_id}|#{session_name}' 2> /dev/null) || _dj_target=''
  fi
  _dj_win=${_dj_target%%|*}
  _dj_session=${_dj_target#*|}
  if [ -z "$_dj_target" ] || [ -z "$_dj_win" ] || [ -z "$_dj_session" ] \
    || [ "$_dj_session" = "$_dj_target" ]; then
    printf 'tmux-whistle: 找不到目标 pane [%s]\n' "$_dj_pane" >&2
    return 1
  fi

  _dj_clients=$(whistle_tmux list-clients -F '#{client_name}|#{client_activity}' \
    2> /dev/null) || _dj_clients=''
  _dj_client=$(printf '%s\n' "$_dj_clients" | awk -F'|' '
    $1 != "" && $2 ~ /^[0-9]+$/ {
      if (!found || $2 + 0 > activity) {
        found = 1
        name = $1
        activity = $2 + 0
      }
    }
    END { if (found) print name }
  ')
  if [ -z "$_dj_client" ]; then
    printf 'tmux-whistle: 桌面跳转失败：没有 attached client\n' >&2
    return 1
  fi

  if ! whistle_tmux switch-client -c "$_dj_client" -t "$_dj_session" 2> /dev/null; then
    printf 'tmux-whistle: 桌面跳转失败：switch-client\n' >&2
    return 1
  fi
  if ! whistle_tmux select-window -t "$_dj_win" 2> /dev/null; then
    printf 'tmux-whistle: 桌面跳转失败：select-window\n' >&2
    return 1
  fi
  if ! whistle_tmux select-pane -t "$_dj_pane" 2> /dev/null; then
    printf 'tmux-whistle: 桌面跳转失败：select-pane\n' >&2
    return 1
  fi
}

# whistle_activity_set <running|idle|gone> [pane] [src] [msg] [body]
#
# 写**活动通道**：@whistle / @whistle_msg / @whistle_at / @whistle_src / @whistle_body
#
# 一次 tmux 调用写完 5 个 pane option（KP-16：这条链里不能出现 run-shell，
# 否则会阻塞 tmux 命令队列）。
#
# @whistle_body 空值也要写 —— 否则上一轮的正文会留在 pane 上，
# 变成「这次没写正文，却显示着上次的」。
#
# **绝不碰通知通道**：活动与通知是两条正交的通道，
# 写 idle（SessionStart 恢复会话）不能替用户把没读的 ◆ / ◔ / ⚠ 抹掉。
#
# **写 idle 时若子 agent 标记仍有效，实际写 running** —— 子 agent 还在跑，
# 这个 pane 就还在干活，显示空闲是失真。
#
# stdout = 目标 pane id。诊断信息一律走 stderr，方便调用方做命令替换。
# 重算与投递由调用方编排（CLI），本函数只负责写。
whistle_activity_set() {
  _as_state="${1:-}"
  _as_pane=$(whistle_resolve_pane "${2:-}")
  _as_src="${3:-${WHISTLE_SRC:-manual}}"
  _as_msg=$(whistle_sanitize "${4:-}")
  _as_body=$(whistle_sanitize "${5:-}" "$WHISTLE_BODY_MAX")

  if [ -z "$_as_pane" ]; then
    printf 'tmux-whistle: 找不到目标 pane（在 tmux 外运行时请用 -t <pane>）\n' >&2
    return 1
  fi
  if [ "$_as_state" != running ] && [ "$_as_state" != idle ] && [ "$_as_state" != gone ]; then
    printf 'tmux-whistle: 未知活动态 [%s]（可选：running idle gone）\n' "$_as_state" >&2
    return 1
  fi

  # 子 agent 还在跑 → idle 实际写成 running
  #
  # @whistle_sub 存的是**过期时间戳**，所以判据是「现在还没过那个点」。
  # 0 = 永不过期（TTL 配成 0）。
  if [ "$_as_state" = idle ]; then
    _as_sub=$(whistle_tmux show -pqv -t "$_as_pane" @whistle_sub 2> /dev/null) || _as_sub=''
    case "$_as_sub" in
    '' | *[!0-9]*) ;;
    0) _as_state=running ;;
    *)
      _as_now=$(whistle_now)
      if [ "$_as_now" -lt "$_as_sub" ]; then
        _as_state=running
      fi
      ;;
    esac
  fi

  whistle_tmux set -p -t "$_as_pane" @whistle "$_as_state" \
    \; set -p -t "$_as_pane" @whistle_msg "$_as_msg" \
    \; set -p -t "$_as_pane" @whistle_at "$(whistle_now)" \
    \; set -p -t "$_as_pane" @whistle_src "$_as_src" \
    \; set -p -t "$_as_pane" @whistle_body "$_as_body" || return 1

  printf '%s' "$_as_pane"
}

# whistle_notice_set <done|wait|error> <msg> <body> [pane]
#
# 写**通知通道**：@whistle_notice / @whistle_notice_msg /
# @whistle_notice_body / @whistle_notice_at
#
# 与活动通道互不影响：写通知不动 @whistle，写活动不动 @whistle_notice。
# 这正是双通道模型的目的 —— 后台 agent 完成的通知不会再顶掉主 agent 的 running。
whistle_notice_set() {
  _ns_state="${1:-}"
  _ns_msg=$(whistle_sanitize "${2:-}")
  _ns_body=$(whistle_sanitize "${3:-}" "$WHISTLE_BODY_MAX")
  _ns_pane=$(whistle_resolve_pane "${4:-}")

  if [ -z "$_ns_pane" ]; then
    printf 'tmux-whistle: 找不到目标 pane（在 tmux 外运行时请用 -t <pane>）\n' >&2
    return 1
  fi
  if ! whistle_is_notified "$_ns_state"; then
    printf 'tmux-whistle: 未知通知态 [%s]（可选：%s）\n' "$_ns_state" "$WHISTLE_NOTIFIED_STATES" >&2
    return 1
  fi

  whistle_tmux set -p -t "$_ns_pane" @whistle_notice "$_ns_state" \
    \; set -p -t "$_ns_pane" @whistle_notice_msg "$_ns_msg" \
    \; set -p -t "$_ns_pane" @whistle_notice_body "$_ns_body" \
    \; set -p -t "$_ns_pane" @whistle_notice_at "$(whistle_now)" || return 1

  printf '%s' "$_ns_pane"
}

# whistle_sub_set <start|stop> [pane]
#
# 子 agent 标记：@whistle_sub 存**过期时间戳**（epoch 秒），0 = 永不过期。
#
# start：写 @whistle_sub = now + @whistle_sub_ttl。
#   活动态由**推导层**合成（标记有效 → 活动态强制 running），
#   这里不写 @whistle —— 写了就分不清「主回合在跑」和「只是子 agent 在跑」，
#   子 agent 结束（stop）时那份 running 会留下来变 permanent。
#
# stop：清 @whistle_sub。活动态是否回落到 idle 由合成规则处理
#   （@whistle 是什么就显示什么）。
#
# 过期不需要写回：推导层按时间戳判断，标记会自己过期回落。
whistle_sub_set() {
  _ss_act="${1:-}"
  _ss_pane=$(whistle_resolve_pane "${2:-}")

  if [ -z "$_ss_pane" ]; then
    printf 'tmux-whistle: 找不到目标 pane（在 tmux 外运行时请用 -t <pane>）\n' >&2
    return 1
  fi

  case "$_ss_act" in
  start)
    _ss_ttl=$(whistle_conf '@whistle_sub_ttl')
    case "$_ss_ttl" in
    '' | *[!0-9]*) _ss_ttl=1800 ;;
    esac
    if [ "$_ss_ttl" -eq 0 ]; then
      _ss_until=0
    else
      _ss_until=$(($(whistle_now) + _ss_ttl))
    fi
    whistle_tmux set -p -t "$_ss_pane" @whistle_sub "$_ss_until" || return 1
    ;;
  stop)
    whistle_tmux set -p -t "$_ss_pane" @whistle_sub '' || return 1
    ;;
  *)
    printf 'tmux-whistle: 未知的子 agent 标记动作 [%s]（可选：start stop）\n' "$_ss_act" >&2
    return 1
    ;;
  esac

  printf '%s' "$_ss_pane"
}

# whistle_state_set <state> <msg> [pane] [body]
#
# 兼容入口：按状态分流到两条通道。
#   running / idle / gone → 活动通道（whistle_activity_set）
#   done / wait / error   → 通知通道（whistle_notice_set）
#
# 新代码请直接用 whistle_activity_set / whistle_notice_set ——
# 这个入口存在的意义是让还没改造的调用方（关键词兜底轮询等）继续可用。
whistle_state_set() {
  _st_state="${1:-}"
  _st_msg="${2:-}"
  _st_pane="${3:-}"
  _st_body="${4:-}"

  case "$_st_state" in
  running | idle | gone)
    whistle_activity_set "$_st_state" "$_st_pane" "${WHISTLE_SRC:-manual}" \
      "$_st_msg" "$_st_body"
    ;;
  done | wait | error)
    whistle_notice_set "$_st_state" "$_st_msg" "$_st_body" "$_st_pane"
    ;;
  *)
    printf 'tmux-whistle: 未知状态 [%s]（可选：%s）\n' "$_st_state" "$WHISTLE_STATES" >&2
    return 1
    ;;
  esac
}

# whistle_state_clear <pane> → stdout = pane id
#
# **只清通知通道**（@whistle_notice*），绝不碰活动通道（@whistle）。
#
# 这是本次最关键的语义修正：以前「已读」清的是整个 @whistle，
# 于是「在跑 → 空闲」的降级有了执行者 —— 主 agent 明明还在干活，
# 用户切进窗口读掉一条通知，活动态就被清空，接着被「按进程发现空闲」
# 判成 idle，徽章从此显示「空闲」，且零报错。
#
# 活动通道只由 whistle_activity_set / whistle_state_gone 改。
#
# 不用清 @whistle_win_pane：那是 window 级派生值，调用方随后会跑
# whistle_recompute_window 重算覆盖它（窗口内没有 pane 时重写成空串）。
# 这里多清一遍反而可能在窗口已不存在时报错。
whistle_state_clear() {
  _pane=$(whistle_resolve_pane "$1")
  [ -z "$_pane" ] && return 1

  whistle_tmux set -p -t "$_pane" -u @whistle_notice \
    \; set -p -t "$_pane" -u @whistle_notice_msg \
    \; set -p -t "$_pane" -u @whistle_notice_body \
    \; set -p -t "$_pane" -u @whistle_notice_at || return 1

  # deliver 层可选：core 独立加载时没有这个函数。tmux 已读成功后
  # 才撤回对应桌面通知；撤回失败不回滚状态，也不污染 stdout 的 pane id。
  if command -v whistle_os_forget > /dev/null 2>&1; then
    whistle_os_forget "$_pane" > /dev/null 2>&1 || true
  fi

  printf '%s' "$_pane"
}

# whistle_activity_clear <pane> → stdout = pane id
#
# 清**活动通道**（@whistle*），通知通道不动。
# 与 whistle_state_clear 是一对：前者清活动，后者清通知。
whistle_activity_clear() {
  _ac_pane=$(whistle_resolve_pane "${1:-}")
  [ -z "$_ac_pane" ] && return 1

  whistle_tmux set -p -t "$_ac_pane" -u @whistle \
    \; set -p -t "$_ac_pane" -u @whistle_msg \
    \; set -p -t "$_ac_pane" -u @whistle_at \
    \; set -p -t "$_ac_pane" -u @whistle_src \
    \; set -p -t "$_ac_pane" -u @whistle_body || return 1

  printf '%s' "$_ac_pane"
}

# whistle_state_gone <pane> → stdout = pane id
#
# 把**活动通道**标成「agent 已退出」（WHISTLE_GONE_STATE）。
# **通知通道不动** —— agent 走了不代表你已经看过那条通知。
#
# 为什么不直接清空：SessionEnd 钩子跑的时候 agent 进程还没退出，
# pane_current_command 仍是 claude —— 清空的话，紧接着的重算会按
# 「前台跑着 agent」把它当成空闲，留下一盏灭不掉的 ◉。写成 gone 就绕开了。
#
# 与 whistle_activity_clear 的区别：清空 = 「这里什么状态都没有」，
# gone = 「这里曾有 agent，已经走了」。后者还留着信息，且不会被
# 「按进程发现空闲」重新认成 agent。
#
# 正文（@whistle_body）一并清掉：agent 都走了，那段回复不再属于任何待处理项。
whistle_state_gone() {
  _sg_pane=$(whistle_resolve_pane "${1:-}")
  [ -z "$_sg_pane" ] && return 1

  whistle_tmux set -p -t "$_sg_pane" @whistle "$WHISTLE_GONE_STATE" \
    \; set -p -t "$_sg_pane" -u @whistle_msg \
    \; set -p -t "$_sg_pane" -u @whistle_at \
    \; set -p -t "$_sg_pane" -u @whistle_body || return 1

  printf '%s' "$_sg_pane"
}

# 只清除指定 pane 上指定的那一个**活动态**（不匹配就什么都不做），并重算
#
# 用途：需要「当前值恰好是 X 才清」的场景，比如 restart 时清掉 running。
#
# 返回值：真的清了就打印所属 window id（调用方据此释放边框/重绘），否则返回 1。
whistle_clear_pane_state() {
  _cps_pane=$(whistle_resolve_pane "${1:-}")
  [ -z "$_cps_pane" ] && return 1
  _cps_want="${2:-}"
  [ -n "$_cps_want" ] || return 1

  _cps_have=$(whistle_tmux show -pqv -t "$_cps_pane" @whistle 2> /dev/null) || _cps_have=''
  [ "$_cps_have" = "$_cps_want" ] || return 1

  whistle_activity_clear "$_cps_pane" > /dev/null
  _cps_win=$(whistle_pane_window "$_cps_pane")
  [ -n "$_cps_win" ] && whistle_recompute_window "$_cps_win"
  whistle_recompute_global

  printf '%s' "$_cps_win"
  return 0
}

# whistle_forget_agent <pane> → stdout = 所属 window id
#
# agent 退出了（SessionEnd）：
#   活动通道是临时状态（running/idle）或空 → 写成 gone（见 whistle_state_gone）。
#   通知通道**原样留着** —— agent 退出不代表你已经看过，那几条要留到你处理。
#   子 agent 标记清掉（主 agent 都走了，子 agent 也不该再算「在干活」）。
#
# 无论哪种都重算：状态变了，徽章与计数得跟上。
whistle_forget_agent() {
  _fa_pane=$(whistle_resolve_pane "${1:-}")
  [ -z "$_fa_pane" ] && return 1

  _fa_have=$(whistle_tmux show -pqv -t "$_fa_pane" @whistle 2> /dev/null) || _fa_have=''
  if whistle_is_transient "$_fa_have" || [ -z "$_fa_have" ]; then
    whistle_state_gone "$_fa_pane" > /dev/null
  fi
  whistle_sub_set stop "$_fa_pane" > /dev/null

  _fa_win=$(whistle_pane_window "$_fa_pane")
  [ -n "$_fa_win" ] && whistle_recompute_window "$_fa_win"
  whistle_recompute_global

  printf '%s' "$_fa_win"
  return 0
}

# 清除整个 window 内所有处于"待处理"状态的 pane（已读语义），并重算
#
# ⚠️ **只清通知通道**：切进窗口 = 已读，读掉的是「有事等你」，
# 不是「这个 pane 有没有 agent 在干活」。动 @whistle 就是把正在干活的
# agent 降级成空闲 —— 本次要修的正是这条。
#
# 分层约定：core 只管状态，不碰边框与重绘（那属于 deliver 层）。
# 所以这里不调 whistle_border_release / whistle_refresh_*，由调用方补上。
whistle_clear_window() {
  _win="${1:-}"
  [ -z "$_win" ] && return 1

  _pids=$(whistle_tmux list-panes -t "$_win" -F '#{pane_id}' 2> /dev/null)
  for _p in $_pids; do
    _s=$(whistle_tmux show -pqv -t "$_p" @whistle_notice 2> /dev/null) || _s=''
    whistle_is_notified "$_s" && whistle_state_clear "$_p" > /dev/null
  done

  whistle_recompute_window "$_win"
  whistle_recompute_global
}

# 清除整个 server 内所有待处理状态（同样只清通知通道）
whistle_clear_all() {
  _pids=$(whistle_tmux list-panes -a -F '#{pane_id}' 2> /dev/null)
  for _p in $_pids; do
    _s=$(whistle_tmux show -pqv -t "$_p" @whistle_notice 2> /dev/null) || _s=''
    whistle_is_notified "$_s" && whistle_state_clear "$_p" > /dev/null
  done

  _wins=$(whistle_tmux list-windows -a -F '#{window_id}' 2> /dev/null)
  for _w in $_wins; do
    whistle_recompute_window "$_w"
  done
  whistle_recompute_global
}

# -- 聚合重算 --------------------------------------------------------------

# 把推导结果里的 (pane_id|有效态) 写成一次 tmux 调用里的 \; 链
#
# 为什么不逐个写：每个 pane 一次 tmux 调用就是 N 次 fork。
# 一次 \; 链写完，只有一次 fork —— 与 CLAUDE.md 里「一次 \; 链写多个
# option 不额外 fork」同一条原则。
#
# stdin = 推导输出（pane_id|有效态|通知态|活动态|消息）
whistle_write_pane_eff() {
  set --
  while IFS='|' read -r _we_pane _we_eff _we_notice _we_act _we_msg \
    || [ -n "${_we_pane:-}" ]; do
    case "${_we_pane:-}" in
    '%'*) ;;
    *) continue ;;
    esac
    if [ $# -gt 0 ]; then
      set -- "$@" ';'
    fi
    set -- "$@" set -p -t "$_we_pane" @whistle_eff "$_we_eff"
  done
  if [ $# -gt 0 ]; then
    whistle_tmux "$@"
  fi
  return 0
}

whistle_recompute_window() {
  _win="$1"
  # 状态块从第 2 列开始：活动态、通知态、活动消息、通知消息、
  # 子 agent 标记（可选列）、最后一列是前台进程名。
  _lines=$(whistle_tmux list-panes -t "$_win" \
    -F '#{pane_id}|#{@whistle}|#{@whistle_notice}|#{@whistle_msg}|#{@whistle_notice_msg}|#{@whistle_sub}|#{pane_current_command}' 2> /dev/null)

  # 推导层：没上报过、但前台跑着 agent 的 pane 算 idle；子 agent 在跑则强制 running。
  # 这层推导在纯函数之前做，下游（聚合、计数、菜单）全都白拿同一个口径。
  _lines=$(printf '%s\n' "$_lines" \
    | whistle_resolve_idle_panes "$(whistle_conf '@whistle_agent_cmds')" 2 0)

  _agg=$(printf '%s' "$_lines" | whistle_aggregate)
  # 拆 6 列：<有效态>|<消息>|<待处理数>|<胜出 pane>|<通知态>|<通知消息>
  _state=${_agg%%|*}
  _rest=${_agg#*|}
  _msg=${_rest%%|*}
  _rest=${_rest#*|}
  _count=${_rest%%|*}
  _rest=${_rest#*|}
  _pane=${_rest%%|*}
  _rest=${_rest#*|}
  _notice=${_rest%%|*}
  _notice_msg=${_rest#*|}

  # window 级刻意用与 pane 级不同的名字（@whistle_win vs @whistle）。
  # 同名会造成影子遮蔽：清掉 pane 的 @whistle 后，查找会回退到 window 上的
  # 聚合值，于是 pane 看起来"清不掉"。
  #
  # @whistle_win 是**有效态**（徽章显示它），@whistle_win_notice 是
  # **通知态**（这个窗口有没有事等你）—— 两个不同的名字，两件事。
  #
  # @whistle_win_pane 记的是「这个窗口该亮的状态来自哪一格」。
  # 消费者是 jump（先判存活再 select-pane）。
  # 菜单**不读它** —— 菜单走 whistle_agent_windows 的第 5 列，那份数据更新鲜。
  # 两处用途不同，别把「测了 @whistle_win_pane」当成「测了菜单」。
  # 它由重算覆盖，所以 whistle_state_clear 不必清它。
  whistle_tmux setw -t "$_win" @whistle_win "$_state" \
    \; setw -t "$_win" @whistle_win_msg "$_msg" \
    \; setw -t "$_win" @whistle_win_count "$_count" \
    \; setw -t "$_win" @whistle_win_pane "$_pane" \
    \; setw -t "$_win" @whistle_win_notice "$_notice" \
    \; setw -t "$_win" @whistle_win_notice_msg "$_notice_msg"

  # pane 级有效态：徽章直接读它（format 层数不变，不加嵌套）。
  printf '%s\n' "$_lines" | whistle_write_pane_eff
}

whistle_recompute_global() {
  # 必须带 pane_id：whistle_aggregate 会跳过不以 '%' 开头的行，
  # 只传 @whistle 的话每一行都被丢掉，计数恒为 0。
  #
  # 一次 list-panes 喂两个纯函数：聚合态 / 待处理总数 + 各状态分布。
  _cg_rows=$(whistle_tmux list-panes -a \
    -F '#{pane_id}|#{@whistle}|#{@whistle_notice}|#{@whistle_msg}|#{@whistle_notice_msg}|#{@whistle_sub}|#{pane_current_command}' 2> /dev/null)
  _cg_rows=$(printf '%s\n' "$_cg_rows" \
    | whistle_resolve_idle_panes "$(whistle_conf '@whistle_agent_cmds')" 2 0)

  _n=$(printf '%s\n' "$_cg_rows" | whistle_aggregate | cut -d'|' -f3)
  _c=$(printf '%s\n' "$_cg_rows" | whistle_count_states)

  # 纯 shell 拆 "r|i|d|w|e"，避免五次 cut 子进程
  _cr=${_c%%|*}
  _rest=${_c#*|}
  _ci=${_rest%%|*}
  _rest=${_rest#*|}
  _cd=${_rest%%|*}
  _rest=${_rest#*|}
  _cw=${_rest%%|*}
  _ce=${_rest#*|}

  whistle_tmux set -g @whistle_pending "${_n:-0}" \
    \; set -g @whistle_count_running "${_cr:-0}" \
    \; set -g @whistle_count_idle "${_ci:-0}" \
    \; set -g @whistle_count_done "${_cd:-0}" \
    \; set -g @whistle_count_wait "${_cw:-0}" \
    \; set -g @whistle_count_error "${_ce:-0}"

  # pane 级有效态
  printf '%s\n' "$_cg_rows" | whistle_write_pane_eff

  # 帧推进器的启停跟着计数走 —— 挂在这里而不是 deliver / setup.sh 里，
  # 因为**这里是唯一改 @whistle_count_running 的地方**。
  # 挂在调用方就会漏：--recompute（由 pane-exited / window-pane-changed
  # 钩子调用）只重算计数，不会走 deliver，于是「running 归零时被停掉的
  # 推进器」在计数回升后没人重新拉起，状态栏和菜单的帧就一起冻住。
  whistle_spin_sync
}

# -- 查询 ------------------------------------------------------------------

# whistle_list_lines：输出 "<session>|<window>|<pane>|<通知态>|<消息>|<age>"
#
# **只列通知通道**（「有事等你」的那些）。活动通道是背景信息，
# 混进待办清单里就没有意义了 —— 待办清单的语义就是「等我处理」。
#
# 分隔符一律用 '|'（非空白）。若用 TAB/空格，read 会折叠连续分隔符，
# 消息为空时后面的列会整体前移一格。消息在倒数第二列且末列 age 恒有值，
# 仍不如 '|' 稳妥。
whistle_list_lines() {
  # 临时变量一律用 _l 前缀：whistle_is_notified 等被调函数也会用通用短名，
  # POSIX sh 里同名会被覆盖（曾经把 session 名覆盖成状态名）。
  whistle_tmux list-panes -a \
    -F '#{session_name}|#{window_name}|#{pane_id}|#{@whistle_notice}|#{@whistle_notice_msg}|#{@whistle_notice_at}' \
    2> /dev/null | while IFS='|' read -r _ls _lwn _lpid _lst _lmsg _lat; do
    whistle_is_notified "$_lst" || continue
    _lage='-'
    if [ -n "${_lat:-}" ]; then
      _lage=$(($(whistle_now) - _lat))s
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$_ls" "$_lwn" "$_lpid" "$_lst" "$_lmsg" "$_lage"
  done
}

# 所有 pane 的 (session, window_id, window_name, window_index, pane_id, 有效态,
#               通知态, 活动态, 消息)
#
# 与 whistle_pending_windows 的区别：**不过滤** whistle_is_notified，
# 所以 running / idle 也在内 —— 菜单要能列出「哪些窗口有 agent」，
# 而不只是「哪些在等我」。
#
# 按 window_id 去重，保留 rank 最高的那一行：list-panes -a 是 pane 粒度，
# 一个窗口开了多个 pane 时同一窗口会出现多次，菜单里就是重复条目。
# 第 5 列是那一行所属的 pane id，菜单据此 select-pane —— 窗口切成多格时
# 才不会落在隔壁格子。
#
# ⚠️ 这里的 rank 必须与 whistle_rank 一致（awk 里没法调 shell 函数）。
# 两处对不上时症状很隐蔽：窗口徽章显示 ▶、菜单却排成 idle 那一条。
#
# 第 10 列是子 agent 标记（可选列）、第 11 列是前台进程名：
# 没上报过、但跑着 agent 的 pane 也要列进菜单（活动态算 idle）——
# 与窗口徽章、状态栏汇总同一口径。
#
# 注意：推导层会**去掉命令列与子 agent 标记列**，所以下面 awk 看到的行是 9 列。
whistle_agent_windows() {
  whistle_tmux list-panes -a \
    -F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{pane_id}|#{@whistle}|#{@whistle_notice}|#{@whistle_msg}|#{@whistle_notice_msg}|#{@whistle_sub}|#{pane_current_command}' \
    2> /dev/null \
    | whistle_resolve_idle_panes "$(whistle_conf '@whistle_agent_cmds')" 6 5 \
    | awk -F'|' -v gone="$WHISTLE_GONE_STATE" '
    $6 == "" || $6 == gone { next }
    {
      r = ($6 == "error") ? 5 : ($6 == "wait") ? 4 : ($6 == "done") ? 3 : ($6 == "running") ? 2 : 1
      if (!($2 in best)) order[++n] = $2
      if (!($2 in best) || r > best[$2]) {
        best[$2] = r
        line[$2] = $0
      }
    }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  '
}

# 待处理的 (session, window_id, window_name, window_index, 通知态, 消息)
# 供 display-menu 与 jump 使用。
whistle_pending_windows() {
  whistle_tmux list-panes -a \
    -F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{@whistle_notice}|#{@whistle_notice_msg}' \
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
# 推进器的 PID 记在**目标 server 自己的 option** 里（@whistle_spin_pid），
# 不用磁盘上的 pidfile。
#
# 为什么不用 pidfile：pidfile 路径按用户命名，**不含 socket** —— 同一台机器上
# 跑着两个 tmux server（用户的真 server + 测试的隔离 server）时，它们共用
# 同一个 pidfile。隔离 server 的 whistle_spin_stop 会把**用户真 server 的推进器**
# kill 掉，用户那边下一次重算又把它拉起来 —— 状态栏汇总格于是反复重画，
# CPU 跟着抖（2026-11-02 实测）。option 跟着 server 走，天然隔离；
# server 一死它也一起没了，不留残骸。
#
# 代价：多一次 tmux 调用。这不在 0.5 秒一次的高频路径上 —— 高频路径只有
# 推进器自己改 @whistle_spin_char。
whistle_spin_pid() {
  _sp_pid=$(whistle_tmux show -gqv '@whistle_spin_pid' 2> /dev/null) || _sp_pid=''
  case "$_sp_pid" in
  '' | *[!0-9]*) _sp_pid='' ;;
  esac
  printf '%s' "$_sp_pid"
}

# 写入推进器 PID；空串表示「当前没有推进器」。
# 用空串而不是 unset：unset 的参数形式在 tmux 版本间有差异，写空串更稳。
whistle_spin_pid_set() {
  whistle_tmux set -g '@whistle_spin_pid' "${1:-}" 2> /dev/null || true
}

# 这个 PID 是不是「活着的、且确实是我们的推进器」。
#
# 只看 kill -0 不够：推进器被 SIGKILL 后 option 里的 PID 会残留，OS 复用 PID 之后
# kill -0 对一个**无关进程**也会成功 —— 于是 stop 可能 kill 错人，ensure 也会误判
# 「已经有推进器」而再也不拉起。多一次 ps 只在启停路径上，不在高频路径上。
whistle_spin_alive() {
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2> /dev/null || return 1
  _sa_cmd=$(ps -p "$1" -o command= 2> /dev/null) || return 1
  case "$_sa_cmd" in
  *spin.sh*) return 0 ;;
  esac
  return 1
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
# ⚠️ 复位写的是 **@whistle_spin_char**（当前帧字符），不是 @whistle_spin（开关）。
# 曾经写成后者，等于把开关自己置 0 —— 此后 whistle_conf 永远读不到 on，
# 动画被永久判成「关」，而界面上完全看不出异常（退回静态图标而已）。
# 「用户可配的开关」与「插件自己写的状态」必须用不同的 option 名。
whistle_spin_sync() {
  if [ "$(whistle_conf '@whistle_spin')" != on ]; then
    whistle_spin_stop
    whistle_tmux set -g @whistle_spin_char "$(whistle_spin_first)" 2> /dev/null || true
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
    whistle_tmux set -g @whistle_spin_char "$(whistle_spin_first)" 2> /dev/null || true
  fi
}

# 单实例守卫：server 里记着的推进器还活着就什么都不做。
whistle_spin_ensure() {
  _se_pid=$(whistle_spin_pid)
  if whistle_spin_alive "$_se_pid"; then
    return 0
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
  _sx_pid=$(whistle_spin_pid)
  # 只杀「确实是推进器」的那个 PID：残留的 PID 被 OS 复用后，裸 kill 会误伤无关进程。
  whistle_spin_alive "$_sx_pid" && kill "$_sx_pid" 2> /dev/null
  # 只清这个 server 的记录 —— 不碰别的 server 的推进器（见 whistle_spin_pid）。
  whistle_spin_pid_set ''
  return 0
}
