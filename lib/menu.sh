#!/bin/sh
# tmux-whistle 菜单共享模型与展示辅助函数。
#
# 模型只消费 whistle_agent_windows 的 9 列输出，不直接读取 tmux。
# 交互菜单与 display-menu 共用同一份排序、键位与溢出结果。

# whistle_menu_timing <标记>
#
# 可选计时日志，只在 server 环境里设了 WHISTLE_MENU_TIMING 时才写
# （`tmux set-environment WHISTLE_MENU_TIMING 1`，需要时再设
# `WHISTLE_MENU_TIMING_LOG` 指定文件）。用来定位「菜单打开很慢」这类只在真实
# 环境复现、隔离环境复现不出来的问题 —— 平时零开销，只有几个变量判断。
whistle_menu_timing() {
  [ -n "${WHISTLE_MENU_TIMING:-}" ] || return 0
  _mt_now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time' 2> /dev/null) \
    || _mt_now=$(date +%s)
  printf '%s %s\n' "$_mt_now" "${1:-}" \
    >> "${WHISTLE_MENU_TIMING_LOG:-${TMPDIR:-/tmp}/tmux-whistle-menu-timing.log}"
}

# whistle_menu_key <序号> → 单字符快捷键：1-9 之后接字母，最多 26 项（9 + 17 = a..q）
#
# 两个坑叠在一起，症状相同（第 10 项起 key 为空）：
#   1. 位置算成了 $1 - 10，第 10 项得到 0 —— cut 不接受 0
#   2. 算术展开后面多写了一个 ')'，cut 实际收到的是 "1)" 而不是 "1"
# 两者都让 cut 报错；stderr 被 2>/dev/null 吞掉，key 变成空串。
# 空 key 在 display-menu 里**合法**（表示"无快捷键"），所以菜单照常弹出、
# 只是第 10 项往后全都不能用键选中 —— 不报错、不崩溃，只能靠断言抓。
#
# 位置单独算进变量：嵌套三层 $() 加引号里再塞算术，少一个括号看不出来。
whistle_menu_key() {
  case "$1" in
  [1-9]) printf '%s' "$1" ;;
  *)
    _mk_pos=$(($1 - 9))
    printf '%s' "$(printf '%s' abcdefghijklmnopqrstuvwxyz | cut -c "$_mk_pos" 2> /dev/null)"
    ;;
  esac
}

# whistle_menu_overflow <被藏起来的项数> → 菜单里那条灰字提示的名字
#
# display-menu 每项一个单字符快捷键：9 个数字 + a~q 17 个字母 = 26 项是硬上限。
# 截断本身合理，问题是**静默** —— 状态栏写着 ⚑28、菜单里只有 26 项，
# 用户会以为自己记错了，而不是「哦有条目被折叠了」。
#
# 提示项以 '-' 开头：tmux 绘制时会剥掉那个 '-' 并置暗（disabled 语义），
# 选中与鼠标路径都会跳过它；快捷键传空串，命令是空转。
# **快捷键必须为空** —— 非空的话用户按那个键会选中一条不可跳转的项，
# 行为上就退化成了「点了没反应」，比原来的静默截断更难查。
whistle_menu_overflow() {
  printf -- '- 还有 %s 项未显示，用 %s list 查看' "${1:-0}" "$WHISTLE_PROG"
}

# whistle_menu_state_icon <状态> → 菜单里该状态的前缀图标
#
# 与状态栏用同一套图标与颜色，两个界面看起来才是一回事：
#   done ◆ / wait ◔ / error ⚠ / running ▶ / idle ◉
#
# running 用静态 ▶ 而不是状态栏那串 Braille 帧：菜单会每约 0.5 秒刷新一次，
# 一直在变的帧在列表里读不出来，看着像渲染错乱而不是动画。
#
# 早先 running 借用的是 ◉，于是同一个字符在状态栏表示「空闲」、菜单表示「在跑」
# —— 含义正好相反，看两个界面对同一件事会得出相反结论。现在 ▶=在跑、◉=空闲，
# 两处一致。
whistle_menu_state_icon() {
  case "${1:-}" in
  running) whistle_icon '@whistle_icon_running' ;;
  idle) whistle_icon '@whistle_icon_idle' ;;
  done) whistle_icon '@whistle_icon_done' ;;
  wait) whistle_icon '@whistle_icon_wait' ;;
  error) whistle_icon '@whistle_icon_error' ;;
  *) printf '%s' '' ;;
  esac
}

whistle_menu_state_color() {
  case "${1:-}" in
  running) whistle_conf '@whistle_color_running' ;;
  idle) whistle_conf '@whistle_color_idle' ;;
  done) whistle_conf '@whistle_color_done' ;;
  wait) whistle_conf '@whistle_color_wait' ;;
  error) whistle_conf '@whistle_color_error' ;;
  *) printf '%s' '' ;;
  esac
}

# whistle_menu_item_label <状态> <session> <窗口> <消息>
#
# 抽成函数是因为 cmd_menu 与 cmd_menu_args 必须逐字相同 —— 改一边不改另一边，
# 测试就会变假绿（这个坑踩过一次）。
#
# session 名用 [] 裹起来：它和窗口名、agent 的话挤在同一行里，
# 不裹起来就分不清哪一段是「哪个 session」、哪一段是「agent 说了什么」。
# 例：完成 [main]: w1 做完了
#
# 窗口名不裹 —— 它是「session 里的哪一格」，紧贴 session 更好读；
# 真正需要与内容区分开的只有 session 这一层。
whistle_menu_item_label() {
  printf '#[fg=%s]%s#[default] %s [%s]: %s %s' \
    "$(whistle_menu_state_color "$1")" "$(whistle_menu_state_icon "$1")" \
    "$(whistle_state_label "$1")" "$2" "$3" "${4:-}"
}

