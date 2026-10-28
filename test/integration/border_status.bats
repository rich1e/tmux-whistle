#!/usr/bin/env bats
# shellcheck shell=bash
#
# pane 边框状态行：分屏时按 pane 显示各自的状态符号。
#
# 注意：断言刻意收进 expect_contains 里。
# 把 case 直接写在 @test 体内、且分支里含 return 时，测试体以 `esac` 结尾，
# bats 会静默跳过整个用例（计数不符但不报错）。踩过一次，别再踩。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  wt_load deliver
  wt_load status-line
  unset TMUX_PANE TMUX
}

teardown() {
  wt_stop
}

win_of() {
  wt display -p -t w1 '#{window_id}'
}

expect_contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  *)
    printf '缺 [%s]，实际: [%s]\n' "$2" "$1" >&2
    return 1
    ;;
  esac
}

@test "border-status: pane 级徽章按 pane 各自渲染" {
  wt set -g @whistle_border_status top
  wt split-window -t w1
  local p1 p2 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')

  # 走新模型的真实链路：写**通知通道**，再由重算把有效态 @whistle_eff
  # 落到每个 pane 上 —— 徽章读的是派生值，直接写 @whistle 徽章是看不到的
  # （@whistle 是活动通道，只装 running / idle / gone）。
  # 状态名 'done' 必须加引号：裸的 done 会被 shell / ShellCheck 当成
  # 语句终止符（SC1010），而这里它只是一个普通实参。
  whistle_notice_set 'done' '做完了' '' "$p1"
  whistle_notice_set wait '要授权' '' "$p2"
  whistle_recompute_window "$w"

  # 与真实路径一致：whistle_deliver 先 ensure（发布 pane 徽章）再 apply
  whistle_ensure_status_line
  whistle_border_status_apply "$w"

  local fmt='#{P:#{E:pane-border-format}}'
  local out
  out=$(wt display -pF "$fmt")

  expect_contains "$out" '◆'
  expect_contains "$out" '◔'
}

@test "border-status: pane 徽章 format 大括号配平（畸形会静默渲染成空）" {
  whistle_pane_mark_publish
  local fmt
  fmt=$(opt '@whistle_pane_mark')
  local open close
  open=$(printf '%s' "$fmt" | tr -cd '{' | wc -c | tr -d ' ')
  close=$(printf '%s' "$fmt" | tr -cd '}' | wc -c | tr -d ' ')
  assert_eq "$open" "$close"
}
