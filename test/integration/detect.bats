#!/usr/bin/env bats
# shellcheck shell=bash
#
# 读屏轮询（lib/detect.sh）：谁可以被接管、写到哪个槽位。
#
# 三条不变量：
#   1. hook / migration 接管过的 pane 一个字都不碰（屏幕永远只是补充）
#   2. 只处理 whistle_detect_eligible 放行的 pane（认识的 agent + 交互式）
#   3. running / idle 只写 @whistle_live，绝不写 @whistle
#
# 伪造前台进程的办法：把 /bin/sleep **软链**成 codex 再跑。
# 复制不行 —— macOS 会把拷出来的系统二进制当签名失效直接 SIGKILL；
# 硬链也不行（SIP 拒绝）。软链下 `#{pane_current_command}` 仍然报 sleep，
# 但 argv[0] 是 codex，正好守住「按 argv0 认 agent」那条规则。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX

  wt set -g @whistle_detect on
  wt set -g @whistle_detect_interval 1

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  ln -sf /bin/sleep "$FAKE_BIN/codex"
  export FAKE_BIN

  DETECT_PID=''
  detect_start
}

teardown() {
  detect_stop
  wt_stop
}

pane_of() { wt display -p -t w1 '#{pane_id}'; }

detect_start() {
  sh "$WHISTLE_ROOT/lib/detect.sh" loop > "$BATS_TEST_TMPDIR/detect.log" 2>&1 &
  DETECT_PID=$!
}

detect_stop() {
  [ -n "${DETECT_PID:-}" ] || return 0
  kill "$DETECT_PID" 2> /dev/null || true
  wait "$DETECT_PID" 2> /dev/null || true
  DETECT_PID=''
}

# -- 判据小函数（wt_wait_until 是 eval，嵌套引号在字符串里极易写错） --------

pane_ready() { [ -n "$(wt capture-pane -p -t w1 | tr -d '[:space:]')" ]; }
fg_is_fake() { [ "$(wt display -p -t w1 '#{pane_current_command}')" = sleep ]; }
fg_not_zsh() { [ "$(wt display -p -t w1 '#{pane_current_command}')" != zsh ]; }
live_val() { wt show -pqv -t "$(pane_of)" @whistle_live 2> /dev/null; }
notice_val() { wt show -pqv -t "$(pane_of)" @whistle_notice 2> /dev/null; }
activity_val() { wt show -pqv -t "$(pane_of)" @whistle 2> /dev/null; }
live_eq() { [ "$(live_val)" = "$1" ]; }
live_empty() { [ -z "$(live_val)" ]; }
notice_eq() { [ "$(notice_val)" = "$1" ]; }

# 先等 shell 起来把画面打出来，再让 codex（其实是 sleep）占住前台。
#
# 第一步 `exec /bin/sh` 不可省：开发机的 zsh 提示符本身就是 `❯`，
# 它会成为屏幕上**最后一条提示行**，把 agent 的输入框抢掉 —— 分类器于是
# 看到 `❯ <命令行>` 而不是 `› `，两个状态都对不上。换成正直的 sh 提示符
# 之后，最后一条 `›` 才是我们要的那条。
pane_with_text() {
  wt_wait_until 5000 pane_ready
  wt send-keys -t w1 'exec /bin/sh' Enter
  wt_wait_until 5000 fg_not_zsh
  wt send-keys -t w1 "$1" Enter
  sleep 0.3
  wt send-keys -t w1 "$FAKE_BIN/codex 30" Enter
  wt_wait_until 5000 fg_is_fake
}

# -- 用例 -------------------------------------------------------------------

@test "detect: 无 hook 的 agent pane 写入 live" {
  pane_with_text 'printf "› \n"'
  wt_wait_until 8000 'live_eq idle'
  assert_eq "$(live_val)" 'idle'
  # 活动通道的真源不许被屏幕结论污染
  assert_eq "$(activity_val)" ''
}

@test "detect: hook 接管的 pane 不写 live" {
  wt set -p -t "$(pane_of)" @whistle_src hook
  pane_with_text 'printf "› \n"'
  sleep 3
  assert_eq "$(live_val)" ''
}

@test "detect: 非 agent pane 不写 live（普通输出含 esc to cancel 也不触发）" {
  wt set -g @whistle_agent_cmds claude
  pane_with_text 'printf "esc to cancel\nenter to confirm\n"'
  sleep 3
  assert_eq "$(live_val)" ''
  assert_eq "$(notice_val)" ''
}

@test "detect: agent 权限对话框写入 wait 通知" {
  pane_with_text 'printf "Press enter to confirm or esc to cancel\n"'
  wt_wait_until 8000 'notice_eq wait'
  assert_eq "$(notice_val)" 'wait'
}

@test "detect: agent 退出后 live 被清空" {
  pane_with_text 'printf "› \n"'
  wt_wait_until 8000 'live_eq idle'

  wt send-keys -t w1 C-c
  wt_wait_until 8000 live_empty
  assert_eq "$(live_val)" ''
}
