#!/bin/sh
# tmux-whistle 的屏幕分类器（纯函数，**不得调用 tmux**）。
#
# 输入一律走 stdin / 参数，输出走 stdout。它只回答一个问题：
# 「这块屏幕现在长什么样」，不读也不写任何 tmux option ——
# 状态槽位的写入在 lib/detect.sh，真源永远只有 hook 上报的值。
#
# ⚠️ 多字节字符**只能**用 `index()` 判位置，绝不能写 `==` 比较。
# 两个坑都实测过（macOS 26 的 one-true-awk + en_US.UTF-8）：
#
# 1. `substr($0, 1, 3) == "❯"` 对 **任意** 三字节 UTF-8 字符都成立 ——
#    `"─"` 与 `"❯"`、`"›"` 在这个 locale 下 `strcoll` 相等，比较恒真。
#    于是分隔线被当成提示行，输入框区域整个错位。
# 2. `[❯›]` 这样的方括号同样不可用：方括号里的多字节字符被拆成
#    `{E2, 9D, AF, 80, BA}` 一撮字节，任何以 `E2` 开头的行都会命中。
#
# `index()` 走的是逐字节查找，没有 collation，两个坑都绕开。

# whistle_screen_tail <n>
# stdin=整屏，stdout=最后 n 行**非空**行。
whistle_screen_tail() {
	_dr_n="${1:-12}"
	case "$_dr_n" in
	'' | *[!0-9]*) _dr_n=12 ;;
	esac
	[ "$_dr_n" -gt 0 ] || _dr_n=1

	awk -v n="$_dr_n" '
    $0 != "" {
      cnt++
      buf[cnt % n] = $0
    }
    END {
      first = cnt - n + 1
      if (first < 1) first = 1
      for (i = first; i <= cnt; i++) print buf[i % n]
    }
  '
}

# whistle_screen_after_rule
# stdin=整屏，stdout=最后一条分隔线（`---` / `──────`）之后的内容；
# 没有分隔线时输出空。
whistle_screen_after_rule() {
	awk '
    function is_rule(s,   t, c) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (s == "") return 0
      t = s
      c = gsub(/─/, "", t)
      c += gsub(/-/, "", t)
      return (t == "" && c >= 3)
    }
    is_rule($0) {
      seen = 1
      buf = ""
      next
    }
    seen {
      buf = buf $0 "\n"
    }
    END {
      printf "%s", buf
    }
  '
}

# whistle_screen_prompt_box
# stdin=整屏，stdout=最后一条提示行（`❯` / `›` 起头）到下一条分隔线或 EOF；
# 没有分隔线时把底部状态栏一并带上。
whistle_screen_prompt_box() {
	awk '
    function is_rule(s,   t, c) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (s == "") return 0
      t = s
      c = gsub(/─/, "", t)
      c += gsub(/-/, "", t)
      return (t == "" && c >= 3)
    }
    function is_prompt(s,   t) {
      t = s
      sub(/^[ \t]+/, "", t)
      return index(t, "❯") == 1 || index(t, "›") == 1
    }
    {
      if (is_prompt($0)) {
        inbox = 1
        buf = $0 "\n"
        next
      }
      if (!inbox) next
      if (is_rule($0)) {
        inbox = 0
        next
      }
      buf = buf $0 "\n"
    }
    END {
      printf "%s", buf
    }
  '
}
