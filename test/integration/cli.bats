#!/usr/bin/env bats
# shellcheck shell=bash
#
# CLI 层：菜单参数构造、跳转、列表、开关、doctor。
#
# 菜单没法在无头 server 里真弹出来（display-menu 需要 attached client），
# 所以这里测的是参数构造 —— 那部分错了才是真 bug。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  unset TMUX_PANE TMUX TMUX_SOCKET
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
}

teardown() {
  wt_stop
}

pane_of() {
  wt display -p -t w1 '#{pane_id}'
}

# -- 菜单 ------------------------------------------------------------------

@test "menu-args: 每项是 label / key / command 三元组" {
  "$CLI" "done" '做完了'
  run "$CLI" --menu-args
  assert_eq "$status" 0

  local n
  n=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  assert_eq "$n" 3

  local label key cmd
  label=$(printf '%s\n' "$output" | sed -n 1p)
  key=$(printf '%s\n' "$output" | sed -n 2p)
  cmd=$(printf '%s\n' "$output" | sed -n 3p)

  assert_contains "$label" '完成'
  assert_contains "$label" 'main:w1'
  assert_contains "$label" '做完了'
  assert_eq "$key" '1'
  assert_contains "$cmd" 'switch-client -t main'
  assert_contains "$cmd" 'select-window -t @'
  assert_contains "$cmd" 'clear -t @'
}

@test "menu-args: 多窗口时键位依次是 1 2 3" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p1 p2 p3
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  "$CLI" "done" 'a' -t "$p1"
  "$CLI" "wait" 'b' -t "$p2"
  "$CLI" "error" 'c' -t "$p3"

  run "$CLI" --menu-args
  local keys
  keys=$(printf '%s\n' "$output" | sed -n '2p;5p;8p')
  assert_eq "$keys" "1
2
3"
}

@test "menu-args: 没有待处理项时输出为空" {
  run "$CLI" --menu-args
  assert_eq "$output" ''
}

# -- 键位（回归：第 10 项起曾算成空） ---------------------------------------

# 造 n 个待处理窗口（含 wt_start 自带的 w1）
seed_pending_windows() {
  local n="$1" i p
  for ((i = 2; i <= n; i++)); do
    wt new-window -d -n "w$i"
  done
  for ((i = 1; i <= n; i++)); do
    p=$(wt display -p -t "w$i" '#{pane_id}')
    "$CLI" "done" "m$i" -t "$p"
  done
}

# 每项是 label / key / command 三行，取每组的第 2 行
menu_keys() {
  printf '%s\n' "$1" | awk 'NR % 3 == 2'
}

@test "menu-args: 第 9 项是数字 9，第 10 项起接字母" {
  # 1-9 用数字，之后接字母表：第 10 项应落在字母表第 1 位。
  # 曾同时踩两个坑：位置算成 $1 - 10（第 10 项得到 0），且算术展开后多写了一个
  # ')'（cut 收到 "0)" 而非 "0"）。两者都让 cut 报错、stderr 被吞、key 变空。
  # 空 key 在 display-menu 里合法（表示"无快捷键"），所以菜单照常弹出、
  # 只是那一项不能用键选中 —— 不报错，靠断言才抓得到。
  seed_pending_windows 11

  run "$CLI" --menu-args
  assert_eq "$status" 0

  local keys
  keys=$(menu_keys "$output")
  assert_eq "$(printf '%s\n' "$keys" | sed -n 9p)" '9'
  assert_eq "$(printf '%s\n' "$keys" | sed -n 10p)" 'a'
  assert_eq "$(printf '%s\n' "$keys" | sed -n 11p)" 'b'
}

@test "menu-args: 满 26 项时键位全部非空且互不相同" {
  # 上限是 26（9 个数字 + 17 个字母，a..q），第 26 项是 q
  seed_pending_windows 26

  run "$CLI" --menu-args
  assert_eq "$status" 0

  local keys total nonempty distinct
  keys=$(menu_keys "$output")
  total=$(printf '%s\n' "$keys" | wc -l | tr -d ' ')
  nonempty=$(printf '%s\n' "$keys" | grep -c .)
  distinct=$(printf '%s\n' "$keys" | sort -u | wc -l | tr -d ' ')

  assert_eq "$total" 26
  assert_eq "$nonempty" 26
  assert_eq "$distinct" 26
  assert_eq "$(printf '%s\n' "$keys" | sed -n 26p)" 'q'
}

