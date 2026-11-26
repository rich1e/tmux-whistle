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

# 四个扫描函数共用的 awk 序言。抄四遍的话，多字节那条坑改一处漏三处。
WHISTLE_DETECT_AWK_LIB='
  function has(s, n) { return index(s, n) > 0 }
  # ⚠️ 提示符后面跟的是 **U+00A0（NBSP）**，不是普通空格 —— Claude Code 与
  # Codex 的真实屏幕都这样（实测 capture-pane 取到 ❯ c2 a0 20 20 …）。
  # 只剥 [ \t] 的话「空输入框」永远剥不干净，空闲态被判成空分类。
  # 统一先归一化成普通空格，再按行首尾剥。
  # ⚠️ NBSP 必须写成**字符串字面量**再交给 gsub：awk 的正则字面量里
  # 八进制转义不被解释成字节（POSIX 只规定字符串字面量有这种转义），
  # 写成正则字面量会去匹配字面上的反斜杠加数字，永远命中不了。
  function trim(s,   nbsp) {
    nbsp = "\302\240"
    gsub(nbsp, " ", s)
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
  }
  # 分隔线：整行只有 - 或 ─，且至少 3 个字符
  function is_rule(s,   t, c) {
    t = trim(s)
    if (t == "") return 0
    c = gsub(/─/, "", t)
    c += gsub(/-/, "", t)
    return (t == "" && c >= 3)
  }
  # 输入框起头：行首（可带缩进）是 › 或 ❯
  function is_prompt(s,   t) {
    t = trim(s)
    return index(t, "›") == 1 || index(t, "❯") == 1
  }
  # 只有提示符、没有内容 —— 空输入框
  function empty_prompt(b,   n, ls, t, r) {
    n = split(b, ls, "\n")
    if (n < 1) return 0
    t = trim(ls[1])
    if (index(t, "›") == 1 || index(t, "❯") == 1) r = substr(t, 4)
    else return 0
    return (r ~ /^[ \t]*$/)
  }
  # 拼接非空行缓冲 _tailbuf[from..to]（由主体规则块按非空行填）
  #
  # ⚠️ 数组名必须与各函数自己的标量缓冲（out / box）**不同名**：awk 没有
  # 局部变量，序言与主体拼在同一个程序里共享全局名 —— 同名会直接报
  # 「can not assign to buf; it is an array name」。
  function joins(from, to,   i, s) {
    if (from < 1) from = 1
    s = ""
    for (i = from; i <= to; i++) s = s _tailbuf[i] "\n"
    return s
  }
'

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
	awk "$WHISTLE_DETECT_AWK_LIB"'
    is_rule($0) {
      seen = 1
      out = ""
      next
    }
    seen {
      out = out $0 "\n"
    }
    END {
      printf "%s", out
    }
  '
}