# whistle_menu_model：把 whistle_agent_windows 的 9 列输入变成菜单共享模型。
#
# 可选行：item|key|window_id|pane_id|session|window_name|eff|message
# 溢出行：overflow|hidden_count
# 待处理项在前，其余项在后；最多 26 个可选项，超出只汇总隐藏数。
# 消息永远放在末列，消息里的 '|' 由 read 的末位变量完整保留。
whistle_menu_model() {
  _mu_items=$(cat)
  [ -n "$_mu_items" ] || return 0

  _mu_i=0
  _mu_total=0
  while IFS='|' read -r _mu_s _mu_wid _mu_wn _mu_wi _mu_pid _mu_eff _mu_notice _mu_activity _mu_msg; do
    whistle_is_notified "$_mu_eff" || continue
    _mu_i=$((_mu_i + 1))
    _mu_total=$((_mu_total + 1))
    [ "$_mu_i" -gt 26 ] && continue
    printf 'item|%s|%s|%s|%s|%s|%s|%s\n' \
      "$(whistle_menu_key "$_mu_i")" "$_mu_wid" "$_mu_pid" \
      "$_mu_s" "$_mu_wn" "$_mu_eff" "$_mu_msg"
  done << EOF
$_mu_items
EOF

  while IFS='|' read -r _mu_s _mu_wid _mu_wn _mu_wi _mu_pid _mu_eff _mu_notice _mu_activity _mu_msg; do
    whistle_is_notified "$_mu_eff" && continue
    _mu_i=$((_mu_i + 1))
    _mu_total=$((_mu_total + 1))
    [ "$_mu_i" -gt 26 ] && continue
    printf 'item|%s|%s|%s|%s|%s|%s|%s\n' \
      "$(whistle_menu_key "$_mu_i")" "$_mu_wid" "$_mu_pid" \
      "$_mu_s" "$_mu_wn" "$_mu_eff" "$_mu_msg"
  done << EOF
$_mu_items
EOF

  if [ "$_mu_total" -gt 26 ]; then
    printf 'overflow|%s\n' "$((_mu_total - 26))"
  fi
}

# whistle_menu_reconcile_selection <选中 window id> <原索引> ← 菜单模型
#
# 模型里只有可见 item，隐藏项不会进入这里的任何一遍扫描。先按 window id 跟随
# 重排；找不到（消失或被挤到 26 项以后）时，再把原索引夹到当前可见范围内。
whistle_menu_reconcile_selection() {
  _mu_model=$(cat)
  _mu_selected=${1:-}
  _mu_previous=${2:-1}
  _mu_count=0

  while IFS='|' read -r _mu_kind _mu_key _mu_wid _mu_pid _mu_s _mu_wn _mu_eff _mu_msg; do
    [ "$_mu_kind" = item ] || continue
    _mu_count=$((_mu_count + 1))
    if [ "$_mu_wid" = "$_mu_selected" ]; then
      printf '%s|%s\n' "$_mu_wid" "$_mu_count"
      return 0
    fi
  done << EOF
$_mu_model
EOF

  [ "$_mu_count" -gt 0 ] || return 0
  case "$_mu_previous" in
  '' | *[!0-9]*) _mu_previous=1 ;;
  esac
  [ "$_mu_previous" -lt 1 ] && _mu_previous=1
  [ "$_mu_previous" -gt "$_mu_count" ] && _mu_previous=$_mu_count

  _mu_index=0
  while IFS='|' read -r _mu_kind _mu_key _mu_wid _mu_pid _mu_s _mu_wn _mu_eff _mu_msg; do
    [ "$_mu_kind" = item ] || continue
    _mu_index=$((_mu_index + 1))
    if [ "$_mu_index" -eq "$_mu_previous" ]; then
      printf '%s|%s\n' "$_mu_wid" "$_mu_index"
      return 0
    fi
  done << EOF
$_mu_model
EOF
}

# whistle_menu_select_key <字符> ← 菜单模型
# 只匹配可见 item 的快捷键；overflow 没有键位，也不可能成为跳转目标。
whistle_menu_select_key() {
  _mu_index=0
  while IFS='|' read -r _mu_kind _mu_key _mu_wid _mu_pid _mu_s _mu_wn _mu_eff _mu_msg; do
    [ "$_mu_kind" = item ] || continue
    _mu_index=$((_mu_index + 1))
    [ "$_mu_key" = "${1:-}" ] || continue
    printf '%s|%s|%s\n' "$_mu_wid" "$_mu_pid" "$_mu_index"
    return 0
  done
}

# whistle_menu_decode_key <octet1> [octet2] [octet3]
# 参数个数参与匹配：方向键的 ESC 前缀不会被误当成单独 Esc；q 也只是普通字符。
whistle_menu_decode_key() {
  case "$#" in
  3)
    case "$1 $2 $3" in
    '27 91 65') printf 'up\n' ;;
    '27 91 66') printf 'down\n' ;;
    *) printf 'unknown\n' ;;
    esac
    ;;
  1)
    case "$1" in
    '' | *[!0-9]*)
      printf 'unknown\n'
      return 0
      ;;
    esac

    # shell printf 会把前导零数字当作八进制；先按十进制文本去掉前导零。
    # 后续只做受限模式匹配，不让超大输入进入整数比较或数值格式化。
    _mu_octet=$1
    while [ "$_mu_octet" != "${_mu_octet#0}" ]; do
      _mu_octet=${_mu_octet#0}
    done
    [ -n "$_mu_octet" ] || _mu_octet=0

    case "$_mu_octet" in
    27) printf 'exit\n' ;;
    13) printf 'enter\n' ;;
    [4-9][0-9] | 1[01][0-9] | 12[0-2])
      _mu_char=$(printf '%b' "$(printf '\\%03o' "$_mu_octet")")
      case "$_mu_char" in
      [0-9A-Za-z]) printf 'char:%s\n' "$_mu_char" ;;
      *) printf 'unknown\n' ;;
      esac
      ;;
    *) printf 'unknown\n' ;;
    esac
    ;;
  *) printf 'unknown\n' ;;
  esac
}

