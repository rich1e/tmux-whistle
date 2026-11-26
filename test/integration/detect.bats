#!/usr/bin/env bats
# shellcheck shell=bash
#
# 读屏轮询（lib/detect.sh）：谁可以被接管、写到哪个槽位、什么时候算数。
#
# 三条不变量：
#   1. hook / migration 接管过的 pane 一个字都不碰（屏幕永远只是补充）
#   2. 只处理 whistle_detect_eligible 放行的 pane（认识的 agent + 交互式）
#   3. running / idle 只写 @whistle_live，绝不写 @whistle
#
# 伪造前台 agent 的办法：把 /bin/cat **软链**成 codex，再让它读一个 FIFO。
#   - 复制系统二进制不行 —— macOS 会把拷出来的当签名失效直接 SIGKILL；
#     硬链也不行（SIP 拒绝）。软链下 comm 是 cat，argv[0] 却是 codex，
#     正好守住「按 argv0 认 agent」那条规则。
#   - 用 cat + FIFO 而不是 sleep：前台被 agent 占住时 `send-keys` 打不进去，
#     想换屏幕内容只能从外面写到 FIFO 里，让 agent 自己「打印」出来。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX

  wt set -g @whistle_detect on
  # 轮询节奏压到 1 秒：用例断言的是「几次扫描之后」，不是墙钟时间。
  wt set -g @whistle_detect_interval 1

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  ln -sf /bin/cat "$FAKE_BIN/codex"
  FAKE_FIFO="$BATS_TEST_TMPDIR/feed"
  mkfifo "$FAKE_FIFO"
  export FAKE_BIN FAKE_FIFO

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
fg_is_agent() { [ "$(wt display -p -t w1 '#{pane_current_command}')" = cat ]; }
fg_not_zsh() { [ "$(wt display -p -t w1 '#{pane_current_command}')" != zsh ]; }
live_val() { wt show -pqv -t "$(pane_of)" @whistle_live 2> /dev/null; }
notice_val() { wt show -pqv -t "$(pane_of)" @whistle_notice 2> /dev/null; }
activity_val() { wt show -pqv -t "$(pane_of)" @whistle 2> /dev/null; }
live_eq() { [ "$(live_val)" = "$1" ]; }
notice_empty() { [ -z "$(notice_val)" ]; }
win_eq() { [ "$(wt show -wv -t w1 @whistle_win 2> /dev/null)" = "$1" ]; }
win_empty() { [ -z "$(wt show -wv -t w1 @whistle_win 2> /dev/null)" ]; }
tn_fired() { [ -s "$WHISTLE_TEST_TN_LOG" ]; }
live_empty() { [ -z "$(live_val)" ]; }
notice_eq() { [ "$(notice_val)" = "$1" ]; }

# 起 agent：先用 sh 换掉 zsh 提示符（zsh 的 `❯` 会抢走「最后一条提示行」），
# 再把 codex（= cat <fifo>）放到前台，最后打开写端。
start_agent() {
  wt_wait_until 5000 pane_ready
  wt send-keys -t w1 'exec /bin/sh' Enter
  wt_wait_until 5000 fg_not_zsh
  wt send-keys -t w1 "$FAKE_BIN/codex $FAKE_FIFO" Enter
  wt_wait_until 5000 fg_is_agent
  exec 9> "$FAKE_FIFO"
}

# 往 agent 的「终端」里写内容（%b 让 \n / \033 生效）
feed() { printf '%b' "$1" >&9; }

# 清屏后重画 —— 模拟 TUI 重绘
redraw() { printf '\033[H\033[2J' >&9; }

# -- 用例 -------------------------------------------------------------------

@test "detect: 无 hook 的 agent pane 写入 live" {
  start_agent
  feed '› \n'
  wt_wait_until 8000 'live_eq idle'
  assert_eq "$(live_val)" 'idle'
  # 活动通道的真源不许被屏幕结论污染
  assert_eq "$(activity_val)" ''
}

@test "detect: hook 接管的 pane 不写 live" {
  wt set -p -t "$(pane_of)" @whistle_src hook
  start_agent
  feed '› \n'
  sleep 3
  assert_eq "$(live_val)" ''
}

@test "detect: 非 agent pane 不写 live（普通输出含 esc to cancel 也不触发）" {
  wt set -g @whistle_agent_cmds claude
  start_agent
  feed 'esc to cancel\nenter to confirm\n'
  sleep 3
  assert_eq "$(live_val)" ''
  assert_eq "$(notice_val)" ''
}

@test "detect: agent 权限对话框写入 wait 通知" {
  start_agent
  feed 'Press enter to confirm or esc to cancel\n'
  wt_wait_until 8000 'notice_eq wait'
  assert_eq "$(notice_val)" 'wait'
}

@test "detect: agent 退出后 live 被清空" {
  start_agent
  feed '› \n'
  wt_wait_until 8000 'live_eq idle'

  wt send-keys -t w1 C-c
  wt_wait_until 8000 live_empty
  assert_eq "$(live_val)" ''
}

