#!/usr/bin/env bats
# shellcheck shell=bash
# install.sh 的桌面通知引导：只跑 dry-run，所有后端都必须是 fake 或不存在。

load '../test_helper/whistle'

setup() {
  INSTALL_FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  INSTALL_TOOLS_BIN="$BATS_TEST_TMPDIR/tools-bin"
  INSTALL_HOME="$BATS_TEST_TMPDIR/home"
  INSTALL_UNEXPECTED="$BATS_TEST_TMPDIR/unexpected-backend-call"
  mkdir -p "$INSTALL_FAKE_BIN" "$INSTALL_TOOLS_BIN" "$INSTALL_HOME"

  # 不继承宿主机 PATH：否则 macOS 真 osascript 会混进「无后端」分支。
  # install dry-run 仍需要这些基础工具，逐一链接但不带任何通知后端。
  local tool
  for tool in dirname awk sed mkdir rm ln cp mv date chmod; do
    ln -s "$(command -v "$tool")" "$INSTALL_TOOLS_BIN/$tool"
  done
}

run_install_dry() {
  run env \
    HOME="$INSTALL_HOME" \
    WHISTLE_HOME="$INSTALL_HOME/data/tmux-whistle" \
    WHISTLE_BIN_DIR="$INSTALL_HOME/bin" \
    TMUX_CONF_LOCAL="$INSTALL_HOME/tmux.conf.local" \
    PATH="$INSTALL_FAKE_BIN:$INSTALL_TOOLS_BIN" \
    "$WHISTLE_ROOT/install.sh" --dry-run --no-hooks
}

fake_install_tn() {
  local version="$1"
  cat > "$INSTALL_FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier $version\n'
  exit 0
fi
printf '%s\n' "\$@" > "$INSTALL_UNEXPECTED"
exit 99
EOF
  chmod +x "$INSTALL_FAKE_BIN/terminal-notifier"
}

fake_install_backend() {
  local name="$1"
  cat > "$INSTALL_FAKE_BIN/$name" << EOF
#!/bin/sh
printf '%s\n' "\$@" > "$INSTALL_UNEXPECTED"
exit 99
EOF
  chmod +x "$INSTALL_FAKE_BIN/$name"
}

@test "install: terminal-notifier 3.x 提示 diagnose 而不是 Script Editor" {
  fake_install_tn '3.1.0.'

  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" 'terminal-notifier -diagnose'
  assert_not_contains "$output" 'Script Editor'
  [ ! -e "$INSTALL_UNEXPECTED" ]
}

@test "install: 旧版 terminal-notifier 提示升级，不误发 diagnose 引导" {
  fake_install_tn '2.0.0.'

  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" '升级'
  assert_contains "$output" '2.0.0.'
  assert_not_contains "$output" 'Script Editor'
  [ ! -e "$INSTALL_UNEXPECTED" ]
}

@test "install: 没有 terminal-notifier 时依次选择 osascript 提示" {
  fake_install_backend osascript

  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" 'Script Editor'
  assert_not_contains "$output" 'terminal-notifier -diagnose'
  [ ! -e "$INSTALL_UNEXPECTED" ]
}

@test "install: 只有 notify-send 时按该后端提示" {
  fake_install_backend notify-send

  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" 'notify-send'
  assert_not_contains "$output" 'Script Editor'
  [ ! -e "$INSTALL_UNEXPECTED" ]
}

@test "install: 没有任何桌面后端时明确提示不可用" {
  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" '未检测到桌面通知后端'
  assert_contains "$output" 'terminal-notifier / osascript / notify-send'
  assert_not_contains "$output" 'Script Editor'
  [ ! -e "$INSTALL_UNEXPECTED" ]
}