# whistle_menu_ansi_fg <tmux 颜色> → ANSI 前景 SGR
#
# popup 直接写终端，不能沿用 display-menu 的 #[fg=...]。当前默认色都是
# #RRGGBB，完整支持这一种；其他 tmux 颜色写法回到默认前景色，不拼出非法序列。
whistle_menu_ansi_fg() {
  case "${1:-}" in
  \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
    _mu_rgb=${1#\#}
    _mu_dec=$(printf '%d' "0x$_mu_rgb")
    printf '\033[38;2;%d;%d;%dm' \
      "$((_mu_dec / 65536))" "$((_mu_dec / 256 % 256))" "$((_mu_dec % 256))"
    ;;
  *) printf '\033[39m' ;;
  esac
}

# whistle_menu_clip <文本> <显示列数> → 可安全写入终端的纯文本
#
# awk 在 C locale 下逐字节解码 UTF-8，因此截断只会落在完整码位边界。
# 控制字符（包括 ESC 与 C1 CSI）不会进入输出，#[...] 也不会被当成样式。
# 先在这里处理显示宽度，再由调用方添加 SGR，转义字节不会占用 columns。
whistle_menu_clip() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk -v max="${2:-80}" '
    BEGIN {
      for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    }

    function char_width(cp) {
      if ((cp >= 768 && cp <= 879) || (cp >= 1155 && cp <= 1161) ||
          (cp >= 1425 && cp <= 1469) || (cp >= 1471 && cp <= 1471) ||
          (cp >= 1473 && cp <= 1474) || (cp >= 1476 && cp <= 1477) ||
          (cp >= 1552 && cp <= 1562) || (cp >= 1611 && cp <= 1631) ||
          (cp >= 1648 && cp <= 1648) || (cp >= 1750 && cp <= 1764) ||
          (cp >= 1767 && cp <= 1768) || (cp >= 1770 && cp <= 1773) ||
          (cp >= 1807 && cp <= 1807) || (cp >= 1809 && cp <= 1809) ||
          (cp >= 1840 && cp <= 1866) || (cp >= 1958 && cp <= 1968) ||
          (cp >= 2027 && cp <= 2035) || (cp >= 2070 && cp <= 2073) ||
          (cp >= 2075 && cp <= 2083) || (cp >= 2085 && cp <= 2087) ||
          (cp >= 2089 && cp <= 2093) || (cp >= 2137 && cp <= 2139) ||
          (cp >= 2260 && cp <= 2273) || (cp >= 2275 && cp <= 2306) ||
          (cp >= 2362 && cp <= 2364) || (cp >= 2369 && cp <= 2376) ||
          (cp >= 2381 && cp <= 2381) || (cp >= 2385 && cp <= 2391) ||
          (cp >= 2402 && cp <= 2403) || (cp >= 2433 && cp <= 2433) ||
          (cp >= 2492 && cp <= 2492) || (cp >= 2497 && cp <= 2500) ||
          (cp >= 2509 && cp <= 2509) || (cp >= 2530 && cp <= 2531) ||
          (cp >= 2561 && cp <= 2562) || (cp >= 2620 && cp <= 2620) ||
          (cp >= 2625 && cp <= 2626) || (cp >= 2631 && cp <= 2632) ||
          (cp >= 2635 && cp <= 2637) || (cp >= 2672 && cp <= 2673) ||
          (cp >= 2689 && cp <= 2690) || (cp >= 2748 && cp <= 2748) ||
          (cp >= 2753 && cp <= 2757) || (cp >= 2759 && cp <= 2760) ||
          (cp >= 2765 && cp <= 2765) || (cp >= 2786 && cp <= 2787) ||
          (cp >= 2817 && cp <= 2817) || (cp >= 2876 && cp <= 2876) ||
          (cp >= 2879 && cp <= 2879) || (cp >= 2881 && cp <= 2884) ||
          (cp >= 2893 && cp <= 2893) || (cp >= 2902 && cp <= 2902) ||
          (cp >= 2946 && cp <= 2946) || (cp >= 3008 && cp <= 3008) ||
          (cp >= 3021 && cp <= 3021) || (cp >= 3072 && cp <= 3072) ||
          (cp >= 3134 && cp <= 3136) || (cp >= 3142 && cp <= 3144) ||
          (cp >= 3146 && cp <= 3149) || (cp >= 3157 && cp <= 3158) ||
          (cp >= 3170 && cp <= 3171) || (cp >= 3201 && cp <= 3201) ||
          (cp >= 3260 && cp <= 3260) || (cp >= 3263 && cp <= 3263) ||
          (cp >= 3270 && cp <= 3270) || (cp >= 3276 && cp <= 3277) ||
          (cp >= 3298 && cp <= 3299) || (cp >= 3329 && cp <= 3329) ||
          (cp >= 3387 && cp <= 3388) || (cp >= 3390 && cp <= 3392) ||
          (cp >= 3396 && cp <= 3396) || (cp >= 3405 && cp <= 3405) ||
          (cp >= 3426 && cp <= 3427) || (cp >= 3530 && cp <= 3530) ||
          (cp >= 3538 && cp <= 3540) || (cp >= 3542 && cp <= 3542) ||
          (cp >= 3633 && cp <= 3633) || (cp >= 3636 && cp <= 3642) ||
          (cp >= 3655 && cp <= 3662) || (cp >= 3761 && cp <= 3761) ||
          (cp >= 3764 && cp <= 3769) || (cp >= 3771 && cp <= 3772) ||
          (cp >= 3784 && cp <= 3789) || (cp >= 3864 && cp <= 3865) ||
          (cp >= 3893 && cp <= 3893) || (cp >= 3895 && cp <= 3895) ||
          (cp >= 3897 && cp <= 3897) || (cp >= 3953 && cp <= 3966) ||
          (cp >= 3968 && cp <= 3972) || (cp >= 3974 && cp <= 3975) ||
          (cp >= 3984 && cp <= 3991) || (cp >= 3993 && cp <= 4028) ||
          (cp >= 4038 && cp <= 4038) || (cp >= 4141 && cp <= 4144) ||
          (cp >= 4146 && cp <= 4146) || (cp >= 4150 && cp <= 4151) ||
          (cp >= 4153 && cp <= 4154) || (cp >= 4157 && cp <= 4158) ||
          (cp >= 4184 && cp <= 4185) || (cp >= 4190 && cp <= 4192) ||
          (cp >= 4209 && cp <= 4212) || (cp >= 4226 && cp <= 4226) ||
          (cp >= 4229 && cp <= 4230) || (cp >= 4237 && cp <= 4237) ||
          (cp >= 4253 && cp <= 4253) || (cp >= 4957 && cp <= 4959) ||
          (cp >= 5906 && cp <= 5908) || (cp >= 5938 && cp <= 5940) ||
          (cp >= 5970 && cp <= 5971) || (cp >= 6002 && cp <= 6003) ||
          (cp >= 6068 && cp <= 6069) || (cp >= 6071 && cp <= 6077) ||
          (cp >= 6086 && cp <= 6086) || (cp >= 6089 && cp <= 6099) ||
          (cp >= 6109 && cp <= 6109) || (cp >= 6155 && cp <= 6157) ||
          (cp >= 6313 && cp <= 6313) || (cp >= 6432 && cp <= 6434) ||
          (cp >= 6439 && cp <= 6440) || (cp >= 6450 && cp <= 6450) ||
          (cp >= 6457 && cp <= 6459) || (cp >= 6679 && cp <= 6680) ||
          (cp >= 6742 && cp <= 6742) || (cp >= 6744 && cp <= 6750) ||
          (cp >= 6752 && cp <= 6752) || (cp >= 6754 && cp <= 6754) ||
          (cp >= 6757 && cp <= 6764) || (cp >= 6771 && cp <= 6780) ||
          (cp >= 6783 && cp <= 6783) || (cp >= 6832 && cp <= 6845) ||
          (cp >= 6912 && cp <= 6915) || (cp >= 6964 && cp <= 6964) ||
          (cp >= 6966 && cp <= 6970) || (cp >= 6972 && cp <= 6972) ||
          (cp >= 6978 && cp <= 6978) || (cp >= 7019 && cp <= 7027) ||
          (cp >= 7040 && cp <= 7041) || (cp >= 7074 && cp <= 7077) ||
          (cp >= 7080 && cp <= 7081) || (cp >= 7083 && cp <= 7085) ||
          (cp >= 7142 && cp <= 7142) || (cp >= 7144 && cp <= 7145) ||
          (cp >= 7149 && cp <= 7149) || (cp >= 7151 && cp <= 7153) ||
          (cp >= 7212 && cp <= 7219) || (cp >= 7222 && cp <= 7223) ||
          (cp >= 7376 && cp <= 7378) || (cp >= 7380 && cp <= 7392) ||
          (cp >= 7394 && cp <= 7400) || (cp >= 7405 && cp <= 7405) ||
          (cp >= 7412 && cp <= 7412) || (cp >= 7416 && cp <= 7417) ||
          (cp >= 7616 && cp <= 7673) || (cp >= 7675 && cp <= 7679) ||
          (cp >= 8203 && cp <= 8207) || (cp >= 8232 && cp <= 8238) ||
          (cp >= 8288 && cp <= 8292) || (cp >= 8294 && cp <= 8303) ||
          (cp >= 8400 && cp <= 8431) || (cp >= 65024 && cp <= 65039) ||
          (cp >= 917760 && cp <= 917999)) return 0

      # 宽字符：CJK 与 emoji。emoji 段要到 U+1FAFF —— 早先止于 U+1F67F，
      # 🚀(U+1F680) 及之后的 emoji 被当成 1 列，clip 出来的行会比 popup 还宽。
      if ((cp >= 4352 && cp <= 4447) ||
          (cp >= 11904 && cp <= 42191 && cp != 12351) ||
          (cp >= 44032 && cp <= 55215) || (cp >= 63744 && cp <= 64255) ||
          (cp >= 65072 && cp <= 65103) || (cp >= 65281 && cp <= 65376) ||
          (cp >= 65504 && cp <= 65510) || (cp >= 126976 && cp <= 129535) ||
          (cp >= 131072 && cp <= 196607) || (cp >= 196608 && cp <= 262141)) return 2
      return 1
    }

    function clip(text,    len, i, b0, b1, b2, b3, n, cp, valid, w, used, out) {
      gsub(/#\[[^]]*\]/, "", text)
      gsub(/#\[/, "", text)
      len = length(text)
      used = 0
      out = ""
      i = 1
      while (i <= len) {
        b0 = ord[substr(text, i, 1)]
        n = 1
        cp = b0
        valid = 1
        if (b0 >= 194 && b0 <= 223 && i + 1 <= len) {
          b1 = ord[substr(text, i + 1, 1)]
          n = 2
          valid = (b1 >= 128 && b1 <= 191)
          cp = (b0 - 192) * 64 + b1 - 128
        } else if (b0 >= 224 && b0 <= 239 && i + 2 <= len) {
          b1 = ord[substr(text, i + 1, 1)]
          b2 = ord[substr(text, i + 2, 1)]
          n = 3
          valid = (b1 >= 128 && b1 <= 191 && b2 >= 128 && b2 <= 191)
          cp = (b0 - 224) * 4096 + (b1 - 128) * 64 + b2 - 128
        } else if (b0 >= 240 && b0 <= 244 && i + 3 <= len) {
          b1 = ord[substr(text, i + 1, 1)]
          b2 = ord[substr(text, i + 2, 1)]
          b3 = ord[substr(text, i + 3, 1)]
          n = 4
          valid = (b1 >= 128 && b1 <= 191 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191)
          cp = (b0 - 240) * 262144 + (b1 - 128) * 4096 + (b2 - 128) * 64 + b3 - 128
        } else if (b0 >= 128) {
          valid = 0
        }
        if (!valid || (n == 3 && cp < 2048) || (n == 4 && cp < 65536) ||
            (cp >= 55296 && cp <= 57343) || cp > 1114111) {
          i++
          continue
        }
        if (cp < 32 || (cp >= 127 && cp <= 159)) {
          i += n
          continue
        }
        w = char_width(cp)
        if (length(out) > 0 && w == 0) {
          out = out substr(text, i, n)
          i += n
          continue
        }
        if (used + w > max) break
        out = out substr(text, i, n)
        used += w
        i += n
      }
      return out
    }

    {
      printf "%s", clip($0)
    }
  '
}

# whistle_menu_item_style <状态> → "<图标> <SGR 前景>"
#
# 单行重绘用：一次取齐图标与颜色。整帧绘制走缓存版本（见 whistle_menu_render），
# 不要在这里逐行调用。
whistle_menu_item_style() {
  _mis_icon=$(whistle_menu_state_icon "${1:-}")
  _mis_fg=$(whistle_menu_ansi_fg "$(whistle_menu_state_color "${1:-}")")
  printf '%s %s' "$_mis_icon" "$_mis_fg"
}

# whistle_menu_item_text <键位> <图标> <状态> <session> <窗口> <消息> <列数> → 纯文本一行
#
# 整帧绘制与单行重绘共用这一处拼装，两边格式不会分叉。
whistle_menu_item_text() {
  _mit_text=$(printf '(%s) %s %s [%s]: %s' \
    "$1" "$2" "$(whistle_state_label "$3")" "$4" "$5")
  [ -z "${6:-}" ] || _mit_text="$_mit_text $6"
  whistle_menu_clip "$_mit_text" "${7:-80}"
}

# whistle_menu_palette_pick <状态> <调色板文本> → "<图标> <SGR 前景>"（纯 shell，不 fork）
whistle_menu_palette_pick() {
  _mpp_state=${1:-}
  while IFS='|' read -r _mpp_s _mpp_ic _mpp_fg; do
    [ "$_mpp_s" = "$_mpp_state" ] || continue
    printf '%s %s' "$_mpp_ic" "$_mpp_fg"
    return 0
  done << EOF
${2:-}
EOF
  printf ' \033[39m'
}

# whistle_menu_render_item <模型行> <选中: 1/0> <列数> → 一行的 ANSI 文本（不含换行）
#
# 只画一行，不碰屏幕其余部分。方向键移动高亮时用这个：整屏重绘要清屏并把每一行
# 重新 clip 一遍（26 项就是 26 个 awk 子进程），在慢终端上是肉眼可见的卡顿。
# UI 里已经取好调色板（_mu_pal）时直接查表，连 tmux 都不用调。
whistle_menu_render_item() {
  _mri_line=${1:-}
  _mri_sel=${2:-0}
  _mri_cols=${3:-80}
  IFS='|' read -r _mri_kind _mri_key _mri_wid _mri_pid _mri_s _mri_wn _mri_eff _mri_msg << EOF
$_mri_line
EOF
  [ "$_mri_kind" = item ] || return 0
  if [ -n "${_mu_pal:-}" ]; then
    _mri_style=$(whistle_menu_palette_pick "$_mri_eff" "$_mu_pal")
  else
    _mri_style=$(whistle_menu_item_style "$_mri_eff")
  fi
  _mri_icon=${_mri_style%% *}
  _mri_fg=${_mri_style#* }
  _mri_plain=$(whistle_menu_item_text "$_mri_key" "$_mri_icon" "$_mri_eff" \
    "$_mri_s" "$_mri_wn" "$_mri_msg" "$_mri_cols")
  if [ "$_mri_sel" = 1 ]; then
    printf '\033[7m%s%s\033[0m' "$_mri_fg" "$_mri_plain"
  else
    printf '%s%s\033[0m' "$_mri_fg" "$_mri_plain"
  fi
}

# whistle_menu_palette → 每行 "<状态>|<图标>|<SGR 前景>"，覆盖五个状态
#
# 一次 tmux 调用取齐十项配置（见 core.sh 的 whistle_conf_bulk）：菜单打开时的
# 首帧延迟几乎全在这些配置查询上，逐项查就是十次进程。
whistle_menu_palette() {
  _mpal_raw=$(whistle_conf_bulk \
    @whistle_icon_running @whistle_color_running \
    @whistle_icon_idle @whistle_color_idle \
    @whistle_icon_done @whistle_color_done \
    @whistle_icon_wait @whistle_color_wait \
    @whistle_icon_error @whistle_color_error)
  _mpal_icon_running='' _mpal_icon_idle='' _mpal_icon_done=''
  _mpal_icon_wait='' _mpal_icon_error=''
  _mpal_color_running='' _mpal_color_idle='' _mpal_color_done=''
  _mpal_color_wait='' _mpal_color_error=''
  while IFS='|' read -r _mpal_opt _mpal_val; do
    case "$_mpal_opt" in
    @whistle_icon_running) _mpal_icon_running=$_mpal_val ;;
    @whistle_icon_idle) _mpal_icon_idle=$_mpal_val ;;
    @whistle_icon_done) _mpal_icon_done=$_mpal_val ;;
    @whistle_icon_wait) _mpal_icon_wait=$_mpal_val ;;
    @whistle_icon_error) _mpal_icon_error=$_mpal_val ;;
    @whistle_color_running) _mpal_color_running=$_mpal_val ;;
    @whistle_color_idle) _mpal_color_idle=$_mpal_val ;;
    @whistle_color_done) _mpal_color_done=$_mpal_val ;;
    @whistle_color_wait) _mpal_color_wait=$_mpal_val ;;
    @whistle_color_error) _mpal_color_error=$_mpal_val ;;
    esac
  done << EOF
