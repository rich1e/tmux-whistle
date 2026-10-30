#!/usr/bin/env bats
# shellcheck shell=bash
# doctor 的 terminal-notifier 诊断：不能只检查命令是否存在。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  wt set -g @whistle_os on
}

teardown() {
  wt_stop
}

@test "doctor: terminal-notifier 3.x 执行 diagnose 并展示授权结果" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 3.1.0.\n'
  exit 0
fi
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/tn.args"
printf 'authorization       authorized\n'
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_eq "$(cat "$BATS_TEST_TMPDIR/tn.args")" '-diagnose'
  assert_contains "$output" 'authorization       authorized'
}

@test "doctor: diagnose rc0 只声明已授权，仍原样列出其它投递问题" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 3.1.0.\n'
  exit 0
fi
printf 'authorization       authorized\n'
printf 'alert style         banners only; alerts recommended\n'
exit 0
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" 'terminal-notifier 已授权（其它投递设置见上方诊断）'
  assert_contains "$output" 'alerts recommended'
  assert_not_contains "$output" 'terminal-notifier 诊断通过'
}

@test "doctor: 旧版 terminal-notifier 提示升级而不是误报未授权" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 2.0.0.\n'
  exit 0
fi
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/tn.unexpected"
exit 99
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" '升级'
  [ ! -e "$BATS_TEST_TMPDIR/tn.unexpected" ]
}

@test "doctor: diagnose 未授权时展示结果但不影响其它检查" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 3.1.0.\n'
  exit 0
fi
printf 'authorization       denied\n'
exit 3
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" 'authorization       denied'
  assert_contains "$output" '系统设置 → 通知 → terminal-notifier'
  assert_contains "$output" '已读钩子'
}
