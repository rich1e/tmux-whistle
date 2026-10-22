#!/usr/bin/env bats
# shellcheck shell=bash
#
# KP-7：已读语义由 tmux hooks 实现。
#
# 实测已确认（探针实验）：`after-select-window` 触发时 run-shell 的参数会被
# format 展开，`#{window_id}` 指向刚被选中的那个窗口；无 attached client 时
# `select-window` 也能正常工作。下面的测试把这两点固化成回归保护。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  wt_load deliver
  wt_load status-line
  unset TMUX_PANE TMUX
  WHISTLE_CLI="$WHISTLE_ROOT/bin/tmux-whistle"
}

teardown() {
  wt_stop
}

win_of() {
  wt display -p -t "$1" '#{window_id}'
}

# -- hook 注册 -------------------------------------------------------------

@test "注册：读侧 hook 全部装上，且都指向 CLI" {
  whistle_hooks_install "$WHISTLE_CLI"

  for h in after-select-window after-select-pane window-pane-changed pane-exited; do
    run wt show-hooks -gw "$h"
    assert_contains "$output" 'tmux-whistle'
  done
}

@test "注册：push 侧不装任何 hook（原理 4.3 的职责边界）" {
  whistle_hooks_install "$WHISTLE_CLI"

  # alert-bell / monitor-* 与"agent 状态"无关，绝不能被我们挂上
  for h in alert-bell alert-activity pane-bell pane-activity pane-title-changed; do
    run wt show-hooks -gw "$h"
    assert_not_contains "$output" 'tmux-whistle'
  done
}

@test "注册：@whistle_clear_on_focus off 时不装已读 hook" {
  wt set -g @whistle_clear_on_focus off
  whistle_hooks_install "$WHISTLE_CLI"

  run wt show-hooks -gw after-select-window
  assert_not_contains "$output" 'tmux-whistle'
  # 但重算 hook 仍然要装
  run wt show-hooks -gw window-pane-changed
  assert_contains "$output" 'tmux-whistle'
}

@test "注册：不覆盖别人在同一 hook 上的条目（用命名 array key）" {
  # 先放一个第三方的钩子
  wt set-hook -g 'after-select-window[somebody-else]' 'display-message third-party'
  wt set-hook -g 'window-pane-changed[somebody-else]' 'display-message third-party'

  whistle_hooks_install "$WHISTLE_CLI"

  run wt show-hooks -gw after-select-window
  assert_contains "$output" 'third-party'
  assert_contains "$output" 'tmux-whistle'

  run wt show-hooks -gw window-pane-changed
  assert_contains "$output" 'third-party'
  assert_contains "$output" 'tmux-whistle'
}

@test "注册：重复安装不会把自己的 hook 越加越多" {
  whistle_hooks_install "$WHISTLE_CLI"
  whistle_hooks_install "$WHISTLE_CLI"
  whistle_hooks_install "$WHISTLE_CLI"

  run wt show-hooks -gw after-select-window
  assert_eq "$(printf '%s\n' "$output" | grep -c 'tmux-whistle')" '1'
}

@test "uninstall：只摘除自己那把 key，别人的留着" {
  wt set-hook -g 'after-select-window[somebody-else]' 'display-message third-party'
  whistle_hooks_install "$WHISTLE_CLI"
  whistle_hooks_uninstall

  run wt show-hooks -gw after-select-window
  assert_contains "$output" 'third-party'
  assert_not_contains "$output" 'tmux-whistle'
}

@test "uninstall：读侧 hook 全部摘掉" {
  whistle_hooks_install "$WHISTLE_CLI"
  whistle_hooks_uninstall

  for h in after-select-window after-select-pane window-pane-changed pane-exited; do
    run wt show-hooks -gw "$h"
    assert_not_contains "$output" 'tmux-whistle'
  done
}

# -- KP-7：hook 里 #{window_id} 展开正确 -------------------------------------

@test "KP-7: after-select-window 里 #{window_id} 展开为刚被选中的窗口" {
  wt new-window -d -n w2
  local out="$BATS_TEST_TMPDIR/probe"
  rm -f "$out"

  wt set-hook -g after-select-window \
    "run-shell -b 'echo #{window_id} > $out'"
  wt select-window -t w2

  wt_wait_until 3000 "[ -s '$out' ]"
  assert_eq "$(cat "$out")" "$(win_of w2)"
}

@test "KP-7: 无 attached client 时 select-window 也能触发 hook" {
  # 这条决定了集成测试能不能在无头 server 上覆盖"已读清除"
  local out="$BATS_TEST_TMPDIR/probe2"
  rm -f "$out"

  wt set-hook -g after-select-window \
    "run-shell -b 'echo #{window_id} > $out'"
  wt select-window -t w1

  wt_wait_until 3000 "[ -s '$out' ]"
  assert_eq "$(cat "$out")" "$(win_of w1)"
}

# -- 已读清除的实际行为 -----------------------------------------------------

@test "已读：切进窗口后该窗口的待处理状态被清除" {
  wt new-window -d -n w2
  local p w1
  p=$(wt display -p -t w1 '#{pane_id}')
  w1=$(win_of w1)

  whistle_state_set "done" '做完了' "$p" > /dev/null
  whistle_recompute_window "$w1"
  assert_eq "$(wt show -wv -t "$w1" @whistle_win)" 'done'

  whistle_read_window "$w1"

  assert_eq "$(wt show -pqv -t "$p" @whistle)" ''
  assert_eq "$(wt show -wv -t "$w1" @whistle_win)" ''
}

@test "已读：读别的窗口不影响本窗口（KP-7 多 client 风险的最小对照）" {
  wt new-window -d -n w2
  local p w1
  p=$(wt display -p -t w1 '#{pane_id}')
  w1=$(win_of w1)

  whistle_state_set "done" '做完了' "$p" > /dev/null
  whistle_recompute_window "$w1"

  whistle_read_window "$(win_of w2)"

  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'done'
}

@test "已读：非待处理窗口被读不产生任何写操作" {
  local p
  p=$(wt display -p -t w1 '#{pane_id}')
  whistle_state_set "running" '还在跑' "$p" > /dev/null

  whistle_read_window "$(win_of w1)"

  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
}

@test "已读：read_pane 只清那一个 pane" {
  wt split-window -t w1
  local p1 p2
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)

  whistle_state_set "done" 'a' "$p1" > /dev/null
  whistle_state_set "wait" 'b' "$p2" > /dev/null

  whistle_read_pane "$p1"

  assert_eq "$(wt show -pqv -t "$p1" @whistle)" ''
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'wait'
}

@test "重算：pane 增删后 window 聚合态与全局计数都被刷新" {
  wt split-window -t w1
  local p2 w
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(win_of w1)

  whistle_state_set "done" '做完了' "$p2" > /dev/null
  "$WHISTLE_CLI" --recompute

  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'
  assert_eq "$(opt '@whistle_pending')" '1'

  wt kill-pane -t "$p2"
  "$WHISTLE_CLI" --recompute

  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_eq "$(opt '@whistle_pending')" '0'
}