$_mpal_raw
EOF
  printf '%s|%s|%s\n' running "$_mpal_icon_running" \
    "$(whistle_menu_ansi_fg "$_mpal_color_running")"
  printf '%s|%s|%s\n' idle "$_mpal_icon_idle" \
    "$(whistle_menu_ansi_fg "$_mpal_color_idle")"
  printf '%s|%s|%s\n' 'done' "$_mpal_icon_done" \
    "$(whistle_menu_ansi_fg "$_mpal_color_done")"
  printf '%s|%s|%s\n' wait "$_mpal_icon_wait" \
    "$(whistle_menu_ansi_fg "$_mpal_color_wait")"
  printf '%s|%s|%s\n' error "$_mpal_icon_error" \
    "$(whistle_menu_ansi_fg "$_mpal_color_error")"
}

# whistle_menu_render <selected window id> <columns> ← 菜单模型
#
# 输出一帧完整 ANSI 内容。标题由内容首行绘制，兼容没有 display-popup -T 的
# tmux 3.2；overflow 只是暗色提示，没有键位，也不可能被选中。
whistle_menu_render() {
  _mu_selected=${1:-}
  _mu_columns=${2:-80}
  case "$_mu_columns" in
  '' | *[!0-9]*) _mu_columns=80 ;;
  esac

  whistle_menu_clip 'tmux-whistle' "$_mu_columns"
  printf '\n'
  _mu_model=$(cat)
  [ -n "$_mu_model" ] || return 0

  # 五态的图标与颜色在一帧里是固定的，用一次 tmux 调用取齐（whistle_menu_palette）。
  # UI 已经把调色板导出到 _mu_pal 时直接复用，整帧重绘不再多一次 tmux。
  [ -n "${_mu_pal:-}" ] || _mu_pal=$(whistle_menu_palette)
  while IFS='|' read -r _mu_st _mu_ic _mu_fg; do
    case "$_mu_st" in
    running)
      _mu_ic_running=$_mu_ic
      _mu_fg_running=$_mu_fg
      ;;
    idle)
      _mu_ic_idle=$_mu_ic
      _mu_fg_idle=$_mu_fg
      ;;
    done)
      _mu_ic_done=$_mu_ic
      _mu_fg_done=$_mu_fg
      ;;
    wait)
      _mu_ic_wait=$_mu_ic
      _mu_fg_wait=$_mu_fg
      ;;
    error)
      _mu_ic_error=$_mu_ic
      _mu_fg_error=$_mu_fg
      ;;
    esac
  done << EOF
