#!/usr/bin/env bats
# shellcheck shell=bash
#
# L3：通过 expect 伪终端附着隔离 server，验证 popup 的真实键盘交互与终端恢复。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
  EXPECT_HELPER="$WHISTLE_ROOT/test/test_helper/menu_popup.exp"
  EXPECT_LOG="$BATS_TEST_TMPDIR/menu-popup.log"
  EXPECT_DRIVER_LOG="$BATS_TEST_TMPDIR/menu-popup-driver.log"

  wt new-window -d -n w2
  P1=$(wt display -p -t w1 '#{pane_id}')
  P2=$(wt display -p -t w2 '#{pane_id}')
  W1=$(wt display -p -t w1 '#{window_id}')
  W2=$(wt display -p -t w2 '#{window_id}')

  # 使用无用户 rc 的 /bin/sh，让 expect 有稳定提示符，也绝不读取真实 shell 配置。
  wt respawn-pane -k -t "$P1" /bin/sh
  wt respawn-pane -k -t "$P2" /bin/sh
  wt set -g @whistle_spin off
}

teardown() {
  wt_stop
}

seed_two_idle() {
  "$CLI" idle -t "$P1"
  "$CLI" idle -t "$P2"
}

run_popup() {
  local scenario="$1" marker="$2"
  # shellcheck disable=SC2016 # 由 bash -c 的位置参数传入，不在外层展开
  run env WHISTLE_MENU_CLI="$CLI" \
    WHISTLE_MENU_SCENARIO="$scenario" \
    WHISTLE_MENU_LOG="$EXPECT_LOG" \
    WHISTLE_MENU_MARKER="$marker" \
    WHISTLE_MENU_PANE="$P1" \
    WHISTLE_MENU_PANE2="$P2" \
    bash -c 'expect "$1" > "$2" 2>&1' _ "$EXPECT_HELPER" "$EXPECT_DRIVER_LOG"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' '--- expect 末尾输出 ---' >&2
    grep -a -E '超时|提前退出' "$EXPECT_DRIVER_LOG" >&2 || true
  fi
  assert_eq "$status" 0
}

@test "menu popup e2e: 两个 idle 窗口中 Down+Enter 跳到第二项" {
  seed_two_idle

  run_popup down-enter DOWN_ENTER_OK

  assert_eq "$(wt display -p -t main '#{window_id}')" "$W2"
  assert_contains "$(cat "$EXPECT_LOG")" 'POPUP_DOWN_ENTER_OK'
}

@test "menu popup e2e: 快捷键激活 running+done 只清通知且保留活动态" {
  "$CLI" running -t "$P1"
  "$CLI" "done" '第一项' -t "$P1"
  "$CLI" running -t "$P2"
  "$CLI" "done" '第二项' -t "$P2"

  run_popup shortcut-second SHORTCUT_OK

  assert_eq "$(wt display -p -t main '#{window_id}')" "$W2"
  assert_eq "$(optp @whistle_notice "$P2")" ''
  assert_eq "$(optp @whistle "$P2")" 'running'
  # 未选中的窗口不该被顺带已读。
  assert_eq "$(optp @whistle_notice "$P1")" 'done'
  assert_contains "$(cat "$EXPECT_LOG")" 'POPUP_SHORTCUT_OK'
}

@test "menu popup e2e: 不足 26 项时 q 不退出，之后仍能 Down+Enter" {
  seed_two_idle

  run_popup q-down-enter Q_NOT_EXIT_OK

  assert_eq "$(wt display -p -t main '#{window_id}')" "$W2"
  assert_contains "$(cat "$EXPECT_LOG")" 'POPUP_Q_NOT_EXIT_OK'
}

@test "menu popup e2e: Up/Down 不误判 Esc，单独 Esc 退出后输入正常" {
  seed_two_idle

  run_popup escape ESC_OK

  assert_eq "$(wt display -p -t main '#{window_id}')" "$W1"
  assert_contains "$(cat "$EXPECT_LOG")" 'POPUP_ESC_OK'
}

@test "menu popup e2e: Ctrl-C 关闭弹窗并恢复后续输入与光标输出" {
  seed_two_idle

  run_popup interrupt INTERRUPT_OK

  local esc
  esc=$(printf '\033')
  assert_contains "$(cat "$EXPECT_LOG")" 'POPUP_INTERRUPT_OK'
  assert_contains "$(cat "$EXPECT_LOG")" "${esc}[?25h"
}

@test "menu popup e2e: 状态变了菜单自己刷新，不用重开" {
  seed_two_idle

  run_popup live-refresh FRESH_RUNNING_MARKER

  # 标记出现在弹窗那一行里 = 菜单自己重绘过；没重开过（整个场景只开一次菜单）。
  # 断言锚在行首的 "(1) " 上：状态栏的瞬时提示也会带这条消息，只认 marker
  # 会把提示当成刷新（假阳性）。带 -state 后缀：退出探针里也有 marker。
  assert_contains \
    "$(grep -a '(1) .*FRESH_RUNNING_MARKER-state' "$EXPECT_LOG")" \
    'FRESH_RUNNING_MARKER-state'
  assert_contains "$(cat "$EXPECT_LOG")" 'POPUP_FRESH_RUNNING_MARKER'
}

@test "menu popup e2e: 列表重排后高亮仍跟着原窗口" {
  "$CLI" running -t "$P1"
  "$CLI" running -t "$P2"

  run_popup reorder-follow REORDER_MARKER

  # 第二项被改成待处理后会排到第一位；高亮若没跟着窗口走，Enter 会跳到别的窗口。
  assert_eq "$(wt display -p -t main '#{window_id}')" "$W2"
  assert_eq "$(optp @whistle_notice "$P2")" ''
  assert_eq "$(optp @whistle "$P2")" 'running'
}

@test "menu popup e2e: 状态没变时不重绘" {
  seed_two_idle

  run_popup no-redraw NO_REDRAW

  assert_contains "$(cat "$EXPECT_DRIVER_LOG")" 'REDRAW'
}
