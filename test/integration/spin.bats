#!/usr/bin/env bats
# shellcheck shell=bash
#
# L2：running 动画帧的启停。
#
# 隔离性：默认情况下 @whistle_root 是空的，whistle_spin_script 因此返回失败，
# whistle_spin_ensure 直接 return —— **测试不会意外拉起后台推进器**。
# 只有最后那条用例显式给出 WHISTLE_SPIN_SCRIPT 才会真的起进程。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  unset TMUX_PANE TMUX TMUX_SOCKET
}

teardown() {
  # 兜底：万一推进器还活着，别泄漏到后续测试或开发机上
  whistle_spin_stop 2> /dev/null || true
  wt_stop
}

# 轮询直到帧号不再是 0（推进器动过了）。
#
# 不用「传一段条件字符串再 eval」的写法：那会触发 SC2016，而且 eval 不该
# 出现在测试里。两种等待条件各自写一个函数，读起来也更直白。
spin_wait_frame_moved() {
  _w=0
  while [ "$_w" -lt 25 ]; do
    [ "$(wt show -gqv @whistle_spin_frame)" != "0" ] && return 0
    _w=$((_w + 1))
    sleep 0.2
  done
  return 1
}

spin_wait_no_pidfile() {
  _w=0
  while [ "$_w" -lt 25 ]; do
    [ ! -f "$(whistle_spin_pidfile)" ] && return 0
    _w=$((_w + 1))
    sleep 0.2
  done
  return 1
}

# 等 pidfile 出现（推进器被拉起是异步的，setup.sh 返回时它可能还没写出来）
spin_wait_pidfile() {
  _w=0
  while [ "$_w" -lt 25 ]; do
    [ -f "$(whistle_spin_pidfile)" ] && return 0
    _w=$((_w + 1))
    sleep 0.2
  done
  return 1
}

@test "spin: 帧号轮转 0→1→2→3→0" {
  wt set -g @whistle_spin_frame 0
  assert_eq "$(whistle_spin_next)" '1'
  wt set -g @whistle_spin_frame 3
  assert_eq "$(whistle_spin_next)" '0'
}

@test "spin: 帧号非法或未设置时当作 0" {
  # 帧号是 user option，可能被手改成任何东西，不能因此崩。
  wt set -g @whistle_spin_frame banana
  assert_eq "$(whistle_spin_index)" '0'
  wt set -g @whistle_spin_frame ''
  assert_eq "$(whistle_spin_index)" '0'
}

@test "spin: 开关与帧号是两个不同的 option（撞名过一次）" {
  # 回归：曾经两者都叫 @whistle_spin，spin_sync 在「没有 running」时把帧号
  # 写进开关（set -g @whistle_spin 0），于是开关永远读到 0 ≠ on，
  # 动画被永久判成「关」—— 界面上只表现为退回静态图标，看不出异常。
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 0
  wt set -g @whistle_spin_frame 2

  whistle_spin_sync

  # 开关仍是 on，帧号被复位 —— 两者互不干扰
  assert_eq "$(wt show -gqv @whistle_spin)" 'on'
  assert_eq "$(wt show -gqv @whistle_spin_frame)" '0'
}

@test "spin: @whistle_spin off 时帧号复位且不启推进器" {
  wt set -g @whistle_count_running 2
  wt set -g @whistle_spin_frame 3
  wt set -g @whistle_spin off

  whistle_spin_sync

  assert_eq "$(wt show -gqv @whistle_spin_frame)" '0'
  [ ! -f "$(whistle_spin_pidfile)" ] || {
    echo "off 时不该留下 pidfile"
    return 1
  }
}

@test "spin: 没有 running 时不启推进器，帧号复位" {
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 0
  wt set -g @whistle_spin_frame 2

  whistle_spin_sync

  assert_eq "$(wt show -gqv @whistle_spin_frame)" '0'
  [ ! -f "$(whistle_spin_pidfile)" ] || {
    echo "不该留下 pidfile"
    return 1
  }
}

@test "spin: 缺 @whistle_root 时不启推进器（测试环境必须保持这样）" {
  # 这是上面几条能安全隔离的原因：找不到脚本就直接返回，绝不 run-shell。
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 1

  whistle_spin_script && {
    echo "测试环境里不该解析出脚本路径"
    return 1
  }
  whistle_spin_sync
  [ ! -f "$(whistle_spin_pidfile)" ] || return 1
}

@test "spin: 真有 running 时推进器会推进帧号，running 归零后自行退出" {
  # shellcheck disable=SC2030,SC2031  # 导出只对本 @test 内启动的子进程有效，这正是本意
  export WHISTLE_SPIN_SCRIPT="$WHISTLE_ROOT/lib/spin.sh"
  wt set -g @whistle_spin_interval 0.1
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 1
  wt set -g @whistle_spin_frame 0

  whistle_spin_sync

  spin_wait_frame_moved || {
    echo "推进器没动：帧号一直是 0"
    return 1
  }

  # running 归零 → 下一轮循环 break → 自己退出并清 pidfile
  wt set -g @whistle_count_running 0
  spin_wait_no_pidfile || {
    echo "running 归零后推进器没有退出"
    return 1
  }
}

@test "spin: setup.sh 在有 running 时拉起推进器，不依赖状态变化" {
  # 回归：推进器原先只在 whistle_deliver 里启停，而 deliver 只在**状态变化**
  # 时才跑。一个「早就报了 running、之后没人动过」的 pane 不会再有 deliver ——
  # 结果 prefix + r 之后动画永远转不起来，界面上却看不出任何异常。
  # shellcheck disable=SC2030,SC2031
  export WHISTLE_SPIN_SCRIPT="$WHISTLE_ROOT/lib/spin.sh"
  wt set -g @whistle_spin on
  wt set -g @whistle_spin_interval 0.1
  # 直接写 pane option，**绕开 CLI** —— 不会有 deliver，正好模拟那个场景
  wt set -p -t "$(wt display -p -t w1 '#{pane_id}')" @whistle running

  run "$WHISTLE_ROOT/scripts/setup.sh" "$(wt display -p '#{socket_path}')"
  assert_eq "$status" 0

  spin_wait_pidfile || {
    echo "setup.sh 没有拉起推进器"
    return 1
  }
}