$_mu_pal
EOF

  while IFS='|' read -r _mu_kind _mu_key _mu_wid _mu_pid _mu_s _mu_wn _mu_eff _mu_msg; do
    case "$_mu_kind" in
    item)
      case "$_mu_eff" in
      running)
        _mu_icon=$_mu_ic_running
        _mu_fg=$_mu_fg_running
        ;;
      idle)
        _mu_icon=$_mu_ic_idle
        _mu_fg=$_mu_fg_idle
        ;;
      done)
        _mu_icon=$_mu_ic_done
        _mu_fg=$_mu_fg_done
        ;;
      wait)
        _mu_icon=$_mu_ic_wait
        _mu_fg=$_mu_fg_wait
        ;;
      error)
        _mu_icon=$_mu_ic_error
        _mu_fg=$_mu_fg_error
        ;;
      *)
        _mu_icon=''
        _mu_fg=$(whistle_menu_ansi_fg '')
        ;;
      esac
      _mu_plain=$(whistle_menu_item_text "$_mu_key" "$_mu_icon" "$_mu_eff" \
        "$_mu_s" "$_mu_wn" "$_mu_msg" "$_mu_columns")
      if [ "$_mu_wid" = "$_mu_selected" ]; then
        printf '\033[7m%s%s\033[0m\n' "$_mu_fg" "$_mu_plain"
      else
        printf '%s%s\033[0m\n' "$_mu_fg" "$_mu_plain"
      fi
      ;;
    overflow)
      _mu_hint=$(whistle_menu_overflow "$_mu_key")
      _mu_hint=$(whistle_menu_clip "${_mu_hint#- }" "$_mu_columns")
      printf '\033[2m%s\033[0m\n' "$_mu_hint"
      ;;
    esac
  done << EOF
