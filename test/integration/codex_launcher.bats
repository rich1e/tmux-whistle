#!/usr/bin/env bats
# shellcheck shell=bash
#
# tmux-whistle-codex 是 pane 本地启动器：它必须先建立可信 PaneBinding，
# 再以 --no-daemon 启动 Codex，避免多个 TUI 复用共享 daemon 后写错 pane。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  export TMUX_PANE
  TMUX_PANE=$(wt display -p -t w1 '#{pane_id}')
  export WHISTLE_TMUX_SOCKET

  WRAPPER="$WHISTLE_ROOT/bin/tmux-whistle-codex"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  CODEX_HOME_TEST="$BATS_TEST_TMPDIR/codex-home"
  CODEX_LOG="$BATS_TEST_TMPDIR/codex.log"
  mkdir -p "$FAKE_BIN" "$CODEX_HOME_TEST"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"tmux-whistle"}]}]}}\n' \
    > "$CODEX_HOME_TEST/hooks.json"

  cat > "$FAKE_BIN/codex" << 'EOF'
#!/bin/sh
{
  for _arg do printf 'ARG=%s\n' "$_arg"; done
  printf 'BINDING=%s\n' "${WHISTLE_CODEX_BINDING:-}"
  printf 'CLIENT=%s\n' "${WHISTLE_CODEX_CLIENT:-}"
  printf 'PANE=%s\n' "${WHISTLE_CODEX_PANE:-}"
  printf 'SOCKET=%s\n' "${WHISTLE_TMUX_SOCKET:-}"
  if [ -n "${WHISTLE_TMUX_SOCKET:-}" ]; then
    printf 'WHISTLE=%s\n' "$(
      tmux -S "$WHISTLE_TMUX_SOCKET" show -pqv -t "$WHISTLE_CODEX_PANE" @whistle
    )"
  fi
} > "$FAKE_CODEX_LOG"
exit "${FAKE_CODEX_RC:-0}"
EOF
  chmod +x "$FAKE_BIN/codex"
}

teardown() {
  wt_stop
}

run_wrapper() {
  run env \
    TMUX_PANE="$TMUX_PANE" \
    WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    CODEX_HOME="$CODEX_HOME_TEST" \
    FAKE_CODEX_LOG="$CODEX_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$WRAPPER" "$@"
}

@test "codex-launcher: tmux 内注入 PaneBinding 并强制 --no-daemon" {
  run_wrapper first --flag

  assert_eq "$status" 0
  assert_eq "$output" ''
  assert_eq "$(sed -n '1p' "$CODEX_LOG")" 'ARG=--no-daemon'
  assert_eq "$(sed -n '2p' "$CODEX_LOG")" 'ARG=first'
  assert_eq "$(sed -n '3p' "$CODEX_LOG")" 'ARG=--flag'
  assert_contains "$(cat "$CODEX_LOG")" 'BINDING=v1'
  assert_contains "$(cat "$CODEX_LOG")" "PANE=$TMUX_PANE"
  assert_contains "$(cat "$CODEX_LOG")" "SOCKET=$WHISTLE_TMUX_SOCKET"
  assert_contains "$(cat "$CODEX_LOG")" "CLIENT=$TMUX_PANE:"
  assert_contains "$(optp @whistle_codex_binding "$TMUX_PANE")" "$TMUX_PANE:"
}

@test "codex-launcher: 启动时立即写 idle，不等 SessionStart" {
  run_wrapper

  assert_eq "$status" 0
  assert_contains "$(cat "$CODEX_LOG")" 'WHISTLE=idle'
  assert_eq "$(opt '@whistle_count_idle')" '1'
}

@test "codex-launcher: tmux-whistle codex 子命令复用同一启动器" {
  run env \
    TMUX_PANE="$TMUX_PANE" \
    WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    CODEX_HOME="$CODEX_HOME_TEST" \
    FAKE_CODEX_LOG="$CODEX_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$WHISTLE_ROOT/bin/tmux-whistle" codex first

  assert_eq "$status" 0
  assert_eq "$(sed -n '1p' "$CODEX_LOG")" 'ARG=--no-daemon'
  assert_eq "$(sed -n '2p' "$CODEX_LOG")" 'ARG=first'
  assert_contains "$(cat "$CODEX_LOG")" 'BINDING=v1'
}

@test "codex-launcher: 已带 --no-daemon 时不重复添加" {
  run_wrapper --no-daemon --version

  assert_eq "$status" 0
  assert_eq "$(grep -c '^ARG=--no-daemon$' "$CODEX_LOG")" '1'
  assert_eq "$(sed -n '2p' "$CODEX_LOG")" 'ARG=--version'
}

@test "codex-launcher: 当前 CODEX_HOME 缺 Hook 时拒绝启动并点名路径" {
  printf '{"hooks":{}}\n' > "$CODEX_HOME_TEST/hooks.json"

  run_wrapper

  assert_eq "$status" 1
  assert_contains "$output" "$CODEX_HOME_TEST/hooks.json"
  assert_contains "$output" 'install-codex-hooks'
  [ ! -e "$CODEX_LOG" ]
}

@test "codex-launcher: 显式允许无 Hook 时仍可启动" {
  printf '{"hooks":{}}\n' > "$CODEX_HOME_TEST/hooks.json"

  run env \
    TMUX_PANE="$TMUX_PANE" \
    WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    CODEX_HOME="$CODEX_HOME_TEST" \
    WHISTLE_CODEX_ALLOW_NO_HOOKS=1 \
    FAKE_CODEX_LOG="$CODEX_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$WRAPPER" --version

  assert_eq "$status" 0
  assert_eq "$(sed -n '1p' "$CODEX_LOG")" 'ARG=--no-daemon'
}

@test "codex-launcher: tmux 外不注入绑定也不改参数" {
  run env \
    -u TMUX_PANE \
    -u WHISTLE_TMUX_SOCKET \
    CODEX_HOME="$CODEX_HOME_TEST" \
    FAKE_CODEX_LOG="$CODEX_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$WRAPPER" --version

  assert_eq "$status" 0
  assert_eq "$(cat "$CODEX_LOG")" \
    "ARG=--version
BINDING=
CLIENT=
PANE=
SOCKET="
}

@test "codex-launcher: 失效 pane 不启动 Codex" {
  run env \
    TMUX_PANE='%999999' \
    WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    CODEX_HOME="$CODEX_HOME_TEST" \
    FAKE_CODEX_LOG="$CODEX_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$WRAPPER"

  assert_eq "$status" 1
  assert_contains "$output" '找不到目标 pane'
  [ ! -e "$CODEX_LOG" ]
}

@test "codex-launcher: Codex 退出码原样透传" {
  run env \
    TMUX_PANE="$TMUX_PANE" \
    WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    CODEX_HOME="$CODEX_HOME_TEST" \
    FAKE_CODEX_LOG="$CODEX_LOG" \
    FAKE_CODEX_RC=37 \
    PATH="$FAKE_BIN:$PATH" \
    "$WRAPPER"

  assert_eq "$status" 37
}
