#!/usr/bin/env bats
# shellcheck shell=bash
#
# 状态读写、窗口聚合、全局计数、清除、列表。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  # 测试本身可能就跑在真实 tmux pane 里（开发时的常态）。
  # $TMUX_PANE 会让 whistle_resolve_pane 指向真实 server 的 pane，
  # 所以这里清掉，强制走 WHISTLE_TMUX_SOCKET 指向的隔离 server。
  unset TMUX_PANE TMUX
}

teardown() {
  wt_stop
}

pane_of() {
  wt display -p -t w1 '#{pane_id}'
}

# -- 置状态 ----------------------------------------------------------------

@test "set: 写全部四个 pane option" {
  run whistle_state_set "done" '重构完成'
  assert_eq "$status" 0

  local p
  p=$(pane_of)
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'done'
  assert_eq "$(wt show -pqv -t "$p" @whistle_msg)" '重构完成'
  [ -n "$(wt show -pqv -t "$p" @whistle_at)" ]
  assert_eq "$(wt show -pqv -t "$p" @whistle_src)" 'manual'
}

@test "set: 未知状态被拒且不写任何东西" {
  local p
  p=$(pane_of)
  run whistle_state_set banana 'x'
  assert_eq "$status" 1
  assert_eq "$(wt show -pqv -t "$p" @whistle)" ''
}

@test "set: 消息落盘前已消毒（KP-3）" {
  whistle_state_set "done" '#{evil}{x}|y'
  local p
  p=$(pane_of)
  local m
  m=$(wt show -pqv -t "$p" @whistle_msg)
  assert_not_contains "$m" '#'
  assert_not_contains "$m" '{'
  assert_not_contains "$m" '}'
  assert_not_contains "$m" '|'
}

# -- 窗口聚合 --------------------------------------------------------------

@test "recompute: 单一 pane 时 window 态跟随它" {
  whistle_state_set "done" '做完了'
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_msg)" '做完了'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '1'
}

@test "recompute: 多 pane 按优先级聚合" {
  wt split-window -t w1
  local p1 p2 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  [ "$p1" != "$p2" ]

  whistle_state_set "running" '在跑' "$p1"
  whistle_state_set "wait" '等你批' "$p2"
  whistle_recompute_window "$w"

  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'wait'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_msg)" '等你批'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '1'
}

@test "recompute: 全空时 window 态为空字符串" {
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '0'
}

@test "recompute: pane 关掉后 window 态会降级（window-pane-changed 的意义）" {
  wt split-window -t w1
  local p2 w
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  [ -n "$p2" ]

  whistle_state_set "done" '做完了' "$p2"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'

  wt kill-pane -t "$p2"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

# -- 全局计数 --------------------------------------------------------------

@test "recompute_global: 四态分布写进 global option" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p1 p2 p3
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  whistle_state_set "running" '' "$p1"
  whistle_state_set "done" 'a' "$p2"
  whistle_state_set "error" 'b' "$p3"

  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_done')" '1'
  assert_eq "$(opt '@whistle_count_wait')" '0'
  assert_eq "$(opt '@whistle_count_error')" '1'
}

@test "recompute_global: 只数待处理状态，running 不算" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')

  whistle_state_set "running" '在跑' "$pa"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_pending')" '0'

  whistle_state_set "done" '好了' "$pb"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_pending')" '1'
}

@test "recompute_global: 跨 session 汇总" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')

  whistle_state_set "done" 'a' "$pa"
  whistle_state_set "wait" 'b' "$pb"
  whistle_state_set "error" 'c' "$pa"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_pending')" '2'
}

# -- 清除 ------------------------------------------------------------------

@test "clear: 清单个 pane 并同步清 window 态" {
  whistle_state_set "done" '做完了'
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'

  whistle_state_clear "$(pane_of)" > /dev/null
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "clear_window: 清掉整个窗口内所有待处理 pane" {
  wt split-window -t w1
  local p1 p2 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  [ "$p1" != "$p2" ]

  whistle_state_set "done" 'a' "$p1"
  whistle_state_set "wait" 'b' "$p2"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '2'

  whistle_clear_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '0'
}

@test "clear_window: running 状态不算待处理，不会被 clear 误清" {
  whistle_state_set "running" '还在跑'
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_clear_window "$w"
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" 'running'
}

@test "clear_all: 清掉全 server 的待处理状态" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')
  whistle_state_set "done" 'a' "$pa"
  whistle_state_set "wait" 'b' "$pb"

  whistle_clear_all
  assert_eq "$(wt show -pqv -t "$pa" @whistle)" ''
  assert_eq "$(wt show -pqv -t "$pb" @whistle)" ''
  assert_eq "$(opt '@whistle_pending')" '0'
}

# -- 查询 ------------------------------------------------------------------

@test "list_lines: 只列出待处理项，running 不出现" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')
  whistle_state_set "running" '在跑' "$pa"
  whistle_state_set "done" '做完了' "$pb"

  run whistle_list_lines
  assert_contains "$output" 'other'
  assert_contains "$output" '做完了'
  assert_not_contains "$output" '在跑'
}

@test "pending_windows: 输出含 window_id 供菜单与 jump 使用" {
  whistle_state_set "done" '做完了'
  run whistle_pending_windows
  assert_contains "$output" '@'
  # 六列：session|window_id|window_name|window_index|state|msg
  assert_eq "$(printf '%s\n' "$output" | awk -F'|' '{print NF}')" '6'
}

# -- agent_windows：菜单要列出「所有有 agent 的窗口」，不只是待处理 --------------

@test "agent_windows: 包含 running，而 pending_windows 不含" {
  whistle_state_set "running" '在跑'

  run whistle_agent_windows
  assert_contains "$output" 'running'
  assert_contains "$output" '在跑'

  run whistle_pending_windows
  assert_eq "$output" ''
}

@test "agent_windows: 从未上报过状态的 pane 不出现" {
  run whistle_agent_windows
  assert_eq "$output" ''
}

@test "agent_windows: 同窗口多 pane 只出一行，取 rank 最高的状态" {
  # list-panes -a 是 pane 粒度；不去重的话菜单里同一个窗口会出现两次。
  wt split-window -t w1
  local p1 p2
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  whistle_state_set "running" '在跑' "$p1"
  whistle_state_set "done" '做完了' "$p2"

  run whistle_agent_windows
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '1'
  assert_contains "$output" 'done'
  assert_contains "$output" '做完了'
}

@test "conf: 未设置的 option 回落到默认表" {
  run whistle_conf '@whistle_color_done'
  assert_eq "$output" '#00af00'
  run whistle_conf '@whistle_os'
  assert_eq "$output" 'off'
}

@test "conf: 用户显式设置的值优先于默认表" {
  wt set -g @whistle_os on
  run whistle_conf '@whistle_os'
  assert_eq "$output" 'on'
}