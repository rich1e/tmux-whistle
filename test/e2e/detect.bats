#!/usr/bin/env bats
# shellcheck shell=bash
#
# L3 端到端：读屏降级通道的整条链路 ——
#   capture-pane → lib/detect-rules.sh 分类 → @whistle_live
#   → 推导层合成有效态 → 窗口徽章
#
# 集成层（test/integration/detect.bats）已经逐条钉住分类与槽位写入；
# 这里只回答一个问题：**状态栏上真的画出来了吗**。
#
# 伪造前台 agent：软链 /bin/cat 成 codex + 一个 FIFO（理由见集成层的注释）。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX

  wt set -g @whistle_detect on
  wt set -g @whistle_detect_interval 1
  wt set -g @whistle_detect_done off

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  ln -sf /bin/cat "$FAKE_BIN/codex"
  FAKE_FIFO="$BATS_TEST_TMPDIR/feed"
  mkfifo "$FAKE_FIFO"
  export FAKE_BIN FAKE_FIFO

  # 徽章链路：先摆出 oh-my-tmux 的 format 形状，patch 才知道往哪儿插
  wt_fake_omt_format
  wt_publish_and_patch

  DETECT_PID=''
  sh "$WHISTLE_ROOT/lib/detect.sh" loop > "$BATS_TEST_TMPDIR/detect.log" 2>&1 &
  DETECT_PID=$!
}

teardown() {
  if [ -n "${DETECT_PID:-}" ]; then
    kill "$DETECT_PID" 2> /dev/null || true
    wait "$DETECT_PID" 2> /dev/null || true
  fi
  wt_stop
}

pane_ready() { [ -n "$(wt capture-pane -p -t w1 | tr -d '[:space:]')" ]; }
fg_is_agent() { [ "$(wt display -p -t w1 '#{pane_current_command}')" = cat ]; }
fg_not_zsh() { [ "$(wt display -p -t w1 '#{pane_current_command}')" != zsh ]; }
win_state() { wt show -wv -t w1 @whistle_win 2> /dev/null; }
win_state_eq() { [ "$(win_state)" = "$1" ]; }

start_agent() {
  wt_wait_until 5000 pane_ready
  wt send-keys -t w1 'exec /bin/sh' Enter
  wt_wait_until 5000 fg_not_zsh
  wt send-keys -t w1 "$FAKE_BIN/codex $FAKE_FIFO" Enter
  wt_wait_until 5000 fg_is_agent
  exec 9> "$FAKE_FIFO"
}

feed() { printf '%b' "$1" >&9; }

@test "e2e: 空闲时窗口徽章显示 ◉" {
  start_agent
  feed '› \n'
  wt_wait_until 15000 'win_state_eq idle'
  assert_eq "$(win_state)" 'idle'
  assert_contains "$(wt_render_windows)" 'w1◉'
}

@test "e2e: 在跑时窗口徽章显示 ▶" {
  start_agent
  feed '• Working (3s • esc to interrupt)\n'
  wt_wait_until 15000 'win_state_eq running'
  assert_eq "$(win_state)" 'running'
  assert_contains "$(wt_render_windows)" 'w1▶'
  # 活动通道的真源必须仍为空 —— 屏幕结论不写进 @whistle
  assert_eq "$(wt show -pqv -t "$(wt display -p -t w1 '#{pane_id}')" @whistle 2> /dev/null)" ''
}

@test "e2e: 等权限时窗口徽章显示 ◔" {
  start_agent
  feed 'Press enter to confirm or esc to cancel\n'
  wt_wait_until 15000 'win_state_eq wait'
  assert_eq "$(win_state)" 'wait'
  assert_contains "$(wt_render_windows)" 'w1◔'
}
