#!/bin/sh
# tmux-whistle 状态栏渲染。
#
# 核心约束（原理 2）：徽章必须是纯 tmux format，一个进程都不 fork。
# 状态栏每 status-interval 重算一次；写成 gpakosz 那种自定义 shell function
# 就会每次刷新都 fork 一个 sh -c，8 个 session 完全不可接受。
#
# 徽章串存进 global user option @whistle_mark，用户的 tmux.conf.local 里只写
# 一个短占位符 #{E:@whistle_mark}（原理 3）。

# 哨兵：注入进 window-status-format 的占位符，也是幂等性的判据（KP-4）
WHISTLE_MARK_SENTINEL='#{E:@whistle_mark}'

# status-right 里的全局待处理计数占位符
WHISTLE_RIGHT_SENTINEL='#{E:@whistle_status_right}'

# whistle_icon <option> → 该状态的符号
#
# 图标是用户填的、而且会进 tmux format，所以必须过 whistle_sanitize：
# 填进 # { } | 会被二次展开或截断条件式。
#
# 「选项不存在」与「选项被显式设成空」要区别对待：
#   不存在 → 回落默认值（用户没配）
#   空     → 就用空（用户明确不想要图标，比如只要一个纯数字计数）
# 用 show 的退出码区分 —— 未设置的 option 上 tmux show 返回非零。
whistle_icon() {
  if _ic_raw=$(whistle_tmux show -gv "$1" 2> /dev/null); then
    whistle_sanitize "$_ic_raw"
  else
    whistle_conf_default "$1"
  fi
}

# whistle_mark_build → 打印徽章 format 串
#
# 纯 format：#{?cond,a,b} 做分支，#{==:x,y} 做字符串比较，
# #{@whistle_win} 在 window-status-format 的 item 上下文里解析为
# "当前窗口自己的" option。
#
# 四层嵌套条件式，结尾必须补齐四个 '}' —— 少一个就是畸形 format，
# tmux 会静默渲染成空字符串（这个坑被 test/integration/badge.bats 抓到过）。
#
# 嵌套顺序只是书写顺序：@whistle_win 存的是单个状态字符串，只有一个分支会命中，
# 所以这里没有「优先级」语义 —— 真正的优先级在 whistle_aggregate 里。
# running 排最后，因为它不计入 ✉N，作用只是让窗口列表能看出「这个窗口有 agent」。
#
# @whistle_badge off 时生成空串：哨兵照常注入，但渲染为空 —— 状态栏格式保持
# 原样。走「注入空串」而不是「注入后再移除」，是因为移除会和主题重算打架
# （见 whistle_ensure_status_line 的自愈逻辑），空串则天然与两种顺序兼容。
whistle_mark_build() {
  [ "$(whistle_conf '@whistle_badge')" = off ] && return 0

  _c_done=$(whistle_conf '@whistle_color_done')
  _c_wait=$(whistle_conf '@whistle_color_wait')
  _c_err=$(whistle_conf '@whistle_color_error')
  _c_run=$(whistle_conf '@whistle_color_running')
  _s_done=$(whistle_icon '@whistle_icon_done')
  _s_wait=$(whistle_icon '@whistle_icon_wait')
  _s_err=$(whistle_icon '@whistle_icon_error')
  _s_run=$(whistle_icon '@whistle_icon_running')

  _w='#{@whistle_win}'
  printf '#{?#{==:%s,done},#[fg=%s]%s#[default],' "$_w" "$_c_done" "$_s_done"
  printf '#{?#{==:%s,wait},#[fg=%s]%s#[default],' "$_w" "$_c_wait" "$_s_wait"
  printf '#{?#{==:%s,error},#[fg=%s]%s#[default],' "$_w" "$_c_err" "$_s_err"
  printf '#{?#{==:%s,running},#[fg=%s]%s#[default],}}}}' "$_w" "$_c_run" "$_s_run"
}