$_mu_model
EOF
}

# whistle_menu_read_key ← 当前终端
#
# 以十进制 octet 输出一个按键。终端已由 UI 设为 min 0 time 5，
# 所以每次读最多等 0.5 秒；Esc 多等一次后续字节，避免把方向键拆成退出。
#
# 只 fork 一个 dd：字节值用 shell 内建 printf '%d' "'x" 取，不再串 od/tr ——
# 空转时这条路径每秒跑两次，fork 数直接决定 CPU（早先版本是每秒 30 次）。
whistle_menu_read_key() {
  _mu_key=''
  _mu_state=0 # 0=等首字节，1=等 '[', 2=等方向键末字节

  while :; do
    _mu_char=$(dd bs=1 count=1 2> /dev/null)
    [ -n "$_mu_char" ] || break

    _mu_num=$(printf '%d' "'$_mu_char" 2> /dev/null) || _mu_num=''
    case "$_mu_num" in
    '' | *[!0-9]*)
      # printf 的 "'x" 形式对非 ASCII 字节可能给不出数（还可能报错）——
      # 这时退回 od 读一遍，绝不把诊断信息打到终端。
      _mu_raw=$(printf '%s' "$_mu_char" | od -An -tu1 -v 2> /dev/null)
      # shellcheck disable=SC2086 # od 的输出是空格分隔的十进制数，这里要的就是词分割
      set -- $_mu_raw
      _mu_num=${1:-}
      ;;
    esac
    [ -n "$_mu_num" ] || break

    _mu_key="${_mu_key:+$_mu_key }$_mu_num"

    case "$_mu_state" in
    0)
      # 首字节不是 Esc 就到此为止；是 Esc 才继续看后面的字节。
      if [ "$_mu_num" = 27 ]; then
        _mu_state=1
      else
        break
      fi
      ;;
    1)
      # Esc 之后的字节：'[' 才是方向键，别的就到此为止（Alt+某键，忽略）。
      if [ "$_mu_num" = 91 ]; then
        _mu_state=2
      else
        break
      fi
      ;;
    *)
      break
      ;;
    esac
  done

  [ -n "$_mu_key" ] || return 0
  printf '%s\n' "$_mu_key"
}

