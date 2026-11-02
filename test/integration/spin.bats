#!/usr/bin/env bats
# shellcheck shell=bash
#
# L2：running 动画帧的启停。
#
# 隔离性：默认情况下 @whistle_root 是空的，whistle_spin_script 因此返回失败，
# whistle_spin_ensure 直接 return —— **测试不会意外拉起后台推进器**。
# 只有需要真进程的用例才显式给出 WHISTLE_SPIN_SCRIPT。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  unset TMUX_PANE TMUX TMUX_SOCKET
}

teardown() {
  # 兜底：万一推进器还活着，别泄漏到后续测试 / 开发机上
  whistle_spin_stop 2> /dev/null || true
  wt_stop
}

spin_wait_char_moved() {
  _w=0
  while [ "$_w" -lt 25 ]; do
    [ "$(wt show -gqv @whistle_spin_char)" != "⠋" ] && return 0
    _w=$((_w + 1))
    sleep 0.2
  done
  return 1
}

spin_wait_no_pid() {
  _w=0
  while [ "$_w" -lt 25 ]; do
    [ -z "$(wt show -gqv @whistle_spin_pid)" ] && return 0
    _w=$((_w + 1))
    sleep 0.2
  done
  return 1
}

# 等 server option 里出现推进器 PID（推进器是异步拉起的，setup.sh 返回时它可能还没写出来）
spin_wait_pid() {
  _w=0
  while [ "$_w" -lt 25 ]; do
    [ -n "$(wt show -gqv @whistle_spin_pid)" ] && return 0
    _w=$((_w + 1))
    sleep 0.2
  done
  return 1
}

@test "spin: 当前帧字符读 option" {
  wt set -g @whistle_spin_char '⠼'
  assert_eq "$(whistle_spin_char)" '⠼'
}

@test "spin: option 未设置时回落第一帧" {
  assert_eq "$(whistle_spin_char)" '⠋'
}

@test "spin: 开关与帧值是两个不同的 option（撞名过一次）" {
  # 回归：曾经两者都叫 @whistle_spin，spin_sync 在「没有 running」时把帧值
  # 写进开关，于是开关永远读到非 on 的值，动画被永久判成「关」——
  # 界面上只表现为退回静态图标，看不出任何异常。
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 0
  wt set -g @whistle_spin_char '⠹'

  whistle_spin_sync

  # 开关仍是 on，帧值被复位 —— 两者互不干扰
  assert_eq "$(wt show -gqv @whistle_spin)" 'on'
  assert_eq "$(wt show -gqv @whistle_spin_char)" '⠋'
}

@test "spin: @whistle_spin off 时帧值复位且不启推进器" {
  wt set -g @whistle_count_running 2
  wt set -g @whistle_spin_char '⠹'
  wt set -g @whistle_spin off

  whistle_spin_sync

  assert_eq "$(wt show -gqv @whistle_spin_char)" '⠋'
  [ -z "$(wt show -gqv @whistle_spin_pid)" ] || {
    echo "off 时不该留下推进器 PID"
    return 1
  }
}

@test "spin: 没有 running 时不启推进器，帧值复位" {
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 0
  wt set -g @whistle_spin_char '⠹'

  whistle_spin_sync

  assert_eq "$(wt show -gqv @whistle_spin_char)" '⠋'
  [ -z "$(wt show -gqv @whistle_spin_pid)" ] || {
    echo "不该留下推进器 PID"
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
  [ -z "$(wt show -gqv @whistle_spin_pid)" ] || return 1
}

@test "spin: 真有 running 时推进器会换帧，running 归零后自行退出" {
  # shellcheck disable=SC2030,SC2031  # 导出只对本 @test 内启动的子进程有效，这正是本意
  export WHISTLE_SPIN_SCRIPT="$WHISTLE_ROOT/lib/spin.sh"
  wt set -g @whistle_spin_interval 0.1
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 1
  wt set -g @whistle_spin_char '⠋'

  whistle_spin_sync

  spin_wait_char_moved || {
    echo "推进器没动：帧字符一直是 ⠋"
    return 1
  }

  # running 归零 → 下一轮循环 break → 自己退出并清掉 PID 记录
  wt set -g @whistle_count_running 0
  spin_wait_no_pid || {
    echo "running 归零后推进器没有退出"
    return 1
  }
}

@test "spin: --recompute 把计数改回来时也会重启推进器" {
  # 回归：--recompute 由 pane-exited / window-pane-changed 钩子调用，它只重算
  # 计数、不走 deliver。同步逻辑挂在 deliver 上时，「running 归零被停掉的
  # 推进器」在计数回升后没人拉起 —— 状态栏与菜单的帧一起冻住，界面上
  # 只是「不转了」，看不出任何异常。
  # shellcheck disable=SC2030,SC2031
  export WHISTLE_SPIN_SCRIPT="$WHISTLE_ROOT/lib/spin.sh"
  wt set -g @whistle_spin on
  wt set -g @whistle_spin_interval 0.1
  # 直接写 pane option，让 recompute 能算出 running >= 1
  wt set -p -t "$(wt display -p -t w1 '#{pane_id}')" @whistle running

  run "$WHISTLE_ROOT/bin/tmux-whistle" --recompute
  assert_eq "$status" 0

  spin_wait_pid || {
    echo "--recompute 没有拉起推进器"
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

  spin_wait_pid || {
    echo "setup.sh 没有拉起推进器"
    return 1
  }
}

@test "spin: 另一个 server 的 whistle_spin_stop 不会误杀本 server 的推进器" {
  # 回归（2026-11-02 实测）：推进器的 PID 原先记在**按用户命名、不含 socket**
  # 的 pidfile 里 —— 用户的真 server 与测试的隔离 server 共用一份。隔离 server
  # 一 stop 就把用户真 server 的推进器 kill 掉，用户那边下一次重算又拉起来，
  # 状态栏汇总格于是反复重画、CPU 跟着抖。PID 记进 server 自己的 option 后，
  # 两个 server 天然隔离。
  # shellcheck disable=SC2030,SC2031
  export WHISTLE_SPIN_SCRIPT="$WHISTLE_ROOT/lib/spin.sh"
  wt set -g @whistle_spin_interval 0.1
  wt set -g @whistle_spin on
  wt set -g @whistle_count_running 1

  whistle_spin_sync

  spin_wait_pid || {
    echo "推进器没起来"
    return 1
  }
  local pid
  pid="$(wt show -gqv @whistle_spin_pid)"
  [ -n "$pid" ] || {
    echo "server option 里没有推进器 PID"
    return 1
  }

  # 起第二个 server 扮演「别人的隔离 server」，让它 stop 自己的推进器。
  local sock2="whistle-test-2-$$"
  local path2
  tmux -L "$sock2" -f /dev/null new-session -d -s other 2> /dev/null
  path2="$(tmux -L "$sock2" display -p '#{socket_path}' 2> /dev/null)"
  if [ -z "$path2" ]; then
    echo "第二个 server 没起来，这条用例就验不到隔离性"
    tmux -L "$sock2" kill-server 2> /dev/null || true
    return 1
  fi
  WHISTLE_TMUX_SOCKET="$path2" whistle_spin_stop
  tmux -L "$sock2" kill-server 2> /dev/null || true

  # 本 server 的推进器必须毫发无损。
  kill -0 "$pid" 2> /dev/null || {
    echo "推进器被另一个 server 误杀了"
    return 1
  }
  assert_eq "$(wt show -gqv @whistle_spin_pid)" "$pid"
}