# whistle_summary_build → 全 server 的四态分布（纯 format，零 fork）
#
# 窗口徽章只在"拥有该窗口的 session"里可见，所以另给一段跨 session 的分布：
#   ▶1 ✓1 ◷0 ✗0
#
# 整段只在真有 agent 活动时出现（running 或待处理任一非零），否则为空。
# 四个格子一起出现、包括计数为 0 的 —— 这样状态栏宽度不会随计数跳动，
# 也保证「四种状态」始终一眼可见。
whistle_summary_build() {
  _sm_c_run=$(whistle_conf '@whistle_color_running')
  _sm_c_done=$(whistle_conf '@whistle_color_done')
  _sm_c_wait=$(whistle_conf '@whistle_color_wait')
  _sm_c_err=$(whistle_conf '@whistle_color_error')

  # running 那格：@whistle_spin on 时用 Braille 帧，否则退回静态图标。
  # ⚠️ 帧片段是 format，**不能过 whistle_icon / whistle_sanitize** ——
  # 它会剔掉 # { } |，整个 format 会被毁成空串（tmux 静默渲染成空白）。
  if [ "$(whistle_conf '@whistle_spin')" = on ]; then
    _sm_s_run=$(whistle_spin_build)
  else
    _sm_s_run=$(whistle_icon '@whistle_icon_running')
  fi
  _sm_s_idle=$(whistle_icon '@whistle_icon_idle')

  _sm_s_done=$(whistle_icon '@whistle_icon_done')
  _sm_s_wait=$(whistle_icon '@whistle_icon_wait')
  _sm_s_err=$(whistle_icon '@whistle_icon_error')

  # 图标与数字之间留一个空格 —— 紧贴成 "✓2" 时，宽图标会看起来像
  # 数字的一部分，窄图标又像被数字吃掉了。
  #
  # #{||:a,b} 的真值判定是"非空且不等于 0"，见 tmux FORMATS。
  printf '#{?#{||:#{@whistle_count_running},#{@whistle_pending}},'
  # running 那格分两态：有在跑 → 帧 + 计数；没有在跑 → ◉ + 计数。
  # 两态都带计数：格子宽度不随状态跳变，而且「◉ 0」比光秃秃的「◉」更明确
  # —— 一眼看出是「零个在跑」而不是「这一格坏了 / 没加载」。
  printf '#{?#{@whistle_count_running},'
  printf '#[fg=%s]%s #{@whistle_count_running}#[default] ,' "$_sm_c_run" "$_sm_s_run"
  printf '#[fg=%s]%s #{@whistle_count_running}#[default] }' "$_sm_c_run" "$_sm_s_idle"
  printf '#[fg=%s]%s #{@whistle_count_done}#[default] ' "$_sm_c_done" "$_sm_s_done"
  printf '#[fg=%s]%s #{@whistle_count_wait}#[default] ' "$_sm_c_wait" "$_sm_s_wait"
  printf '#[fg=%s]%s #{@whistle_count_error}#[default] ,}' "$_sm_c_err" "$_sm_s_err"
}

# whistle_status_right_build → 状态栏右侧的全局待处理计数
#
# 这是跨 session 可见性的关键：窗口徽章只出现在"拥有该窗口的 session"的
# 状态栏里，你在 B 时看不到 A 的窗口列表。全局计数补上这一块 ——
# 不管你在哪个 session，都能看到"别处还有 N 件事等着"。
#
# 前面接四态汇总：汇总给分布，✉ 给"总共几件要处理"这一眼。
# 两者共用同一次 status-right 注入，所以自愈只需要一个入口。
#
# 颜色用 @whistle_color_pending，**不再借用 @whistle_color_wait** ——
# 待处理总数与「等待」是两回事（后者已由汇总里的 ◷ 表达），
# 借用会让改 ◷ 的颜色连带改了总数，而且总数默认是青的、不是琥珀色。
whistle_status_right_build() {
  whistle_summary_build
  printf '#{?@whistle_pending, #[fg=%s]%s #{@whistle_pending}#[default],}' \
    "$(whistle_conf '@whistle_color_pending')" \
    "$(whistle_icon '@whistle_icon_pending')"
}

whistle_status_right_publish() {
  whistle_tmux set -g @whistle_status_right "$(whistle_status_right_build)"
}

# 幂等把全局计数插到 status-right 最前面（左端最显眼）
whistle_status_right_patch() {
  _cur=$(whistle_tmux show -gv status-right 2> /dev/null) || return 1
  _stripped=$(printf '%s' "$_cur" | sed "s/${WHISTLE_RIGHT_SENTINEL}//g")

  if [ "$_stripped" != "$_cur" ]; then
    return 0 # 已注入
  fi

  whistle_tmux set -g status-right "${WHISTLE_RIGHT_SENTINEL}${_stripped}" || return 1

  _n=$(whistle_tmux show -gv status-right | grep -o -F "$WHISTLE_RIGHT_SENTINEL" | wc -l | tr -d ' ')
  if [ "$_n" != 1 ]; then
    whistle_tmux set -g status-right "$_cur"
    printf 'tmux-whistle: 注入 status-right 后哨兵出现 %s 次，已回滚\n' "$_n" >&2
    return 1
  fi
}

whistle_status_right_unpatch() {
  _cur=$(whistle_tmux show -gv status-right 2> /dev/null) || return 1
  whistle_tmux set -g status-right "$(printf '%s' "$_cur" | sed "s/${WHISTLE_RIGHT_SENTINEL}//g")"
}