# 终端恢复必须幂等：正常激活会显式调用一次，随后 return 还可能触发 EXIT。
# 不清 ISIG —— Ctrl-C 正是要走 INT → EXIT 这条恢复路径。
whistle_menu_restore() {
  [ "${_mu_terminal_ready:-0}" = 1 ] || return 0
  _mu_terminal_ready=0
  printf '\033[0m\033[?25h'
  stty "$_mu_terminal_state" 2> /dev/null || true
  trap - EXIT HUP INT TERM WINCH
}

whistle_menu_activate() {
  whistle_menu_restore
  # 与 cmd_jump 共用 window id 的客户端切换方式；已读与 pane 存活判断仍只在
  # cmd_clear 中定义，绝不能在这里另写一份通知清除逻辑。
  whistle_tmux switch-client -t "$1" 2> /dev/null || true
  cmd_clear -t "$1" --select "$2"
}

# whistle_menu_paint_row <索引> <是否选中 1/0>
#
# 只重画一项，**不整屏重绘**。方向键移动时整屏重绘要清屏并把 26 行逐行 clip
# （26 个 awk 子进程），在慢终端上肉眼可见地卡；实际变了的只有两行。
# 行号 = 索引 + 1 —— 标题占第 1 行，条目从第 2 行起，与整帧绘制的顺序一致。
whistle_menu_paint_row() {
  [ "${_mu_count:-0}" -gt 0 ] || return 0
  _mpr_line=$(printf '%s\n' "$_mu_model" | grep '^item|' | sed -n "${1:-1}p")
  [ -n "$_mpr_line" ] || return 0
  printf '\033[%s;1H\033[2K' "$((${1:-1} + 1))"
  whistle_menu_render_item "$_mpr_line" "${2:-0}" "${_mu_columns:-80}"
}

# whistle_menu_move <up|down>
#
# 移动高亮：更新选中身份，然后**只重画旧行与新行**（不清屏、不重排整屏）。
# 到边界时什么都不做 —— 不回绕，方向键与 j/k 共用这一处。
whistle_menu_move() {
  case "${1:-}" in
  up)
    [ "$_mu_index" -gt 1 ] || return 0
    _mm_new=$((_mu_index - 1))
    ;;
  down)
    [ "$_mu_index" -lt "${_mu_count:-0}" ] || return 0
    _mm_new=$((_mu_index + 1))
    ;;
  *) return 0 ;;
  esac
  _mm_old=$_mu_index
  _mu_index=$_mm_new
  _mu_selection=$(printf '%s\n' "$_mu_model" \
    | whistle_menu_reconcile_selection '' "$_mu_index")
  _mu_selected=${_mu_selection%%|*}
  whistle_menu_paint_row "$_mm_old" 0
  whistle_menu_paint_row "$_mu_index" 1
}