# whistle_screen_prompt_box
# stdin=整屏，stdout=最后一条提示行（`❯` / `›` 起头）到下一条分隔线或 EOF；
# 没有分隔线时把底部状态栏一并带上。
whistle_screen_prompt_box() {
	awk "$WHISTLE_DETECT_AWK_LIB"'
    {
      if (is_prompt($0)) {
        inbox = 1
        out = $0 "\n"
        next
      }
      if (!inbox) next
      if (is_rule($0)) {
        inbox = 0
        next
      }
      out = out $0 "\n"
    }
    END {
      printf "%s", out
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
# 整屏只扫一遍 —— 每秒每个 pane 都要跑，多次 fork 会把轮询成本堆起来。
whistle_classify_codex() {
	awk "$WHISTLE_DETECT_AWK_LIB"'
    {
      line[NR] = $0
      if (trim($0) != "") { ne++; _tailbuf[ne] = $0 }
      if (is_prompt($0)) pstart = NR
      if (is_rule($0)) rule[NR] = 1
    }
    END {
      # 尾部只看**非空**行：真实 TUI 的对话框上方/下方常有大量空白行，
      # 按物理行取 tail 会把信号行挡在窗口外（trust 页就是这么漏的）。
      tail20 = joins(ne - 19, ne)
      tail12 = joins(ne - 11, ne)

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

# whistle_classify_claude
# stdin=整屏，stdout ∈ running / wait / idle / freeze / 空。
#
# 与 Codex 共用顺序；Claude 的差异在「转圈字符写在输入框里」——
# `❯ ✻ 思考中` 既不是空闲提示符，也已经过了 UserPromptSubmit，
# 所以提示符后面跟着 spinner 字符就是 running。
whistle_classify_claude() {
	awk "$WHISTLE_DETECT_AWK_LIB"'
    function spinner_lead(t,   n, cs, i) {
      n = split("⠁ ⠂ ⠄ ⠈ ⠐ ⠠ ⡀ ⢀ ✢ ✳ ✷ ✸ ✻ ✽", cs, " ")
      for (i = 1; i <= n; i++) if (index(t, cs[i]) == 1) return 1
      return 0
    }
    {
      line[NR] = $0
      if (trim($0) != "") { ne++; _tailbuf[ne] = $0 }
      if (is_prompt($0)) pstart = NR
      if (is_rule($0)) rule[NR] = 1
    }
    END {
      tail12 = joins(ne - 11, ne)
      all = joins(1, ne)
      low = tolower(all)

      box = ""
      if (pstart > 0) {
        for (i = pstart; i <= NR; i++) {
          if (i > pstart && (i in rule)) break
          box = box line[i] "\n"
        }
      }

      # 提示框首行去掉提示符与空白后剩下的内容
      hasp = 0
      rest = ""
      n = split(box, ls, "\n")
      if (n >= 1) {
        first = trim(ls[1])
        if (index(first, "❯") == 1) {
          hasp = 1
          rest = trim(substr(first, 4))
        }
      }

      if (has(all, "showing detailed transcript")) {
        print "freeze"
        exit
      }
      if ((has(low, "do you want to proceed?") && has(low, "esc to cancel")) ||
          (has(low, "esc to cancel") && has(low, "enter to confirm"))) {
        print "wait"
        exit
      }
      if (has(tail12, "esc to interrupt") || spinner_lead(rest)) {
        print "running"
        exit
      }
      if (hasp && length(rest) == 0) {
        print "idle"
        exit
      }
      print ""
    }
  '
}

# whistle_classify_screen <agent>
# stdin=整屏；agent ∈ codex / claude。未知 agent 输出空。
whistle_classify_screen() {
	case "${1:-}" in
	codex) whistle_classify_codex ;;
	claude) whistle_classify_claude ;;
	*) return 0 ;;
	esac
}

# whistle_agent_kind <cmd>
# stdout ∈ claude / codex / opencode / 空。
#
# ⚠️ 归一化规则必须与 whistle_agent_windows 的 awk 逐项一致
# （去 `.exe`、转小写、按前缀归类），否则「菜单里画哪个图标」与
# 「谁可以被读屏接管」会给出两个答案。
whistle_agent_kind() {
	_dr_kind="${1:-}"
	case "$_dr_kind" in
	*[A-Z]*) _dr_kind=$(printf '%s' "$_dr_kind" | tr '[:upper:]' '[:lower:]') ;;
	esac
	_dr_kind=${_dr_kind%.exe}
	case "$_dr_kind" in
	claude*) printf 'claude' ;;
	codex*) printf 'codex' ;;
	opencode*) printf 'opencode' ;;
	esac
}

# whistle_detect_eligible <cmd> <argv> <agent_cmds>
# exit 0 = 这个 pane 可以被读屏接管。
#
# 三条判据，缺一不可：
#   1. 前台进程是认识的 agent（whistle_agent_kind 非空）——
#      认不出来就没有对应的规则表，读屏只能瞎猜。
#   2. argv 里没有 `exec` 子命令 —— `codex exec` / `claude -p` 是一次性
#      非交互进程，屏幕上没有输入框，读屏只会拿到一段静止输出。
#   3. 该进程名在 @whistle_agent_cmds 名单里 —— 用户可以把某个 agent 摘掉。
whistle_detect_eligible() {
	_dr_cmd="${1:-}"
	_dr_argv="${2:-}"
	_dr_cmds="${3:-}"

	_dr_kind=$(whistle_agent_kind "$_dr_cmd")
	[ -n "$_dr_kind" ] || return 1

	case " $_dr_argv " in
	*" exec "*) return 1 ;;
	esac

	_dr_base="$_dr_cmd"
	case "$_dr_base" in
	*[A-Z]*) _dr_base=$(printf '%s' "$_dr_base" | tr '[:upper:]' '[:lower:]') ;;
	esac
	_dr_base=${_dr_base%.exe}

	# shellcheck disable=SC2086  # 名单本来就是空格分隔的词表
	for _dr_t in $_dr_cmds; do
		_dr_t=${_dr_t%.exe}
		case "$_dr_base" in
		"$_dr_t" | "$_dr_t"*) return 0 ;;
		esac
	done
	return 1
}