# whistle_mark_publish：把徽章串写进 global option（改色后重跑即可生效，无需重载配置）
whistle_mark_publish() {
  whistle_tmux set -g @whistle_mark "$(whistle_mark_build)"
}

# whistle_pane_mark_build → pane 级徽章（用于 pane-border-status 行）
#
# 与窗口徽章同一个公式，但读的是 pane 作用域的 @whistle ——
# pane-border-format 的 item 上下文是 pane。分屏时能分清是哪个 pane 在等你。
whistle_pane_mark_build() {
  _c_done=$(whistle_conf '@whistle_color_done')
  _c_wait=$(whistle_conf '@whistle_color_wait')
  _c_err=$(whistle_conf '@whistle_color_error')
  _c_run=$(whistle_conf '@whistle_color_running')
  _s_done=$(whistle_icon '@whistle_icon_done')
  _s_wait=$(whistle_icon '@whistle_icon_wait')
  _s_err=$(whistle_icon '@whistle_icon_error')
  _s_run=$(whistle_icon '@whistle_icon_running')

  _p='#{@whistle}'
  printf ' #{?#{==:%s,done},#[fg=%s]%s#[default],' "$_p" "$_c_done" "$_s_done"
  printf '#{?#{==:%s,wait},#[fg=%s]%s#[default],' "$_p" "$_c_wait" "$_s_wait"
  printf '#{?#{==:%s,error},#[fg=%s]%s#[default],' "$_p" "$_c_err" "$_s_err"
  printf '#{?#{==:%s,running},#[fg=%s]%s#[default],}}}}' "$_p" "$_c_run" "$_s_run"
}

whistle_pane_mark_publish() {
  whistle_tmux set -g @whistle_pane_mark "$(whistle_pane_mark_build)"
}

# whistle_ensure_status_line
#
# 保证徽章与全局计数此刻确实在状态栏格式里，缺了就补。
#
# 为什么需要它：oh-my-mux 在 source 完 tmux.conf.local **之后**才重算主题并
# 重新 set-option status-right / window-status-format，会把我们早先打的补丁
# 覆盖掉；而加载顺序里没有一个可靠的"配置已就绪"信号可等。
# 与其猜延迟，不如在**真正要显示的时候**自愈 —— 那一刻补丁必须在位。
#
# 全部幂等，重复调用不会叠出双徽章。
whistle_ensure_status_line() {
  whistle_status_right_publish
  whistle_status_right_patch

  whistle_mark_publish
  whistle_pane_mark_publish
  whistle_format_patch window-status-format
  whistle_format_patch window-status-current-format
}

# -- 幂等注入（KP-4 / KP-5） ------------------------------------------------

# 把哨兵插到字符串最后一个字符之前。
# oh-my-tmux 的 window-status-format 末位是 powerline 右分隔符，
# 插在它之后徽章会掉到 chip 外面（KP-5）。
#
# 取末位字符不能用 ${v##*?} —— '##' 删的是最长匹配前缀，而 '*?' 能匹配整串，
# 结果是整个字符串被删光（静默失败）。改用 wc -m 数出字符数再 cut 取末位。
# C locale 下 wc -m == wc -c、cut -c 按字节切，与 ${v%?} 按字节删保持自洽。
whistle_insert_before_tail() {
  _fmt="$1"
  [ -z "$_fmt" ] && return 1
  _n=$(printf '%s' "$_fmt" | wc -m | tr -d ' ')
  _head=${_fmt%?}
  _tail=$(printf '%s' "$_fmt" | cut -c "$_n")
  printf '%s%s%s' "$_head" "$2" "$_tail"
}

# whistle_format_patch <window-status-format | window-status-current-format>
#
# 幂等：先删掉所有旧哨兵，再插入恰好一个。插入后校验计数为 1，
# 不等则回滚原值并报错（KP-4）。
whistle_format_patch() {
  _opt="$1"
  _cur=$(whistle_tmux show -gwv "$_opt" 2> /dev/null) || return 1

  # 已经是官方扩展点路径（用户手写了哨兵）就不动
  _stripped=$(printf '%s' "$_cur" | sed "s/${WHISTLE_MARK_SENTINEL}//g")
  if [ "$_stripped" != "$_cur" ]; then
    return 0
  fi

  _new=$(whistle_insert_before_tail "$_stripped" "$WHISTLE_MARK_SENTINEL")
  [ -z "$_new" ] && return 1

  whistle_tmux set -gw "$_opt" "$_new" || return 1

  _n=$(whistle_tmux show -gwv "$_opt" | grep -o -F "$WHISTLE_MARK_SENTINEL" | wc -l | tr -d ' ')
  if [ "$_n" != 1 ]; then
    whistle_tmux set -gw "$_opt" "$_cur"
    printf 'tmux-whistle: 注入 %s 后哨兵出现 %s 次（应为 1），已回滚\n' "$_opt" "$_n" >&2
    return 1
  fi
  return 0
}

