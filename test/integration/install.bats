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
  for tool in dirname awk sed mkdir rm ln cp mv date chmod python3; do
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
  local expected_version
  expected_version=$("$WHISTLE_ROOT/bin/tmux-whistle" --version)

  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" "$expected_version 安装"
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

@test "install: 默认同时预览 Claude Code 与 Codex hooks" {
  run env \
    HOME="$INSTALL_HOME" \
    WHISTLE_HOME="$INSTALL_HOME/data/tmux-whistle" \
    WHISTLE_BIN_DIR="$INSTALL_HOME/bin" \
    TMUX_CONF_LOCAL="$INSTALL_HOME/tmux.conf.local" \
    PATH="$INSTALL_FAKE_BIN:$INSTALL_TOOLS_BIN" \
    "$WHISTLE_ROOT/install.sh" --dry-run

  assert_eq "$status" 0
  assert_contains "$output" '会安装 Claude Code 与 Codex hooks'
}

# -- OpenCode 插件形态（docs/opencode-integration-plan.md §6.1）-------------
#
# 这条守的是「目录 vs 单文件」那条最容易悄悄退回的错误：
# plugins/ 下的**单文件**会被当成 server part，而 server 的 TMUX_PANE 是启动
# 快照 —— pane 归属从一开始就是错的，且全程零报错。所以必须有测试钉住形态。

@test "install: OpenCode 插件以**目录**软链安装，链接名不带扩展名" {
  mkdir -p "$INSTALL_HOME/.config/opencode"
  run_install_dry

  assert_eq "$status" 0
  # dry-run 只打印命令，不真建链接 —— 断言命令里是目录形态
  assert_contains "$output" "ln -sfn"
  assert_contains "$output" "hooks/opencode"
  assert_contains "$output" ".config/opencode/plugins/tmux-whistle"
  # 反例：绝不能链单个 tui.js 到带 .js 的链接名
  assert_not_contains "$output" "hooks/opencode/tui.js /"
  assert_not_contains "$output" "plugins/tmux-whistle.js"
}

@test "install: 父目录不存在时也把 OpenCode 插件目录建出来" {
  # 不判断「~/.config/opencode 是否存在」是刻意的：mkdir -p 本来就该建父目录。
  # 早先写成「父目录不在就跳过」，结果从未装过 OpenCode 的人装完也没有插件。
  local fresh_home="$BATS_TEST_TMPDIR/fresh-home"
  mkdir -p "$fresh_home"
  [ ! -d "$fresh_home/.config/opencode" ]

  run env \
    HOME="$fresh_home" \
    WHISTLE_HOME="$fresh_home/data/tmux-whistle" \
    WHISTLE_BIN_DIR="$fresh_home/bin" \
    TMUX_CONF_LOCAL="$fresh_home/tmux.conf.local" \
    PATH="$INSTALL_FAKE_BIN:$INSTALL_TOOLS_BIN" \
    "$WHISTLE_ROOT/install.sh" --dry-run --no-hooks

  assert_eq "$status" 0
  assert_contains "$output" 'mkdir -p'
  assert_contains "$output" '.config/opencode/plugins'
}

@test "install: --uninstall 会删掉 OpenCode 插件链接" {
  local link="$INSTALL_HOME/.config/opencode/plugins/tmux-whistle"
  mkdir -p "$INSTALL_HOME/.config/opencode/plugins"
  ln -s "$WHISTLE_ROOT/hooks/opencode" "$link"
  [ -L "$link" ]

  run env \
    HOME="$INSTALL_HOME" \
    WHISTLE_HOME="$INSTALL_HOME/data/tmux-whistle" \
    WHISTLE_BIN_DIR="$INSTALL_HOME/bin" \
    TMUX_CONF_LOCAL="$INSTALL_HOME/tmux.conf.local" \
    PATH="$INSTALL_FAKE_BIN:$INSTALL_TOOLS_BIN" \
    "$WHISTLE_ROOT/install.sh" --uninstall

  assert_eq "$status" 0
  # 卸载漏了这一条 → 插件仍被加载、仍往 tmux 写状态
  [ ! -L "$link" ]
}

@test "install: Codex pane 本地启动器安装为独立软链" {
  run_install_dry

  assert_eq "$status" 0
  assert_contains "$output" 'tmux-whistle-codex'
  assert_contains "$output" "bin/tmux-whistle-codex"
}

@test "install: --uninstall 会删掉 Codex 启动器链接" {
  local link="$INSTALL_HOME/bin/tmux-whistle-codex"
  mkdir -p "$INSTALL_HOME/bin"
  ln -s "$WHISTLE_ROOT/bin/tmux-whistle-codex" "$link"
  [ -L "$link" ]

  run env \
    HOME="$INSTALL_HOME" \
    WHISTLE_HOME="$INSTALL_HOME/data/tmux-whistle" \
    WHISTLE_BIN_DIR="$INSTALL_HOME/bin" \
    TMUX_CONF_LOCAL="$INSTALL_HOME/tmux.conf.local" \
    PATH="$INSTALL_FAKE_BIN:$INSTALL_TOOLS_BIN" \
    "$WHISTLE_ROOT/install.sh" --uninstall

  assert_eq "$status" 0
  [ ! -L "$link" ]
}