@test "menu-args: 超过 26 项时截断到 26" {
  seed_pending_windows 28

  run "$CLI" --menu-args
  assert_eq "$status" 0

  local total
  total=$(menu_keys "$output" | wc -l | tr -d ' ')
  assert_eq "$total" 26
}

@test "menu-args: 命令里用的是 CLI 绝对路径（不依赖 PATH）" {
  "$CLI" "done" 'x'
  run "$CLI" --menu-args
  local cmd
  cmd=$(printf '%s\n' "$output" | sed -n 3p)
  assert_contains "$cmd" "$CLI"
}

@test "menu: 无 attached client 时降级成文本列表而不是失败" {
  "$CLI" "done" '做完了'
  run "$CLI" menu
  assert_eq "$status" 0
  assert_contains "$output" '做完了'
}

# -- jump ------------------------------------------------------------------

@test "jump: 按 session:window 跳转并清除" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  run "$CLI" jump 'other:api'
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p" @whistle)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "jump: 找不到目标时报错退出" {
  run "$CLI" jump 'nope:nothing'
  assert_eq "$status" 1
  assert_contains "$output" '找不到'
}

# -- 列表 / 清除 / 开关 -----------------------------------------------------

@test "list: 无待处理时给出友好提示" {
  run "$CLI" list
  assert_eq "$status" 0
  assert_contains "$output" '没有待处理'
}

@test "list: 有项时输出表头与计数" {
  "$CLI" "done" '做完了'
  run "$CLI" list
  assert_contains "$output" 'SESSION'
  assert_contains "$output" '做完了'
  assert_contains "$output" '共 1 项'
}

@test "clear -a: 清空全局" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')
  "$CLI" "done" 'a' -t "$pa"
  "$CLI" "wait" 'b' -t "$pb"

  run "$CLI" clear -a
  assert_eq "$status" 0
  assert_eq "$(opt '@whistle_pending')" '0'
}

@test "开关: on 与 off 写全局标志" {
  run "$CLI" off
  assert_eq "$(opt '@whistle_enabled')" 'off'
  run "$CLI" on
  assert_eq "$(opt '@whistle_enabled')" 'on'
}

# -- 参数与用法 -------------------------------------------------------------

@test "未知子命令：打印用法并非零退出" {
  run "$CLI" frobnicate
  assert_eq "$status" 1
  assert_contains "$output" '用法'
}

@test "--help: 列出主要子命令" {
  run "$CLI" --help
  assert_eq "$status" 0
  for c in "done" "wait" "error" "running" clear list menu jump doctor; do
    assert_contains "$output" "$c"
  done
}

@test "done 带 -t 指定目标 pane" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" '目标明确' -t "$p2"
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'done'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" ''
}

@test "--dry-run: 只打印不执行" {
  run "$CLI" "done" 'x' --dry-run
  assert_eq "$status" 0
  assert_contains "$output" '将置'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" ''
}

# -- doctor ----------------------------------------------------------------

@test "doctor: 能跑完并报告 tmux 版本" {
  run "$CLI" doctor
  assert_contains "$output" 'tmux'
  assert_contains "$output" '投递渠道'
  # 未安装状态下的"未注入"只是提醒，不该让 doctor 整体失败
  [[ "$output" == *'未注入'* ]] || [[ "$output" == *'已注入'* ]]
}
@test "menu-args: 生成的命令是合法的 tmux 命令（不会 Unknown command）" {
  "$CLI" "done" '做完了'
  run "$CLI" --menu-args
  local cmd
  cmd=$(printf '%s\n' "$output" | sed -n 3p)

  # 用 source-file 让 tmux 用**它自己的命令解析器**吃这条命令 ——
  # display-menu 的第三参就是这样被解析的。之前这里把 CLI 路径裸放在
  # 命令位置，tmux 会报 "Unknown command: .../tmux-whistle"。
  printf '%s\n' "$cmd" > "$BATS_TEST_TMPDIR/cmd.tmux"
  run wt source-file "$BATS_TEST_TMPDIR/cmd.tmux"

  assert_not_contains "$output" 'Unknown command'
  assert_not_contains "$output" 'unknown command'
  assert_not_contains "$output" 'parse error'
}

@test "menu-args: CLI 调用被包在 run-shell 里" {
  "$CLI" "done" 'x'
  run "$CLI" --menu-args
  local cmd
  cmd=$(printf '%s\n' "$output" | sed -n 3p)
  assert_contains "$cmd" "run-shell"
  assert_contains "$cmd" "$CLI"
}