whistle_format_unpatch() {
  _opt="$1"
  _cur=$(whistle_tmux show -gwv "$_opt" 2> /dev/null) || return 1
  whistle_tmux set -gw "$_opt" "$(printf '%s' "$_cur" | sed "s/${WHISTLE_MARK_SENTINEL}//g")"
}

# 两条路径都被占用时给出提示，而不是默默叠出双徽章
whistle_format_status() {
  _c=$(whistle_tmux show -gwv window-status-format 2> /dev/null)
  _n=$(printf '%s' "$_c" | grep -o -F "$WHISTLE_MARK_SENTINEL" | wc -l | tr -d ' ')
  [ "$_n" = 1 ] || printf 'warn window-status-format 中哨兵出现 %s 次\n' "$_n"
  return 0
}

# -- 生成给 tmux.conf.local 的文本（显式路径） ----------------------------

# whistle_print_status_line：打印要写进用户配置的 tmux_conf_* 赋值。
# 用户手动加这两行，徽章会落在 powerline 芯片内部。
whistle_print_status_line() {
  _content=$(whistle_tmux show -gwv window-status-current-format 2> /dev/null \
    | sed "s/${WHISTLE_MARK_SENTINEL}//g")
  if [ -z "$_content" ]; then
    # 没有参考值时给一个保守的默认值
    _content='#I #W#{?window_bell_flag,!,}#{?window_zoomed_flag,Z,}'
  fi
  printf '# ---- tmux-whistle（徽章落在 powerline 芯片内部）----\n'
  printf 'tmux_conf_theme_window_status_format="%s%s"\n' "$_content" "$WHISTLE_MARK_SENTINEL"
  printf 'tmux_conf_theme_window_status_current_format="%s%s"\n' "$_content" "$WHISTLE_MARK_SENTINEL"
  printf '# ---- /tmux-whistle ----\n'
}

# -- 已读钩子（原理 6） ----------------------------------------------------

# 切进窗口 = 已读。hook 里传 #{window_id}（KP-7 优先方案）。
whistle_read_window() {
  _win="${1:-}"
  [ -z "$_win" ] && _win=$(whistle_tmux display-message -p '#{window_id}' 2> /dev/null)
  [ -z "$_win" ] && return 1

  # option 不存在时 tmux show 返回非零，这里必须兜住：
  # set -e 的调用方（hook、bats）会因此中断，已读路径就废了。
  _s=$(whistle_tmux show -wv -t "$_win" @whistle_win 2> /dev/null) || _s=''
  whistle_is_notified "$_s" || return 0
  whistle_clear_window "$_win"
}

whistle_read_pane() {
  _pane="${1:-}"
  [ -z "$_pane" ] && _pane=$(whistle_resolve_pane '')
  [ -z "$_pane" ] && return 1

  _s=$(whistle_tmux show -pqv -t "$_pane" @whistle 2> /dev/null) || _s=''
  whistle_is_notified "$_s" || return 0

  whistle_state_clear "$_pane" > /dev/null
  _win=$(whistle_pane_window "$_pane")
  [ -n "$_win" ] && whistle_recompute_window "$_win"
  whistle_recompute_global
}

# 注册 tmux hooks。只装读侧的（原理 4.3）。
whistle_hooks_install() {
  _cli="$1"

  [ "$(whistle_conf '@whistle_clear_on_focus')" = on ] && {
    whistle_tmux set-hook -g 'after-select-window[whistle]' \
      "run-shell -b '$_cli --read-window #{window_id}'"
    whistle_tmux set-hook -g 'after-select-pane[whistle]' \
      "run-shell -b '$_cli --read-pane #{pane_id}'"
  }

  # 只做聚合重算，不投递任何通知；必须是纯重算、幂等、廉价
  whistle_tmux set-hook -g 'window-pane-changed[whistle]' \
    "run-shell -b '$_cli --recompute'"
  whistle_tmux set-hook -g 'pane-exited[whistle]' \
    "run-shell -b '$_cli --recompute'"
}

whistle_hooks_uninstall() {
  # 只摘除我们自己那把 key，别人的钩子原样保留
  whistle_tmux set-hook -gu 'after-select-window[whistle]'
  whistle_tmux set-hook -gu 'after-select-pane[whistle]'
  whistle_tmux set-hook -gu 'window-pane-changed[whistle]'
  whistle_tmux set-hook -gu 'pane-exited[whistle]'
}