# whistle_menu_ui：display-popup -E 内的完整交互进程。
#
# 状态会自己变：agent 跑完、子 agent 结束、通知到达，菜单都得跟着改。
# 因此每次空读（约 0.5 秒）重新读一次模型：变了就重绘，没变就不动。
# 用空读当节拍而不是每秒 fork 一次 date —— 热循环里少一个进程。
whistle_menu_ui() {
  # WHISTLE_MENU_TIMING 打开时记录各阶段耗时（见 whistle_menu_timing）。
  whistle_menu_timing 'ui-start'
  # 初始模型就为空也要**留下来说一句**，而不是直接退出：cmd_menu 看到有项、
  # 但 popup 进程第一次查询之前 agent 刚好被清掉或退出时，直接 return 会让
  # 用户看到 popup 一闪而过，什么解释都没有。
  _mu_model=$(whistle_agent_windows | whistle_menu_model)
  whistle_menu_timing "ui-model-done lines=$(printf '%s\n' "$_mu_model" | grep -c .)"
  _mu_selection=''
  if [ -n "$_mu_model" ]; then
    _mu_selection=$(printf '%s\n' "$_mu_model" | whistle_menu_reconcile_selection '' 1)
  fi
  _mu_selected=${_mu_selection%%|*}
  _mu_index=${_mu_selection##*|}
  case "$_mu_index" in
  '' | *[!0-9]*) _mu_index=1 ;;
  esac
  _mu_count=$(printf '%s\n' "$_mu_model" | grep -c '^item|')

  # 调色板只跟配置有关，整个菜单生命周期取一次就够：单行重绘靠它免掉 tmux 调用，
  # 整帧绘制也直接复用（导出后子 shell 里的 render 能读到）。
  _mu_pal=$(whistle_menu_palette)
  export _mu_pal
  whistle_menu_timing 'ui-palette-done'

  _mu_terminal_state=$(stty -g 2> /dev/null) || return 1
  [ -n "$_mu_terminal_state" ] || return 1
  _mu_terminal_ready=1
  trap 'whistle_menu_restore' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # 终端改大小时重绘：模型没变也要按新的 stty size 重算列宽，否则行宽停在旧值。
  # trap 在 dd 返回后才执行（最多晚 0.5 秒），不需要在热循环里每秒 fork 一次 stty。
  trap '_mu_dirty=1' WINCH

  # 保留 isig 与输出后处理；关掉 icrnl 让 Enter 按 CR(13) 交给解码器。
  #
  # time 5 = 空读最多等 0.5 秒。**按键到达时 read 立即返回**（time 只是
  # 「多久没数据就放弃」的界），所以响应不受影响；空转时的轮询次数因此
  # 从每秒 10 次降到 2 次 —— 这条路径每轮要 fork 一个 dd，次数就是 CPU。
  stty -icanon -echo -icrnl min 0 time 5 || return 1
  printf '\033[?25l'
  whistle_menu_timing 'ui-tty-ready'

  _mu_dirty=1
  while :; do
    if [ "$_mu_dirty" = 1 ]; then
      _mu_size=$(stty size 2> /dev/null)
      _mu_columns=${_mu_size#* }
      printf '\033[H\033[2J'
      if [ -n "$_mu_model" ]; then
        printf '%s\n' "$_mu_model" | whistle_menu_render "$_mu_selected" "$_mu_columns"
      else
        # 所有 agent 都走了：菜单还开着，但要说清楚为什么空了。
        printf '%s\n' "$(whistle_menu_clip 'tmux-whistle' "$_mu_columns")"
        printf '%s\n' "$(whistle_menu_clip '没有 agent 上报过状态' "$_mu_columns")"
      fi
      _mu_dirty=0
      whistle_menu_timing "ui-frame-done cols=$_mu_columns"
    fi

    _mu_octets=$(whistle_menu_read_key)
    if [ -z "$_mu_octets" ]; then
      # 没有输入：一次空读就是约 0.5 秒（stty time 5），刷新一次模型。
      _mu_next=$(whistle_agent_windows | whistle_menu_model)
      [ "$_mu_next" != "$_mu_model" ] || continue
      _mu_model=$_mu_next
      _mu_count=$(printf '%s\n' "$_mu_model" | grep -c '^item|')
      if [ -n "$_mu_model" ]; then
        # 列表重排后高亮要跟着窗口走，而不是停在原来的行号上。
        _mu_selection=$(printf '%s\n' "$_mu_model" \
          | whistle_menu_reconcile_selection "$_mu_selected" "$_mu_index")
        if [ -n "$_mu_selection" ]; then
          _mu_selected=${_mu_selection%%|*}
          _mu_index=${_mu_selection##*|}
        fi
      else
        _mu_selected=''
        _mu_index=1
      fi
      _mu_dirty=1
      continue
    fi
    # read_key 只输出十进制数字与空格，可安全作为解码器的位置参数。
    # shellcheck disable=SC2086 # 十进制 octet 必须拆成解码器的位置参数
    set -- $_mu_octets
    _mu_action=$(whistle_menu_decode_key "$@")

    case "$_mu_action" in
    exit)
      return 0
      ;;
    up)
      whistle_menu_move up
      continue
      ;;
    down)
      whistle_menu_move down
      continue
      ;;
    enter)
      _mu_shortcut=$(whistle_menu_key "$_mu_index")
      ;;
    char:*)
      _mu_shortcut=${_mu_action#char:}
      ;;
    *)
      continue
      ;;
    esac

    _mu_selection=$(printf '%s\n' "$_mu_model" | whistle_menu_select_key "$_mu_shortcut")
    if [ -z "$_mu_selection" ]; then
      # j / k：没被分配成快捷键时按 vim 习惯上下移动。
      # 菜单项够多（≥19 项时 j、≥20 项时 k）时这两个字母已经是快捷键，
      # 那就照旧跳转 —— 同一个键在同一份列表里只做一件事。
      case "$_mu_shortcut" in
      j) whistle_menu_move down ;;
      k) whistle_menu_move up ;;
      esac
      continue
    fi
    _mu_wid=${_mu_selection%%|*}
    _mu_rest=${_mu_selection#*|}
    _mu_pid=${_mu_rest%%|*}
    whistle_menu_activate "$_mu_wid" "$_mu_pid"
    return 0
  done
}
