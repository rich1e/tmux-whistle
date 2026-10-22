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

# 各状态在状态栏上的符号
WHISTLE_SYM_done='✔'
WHISTLE_SYM_wait='⏳'
WHISTLE_SYM_error='✗'

# whistle_mark_build → 打印徽章 format 串
#
# 纯 format：#{?cond,a,b} 做分支，#{==:x,y} 做字符串比较，
# #{@whistle_win} 在 window-status-format 的 item 上下文里解析为
# "当前窗口自己的" option。
#
# 三层嵌套条件式，结尾必须补齐三个 '}' —— 少一个就是畸形 format，
# tmux 会静默渲染成空字符串（这个坑被 test/integration/badge.bats 抓到过）。
#
# @whistle_badge off 时生成空串：哨兵照常注入，但渲染为空 —— 状态栏格式保持
# 原样。走「注入空串」而不是「注入后再移除」，是因为移除会和主题重算打架
# （见 whistle_ensure_status_line 的自愈逻辑），空串则天然与两种顺序兼容。
whistle_mark_build() {
  [ "$(whistle_conf '@whistle_badge')" = off ] && return 0

  _c_done=$(whistle_conf '@whistle_color_done')
  _c_wait=$(whistle_conf '@whistle_color_wait')
  _c_err=$(whistle_conf '@whistle_color_error')

  _w='#{@whistle_win}'
  printf '#{?#{==:%s,done},#[fg=%s]%s#[default],' "$_w" "$_c_done" "$WHISTLE_SYM_done"
  printf '#{?#{==:%s,wait},#[fg=%s]%s#[default],' "$_w" "$_c_wait" "$WHISTLE_SYM_wait"
  printf '#{?#{==:%s,error},#[fg=%s]%s#[default],}}}' "$_w" "$_c_err" "$WHISTLE_SYM_error"
}

# whistle_status_right_build → 状态栏右侧的全局待处理计数
#
# 这是跨 session 可见性的关键：窗口徽章只出现在"拥有该窗口的 session"的
# 状态栏里，你在 B 时看不到 A 的窗口列表。全局计数补上这一块 ——
# 不管你在哪个 session，都能看到"别处还有 N 件事等着"。
whistle_status_right_build() {
  printf '#{?@whistle_pending, #[fg=%s]🔔#{@whistle_pending}#[default],}' \
    "$(whistle_conf '@whistle_color_wait')"
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

  _p='#{@whistle}'
  printf ' #{?#{==:%s,done},#[fg=%s]%s#[default],' "$_p" "$_c_done" "$WHISTLE_SYM_done"
  printf '#{?#{==:%s,wait},#[fg=%s]%s#[default],' "$_p" "$_c_wait" "$WHISTLE_SYM_wait"
  printf '#{?#{==:%s,error},#[fg=%s]%s#[default],}}}' "$_p" "$_c_err" "$WHISTLE_SYM_error"
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
