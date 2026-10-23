#!/usr/bin/env bats
# shellcheck shell=bash
#
# L2：run -- 命令包装器。
#
# 包装器只认退出码，不解析输出；退出码本身必须透传给调用方，
# 否则 `make && tmux-whistle run -- …` 在失败时会返回 0。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  unset TMUX_PANE TMUX TMUX_SOCKET
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
  PANE="$(wt display -p -t main:w1 '#{pane_id}')"
}

teardown() {
  wt_stop
}

# helper 里只有 assert_eq / assert_contains / assert_not_contains，没有 assert_ne。
# 这里补一个专用的，省得每处写 `|| return 1` 的样板。
assert_nonzero() {
  [ "$1" -ne 0 ] || {
    echo "期望非零退出码，实际是 $1"
    return 1
  }
}

@test "run: 退出码 0 → done" {
  run "$CLI" run -- sh -c 'exit 0'
  assert_eq "$status" 0
  assert_eq "$(optp @whistle "$PANE")" 'done'
}

@test "run: 退出码非 0 → error，消息里带退出码" {
  run "$CLI" run -- sh -c 'exit 7'
  assert_eq "$status" 7
  assert_eq "$(optp @whistle "$PANE")" 'error'
  assert_contains "$(optp @whistle_msg "$PANE")" '7'
}

@test "run: 命令结束后 running 被换成终态" {
  run "$CLI" run -- sh -c 'exit 0'
  assert_eq "$(optp @whistle "$PANE")" 'done'
}

@test "run: 自定义标签出现在消息里" {
  run "$CLI" run 'pnpm test' -- sh -c 'exit 0'
  assert_eq "$status" 0
  assert_contains "$(optp @whistle_msg "$PANE")" 'pnpm test'
}

@test "run: 没有标签时消息里出现命令名" {
  run "$CLI" run -- pnpm test
  assert_contains "$(optp @whistle_msg "$PANE")" 'pnpm'
}

@test "run: 消息带耗时" {
  "$CLI" run -- sh -c 'exit 0'

  # 断言「末尾有个 Ns」这个形态，不是具体秒数（可能是 0s 也可能 1s）。
  # 用 grep -E 而不是 assert_contains 's' —— 默认标签是 sh，自带一个 s，
  # 那样写的话把整段耗时删掉也照样绿。
  local m
  m=$(optp @whistle_msg "$PANE")
  printf '%s' "$m" | grep -qE '（[0-9]+s）$' || {
    echo "消息里没有耗时: [$m]"
    return 1
  }
}

@test "run: 收到 SIGINT 时包装器不被打死，落终态而不是停在 running" {
  # Ctrl-C 把 SIGINT 发给**整个前台进程组**。没有 handler 的话，/bin/sh 跑的
  # 包装器会在读到 $? 之前就被打死 —— 状态永远停在 running。
  # 而 running 不计入 pending、🔔 不亮，非 Claude Code 的进程更没有
  # SessionEnd 兜底，那盏 ● 就再也灭不掉了。
  #
  # 必须 set -m 才能复现：非交互 shell 里 `cmd &` 的后台作业默认**忽略** SIGINT，
  # 不开 job control 的话信号根本打不到包装器，测试会假绿。
  #
  # trap 必须是 ':'（no-op）而不是 ''（ignore）：被 trap 的信号在子进程里
  # 复位成默认动作，子命令照样能被 Ctrl-C 打断；被 ignore 的会连子进程一起忽略。
  set -m
  "$CLI" run -- sleep 2 &
  local pid=$!
  set +m
  sleep 0.4
  kill -INT -- "-$pid" 2> /dev/null || kill -INT "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true

  # 断言「不在 running」而不是具体终态：包装器活下来时，sleep 可能被一起
  # 打断（130 → error）也可能没被打断（0 → done），两者都是正确结果。
  local state
  state=$(optp @whistle "$PANE")
  [ "$state" != 'running' ] || {
    echo "包装器被打死了，状态停在 running"
    return 1
  }
}

@test "run: 命令的输出透传到终端，不被吞掉" {
  run "$CLI" run -- sh -c 'echo hello-from-run'
  assert_eq "$status" 0
  assert_contains "$output" 'hello-from-run'
}

@test "run: 命令参数原样传递，不做 word splitting" {
  # shellcheck disable=SC2016
  # 上面的 $1 是**故意**用单引号的：它要由内层 sh 展开，不是由 bats 展开。
  # 换成双引号的话测的就是「bats 有没有替我们展开」，而不是「包装器有没有
  # 原样传参」—— 那正是这条用例要守的东西。
  run "$CLI" run -- sh -c 'printf "[%s]" "$1"' _ 'a b c'
  assert_contains "$output" '[a b c]'
}

@test "run: 缺 -- 时报错且不执行任何东西" {
  run "$CLI" run
  assert_nonzero "$status"
  assert_eq "$(optp @whistle "$PANE")" ''
}

@test "run: -- 后面没有命令时报错且不写状态" {
  run "$CLI" run --
  assert_nonzero "$status"
  assert_eq "$(optp @whistle "$PANE")" ''
}

@test "run: -t 指定别的 pane 时状态落在那上面" {
  wt new-window -d -n other
  local p
  p=$(wt display -p -t main:other '#{pane_id}')

  run "$CLI" run -t "$p" -- sh -c 'exit 0'
  assert_eq "$status" 0
  assert_eq "$(optp @whistle "$p")" 'done'
  assert_eq "$(optp @whistle "$PANE")" ''
}

@test "run: 成功时也要算待处理（跟普通 done 一样）" {
  run "$CLI" run -- sh -c 'exit 0'
  assert_contains "$(opt @whistle_pending)" '1'
}

@test "run: 窗口徽章同步更新" {
  run "$CLI" run -- sh -c 'exit 0'
  local w
  w=$(wt display -p -t main:w1 '#{window_id}')
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'
}