@test "detect: running 立即生效，回落到 idle 要连续两次确认" {
  start_agent
  feed '• Working (3s • esc to interrupt)\n'
  # running 不等防抖：晚一拍才亮 ▶ 会让人以为没反应
  wt_wait_until 5000 'live_eq running'

  redraw
  feed '› \n'
  # 一次扫描之内不该回落：那只是 TUI 重绘的瞬间
  sleep 0.6
  assert_eq "$(live_val)" 'running'

  wt_wait_until 8000 'live_eq idle'
  assert_eq "$(live_val)" 'idle'
}

# -- running→idle 补 done ----------------------------------------------------

@test "detect: running→idle 补一条 done 通知" {
  wt set -g @whistle_detect_done_min 0
  start_agent
  feed '• Working (3s • esc to interrupt)\n'
  wt_wait_until 5000 'live_eq running'
  redraw
  feed '› \n'
  wt_wait_until 15000 'notice_eq done'
  assert_eq "$(notice_val)" 'done'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice_msg)" '检测到回合结束'
  # 活动通道的真源不受影响
  assert_eq "$(activity_val)" ''
}

@test "detect: running 时长不足不补 done" {
  wt set -g @whistle_detect_done_min 30
  start_agent
  feed '• Working (3s • esc to interrupt)\n'
  wt_wait_until 5000 'live_eq running'
  redraw
  feed '› \n'
  wt_wait_until 15000 'live_eq idle'
  sleep 1
  assert_eq "$(notice_val)" ''
}

@test "detect: 已有未读通知不被 done 覆盖" {
  wt set -g @whistle_detect_done_min 0
  wt set -p -t "$(pane_of)" @whistle_notice wait
  start_agent
  feed '• Working (3s • esc to interrupt)\n'
  wt_wait_until 5000 'live_eq running'
  redraw
  feed '› \n'
  wt_wait_until 15000 'live_eq idle'
  sleep 1
  assert_eq "$(notice_val)" 'wait'
}

@test "detect: 开关关闭时不补 done" {
  wt set -g @whistle_detect_done off
  wt set -g @whistle_detect_done_min 0
  start_agent
  feed '• Working (3s • esc to interrupt)\n'
  wt_wait_until 5000 'live_eq running'
  redraw
  feed '› \n'
  wt_wait_until 15000 'live_eq idle'
  sleep 1
  assert_eq "$(notice_val)" ''
}

@test "detect: 关掉开关后清空所有 live" {
  start_agent
  feed '› \n'
  wt_wait_until 8000 'live_eq idle'

  wt set -g @whistle_detect off
  wt_wait_until 15000 live_empty
  assert_eq "$(live_val)" ''
}

# -- 评审补充（通知生命周期 / 投递 / 快节奏边界） ---------------------------

@test "detect: 读屏写的 wait 在批准后自动清掉" {
  start_agent
  feed 'Press enter to confirm or esc to cancel\n'
  wt_wait_until 8000 'notice_eq wait'

  # 用户按了 y：屏幕回到「在跑」。焦点没动过，没有任何 after-select-*
  # 会触发已读路径 —— 只能由读屏自己收掉它写的那条通知。
  redraw
  feed '• Working (3s • esc to interrupt)\n'
  wt_wait_until 12000 notice_empty
  assert_eq "$(notice_val)" ''
  assert_eq "$(live_val)" 'running'
}

@test "detect: 未读 done 不挡住新的权限请求（wait 是升级不是覆盖）" {
  wt set -g @whistle_detect_done off
  wt set -p -t "$(pane_of)" @whistle_notice 'done' 
  start_agent
  feed 'Press enter to confirm or esc to cancel\n'
  wt_wait_until 10000 'notice_eq wait'
  assert_eq "$(notice_val)" 'wait'
}

@test "detect: opencode 没有规则表，不写 live" {
  wt set -g @whistle_agent_cmds 'opencode'
  ln -sf /bin/cat "$FAKE_BIN/opencode"
  wt_wait_until 5000 pane_ready
  wt send-keys -t w1 'exec /bin/sh' Enter
  wt_wait_until 5000 fg_not_zsh
  wt send-keys -t w1 "$FAKE_BIN/opencode $FAKE_FIFO" Enter
  exec 9> "$FAKE_FIFO"
  feed '› \n'
  sleep 3
  assert_eq "$(live_val)" ''
}

@test "detect: 读屏写 wait 时走投递层（桌面通知）" {
  wt set -g @whistle_os on
  start_agent
  feed 'Press enter to confirm or esc to cancel\n'
  wt_wait_until 12000 'notice_eq wait'
  wt_wait_until 8000 'tn_fired'
  assert_eq "$(notice_val)" 'wait'
}

@test "detect: 守护进程日志里没有 command not found" {
  start_agent
  feed '› \n'
  wt_wait_until 8000 'live_eq idle'
  sleep 1
  run grep -c 'command not found' "$BATS_TEST_TMPDIR/detect.log"
  assert_eq "$output" '0'
}

@test "detect: 关掉开关后窗口徽标也清空" {
  start_agent
  feed '› \n'
  wt_wait_until 8000 'live_eq idle'
  wt_wait_until 8000 'win_eq idle'

  wt set -g @whistle_detect off
  wt_wait_until 15000 live_empty
  wt_wait_until 8000 win_empty
  assert_eq "$(wt show -wv -t w1 @whistle_win 2> /dev/null)" ''
}
