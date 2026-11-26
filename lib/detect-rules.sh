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

# whistle_classify_codex
# stdin=整屏，stdout ∈ running / wait / idle / freeze / 空。
#
# 顺序固定为 freeze → wait → running → idle，**首次命中即返回**：
# 权限对话框页面同时会显示 `• Running <command>`，wait 必须压在 running 之上；
# 滚动冻结时底部仍有 `› Ask Codex…` 提示框，freeze 必须压在 idle 之上。
#
# 区域来自 whistle_screen_tail / _prompt_box 的同一套口径，但整屏只扫一遍 ——
# 每秒每个 pane 都要跑，多次 fork 会把轮询成本堆起来。
whistle_classify_codex() {
	awk '
    function has(s, n) { return index(s, n) > 0 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function is_rule(s,   t, c) {
      t = trim(s)
      if (t == "") return 0
      c = gsub(/─/, "", t)
      c += gsub(/-/, "", t)
      return (t == "" && c >= 3)
    }
    function is_prompt(s,   t) {
      t = trim(s)
      return index(t, "›") == 1 || index(t, "❯") == 1
    }
    # 只有提示符、没有内容 —— 空输入框就是空闲
    function empty_prompt(b,   n, ls, t, r) {
      n = split(b, ls, "\n")
      if (n < 1) return 0
      t = trim(ls[1])
      if (index(t, "›") == 1 || index(t, "❯") == 1) r = substr(t, 4)
      else return 0
      return (r ~ /^[ \t]*$/)
    }
    function join(from, to,   i, s) {
      s = ""
      for (i = from; i <= to; i++) s = s buf[i] "\n"
      return s
    }
    {
      line[NR] = $0
      if (trim($0) != "") { ne++; buf[ne] = $0 }
      if (is_prompt($0)) pstart = NR
      if (is_rule($0)) rule[NR] = 1
    }
    END {
      # 尾部只看**非空**行：真实 TUI 的对话框上方/下方常有大量空白行，
      # 按物理行取 tail 会把信号行挡在窗口外（trust 页就是这么漏的）。
      tail20 = join(ne - 19 < 1 ? 1 : ne - 19, ne)
      tail12 = join(ne - 11 < 1 ? 1 : ne - 11, ne)

      box = ""
      if (pstart > 0) {
        for (i = pstart; i <= NR; i++) {
          if (i > pstart && (i in rule)) break
          box = box line[i] "\n"
        }
      }

      if (has(tail20, "↓ Back to bottom") || has(tail20, "enter/esc latest") ||
          has(tail20, "↑/↓ to scroll") || has(tail20, "pgup/pgdn")) {
        print "freeze"
        exit
      }
      if (has(tail20, "Press enter to confirm") ||
          has(tail20, "Would you like to run the following command?") ||
          (has(tail20, "Trust this folder?") && has(tail20, "enter continue")) ||
          (has(tail20, "esc to cancel") && has(tail20, "to confirm"))) {
        print "wait"
        exit
      }
      if (!has(tail20, "Reconnect failed") &&
          (has(tail12, "esc to interrupt") || has(tail12, "• Working (") ||
           has(tail12, "• Running "))) {
        print "running"
        exit
      }
      if (has(box, "› Ask Codex to do anything") ||
          has(box, "› Ask a follow-up question") || empty_prompt(box)) {
        print "idle"
        exit
      }
      print ""
    }
  '
}
