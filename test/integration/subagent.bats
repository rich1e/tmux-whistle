#!/usr/bin/env bats
# shellcheck shell=bash
#
# L2：子 agent 标记的 TTL 安全阀。
#
# 本文件守的是一条硬底线：**宁可漏报 running，不可永久误报 running。**
#
# @whistle_sub 存的是**过期时间戳**（epoch 秒），不是布尔：
#   - 非空且 now < 值  → 该 pane 强制算 running（子 agent 还在跑）
#   - 0                → 永不过期
#   - 空               → 没有子 agent
# 过期判定在推导层按时间戳做，**不写回** —— 所以它只在「重算」时生效。
# Claude Code 若在某些路径不发 SubagentStop，标记会泄漏；周期重算是安全阀
# （挂在 lib/spin.sh 上，本文件末尾用静态断言守住）。

load '../test_helper/whistle'

setup() {
  # whistle_spin_pidfile 落在 ${XDG_RUNTIME_DIR:-$TMPDIR} 下，**路径里不含 socket** ——
  # 不隔离的话，本文件里的 whistle_recompute_global 会走到 whistle_spin_sync 的
  # 「没有 running」分支、调 whistle_spin_stop，去 kill / 删开发机上真实推进器的
  # pidfile。给每个用例一个自己的 XDG_RUNTIME_DIR，把它挡在隔离区里。
  SUB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/whistle-sub.XXXXXX")
  export XDG_RUNTIME_DIR="$SUB_TMP"

  wt_start
  wt_load core
  # 测试本身可能就跑在真实 tmux pane 里（开发时的常态）。
  # $TMUX_PANE 会让 whistle_resolve_pane 指向真实 server 的 pane，
  # $TMUX / $TMUX_SOCKET 也会把 whistle_tmux 带去别的 server —— 全部清掉，
  # 强制走 WHISTLE_TMUX_SOCKET 指向的隔离 server。
  unset TMUX_PANE TMUX TMUX_SOCKET

  # 让「按进程发现空闲」能命中这个 pane：把它当前的前台命令写成 agent 清单。
  # 于是「没有子 agent 标记」时该 pane 推导成 idle，「标记有效」时强制 running。
  wt set -g @whistle_agent_cmds "$(wt display -p -t w1 '#{pane_current_command}')"
}

teardown() {
  wt_stop
  [ -n "${SUB_TMP:-}" ] && command rm -rf "$SUB_TMP" 2> /dev/null || true
  unset XDG_RUNTIME_DIR
}

pane_of() {
  wt display -p -t w1 '#{pane_id}'
}

win_of() {
  wt display -p -t w1 '#{window_id}'
}

# -- TTL 过期判定 ------------------------------------------------------------

@test "sub: 已过期的 @whistle_sub 不再撑起 running（自愈的核心）" {
  local p w
  p=$(pane_of)
  w=$(win_of)
  # epoch 1 —— 任何真实时钟都已越过它
  wt set -p -t "$p" @whistle_sub 1

  whistle_recompute_global
  whistle_recompute_window "$w"

  # 关键断言：不是 1。过期标记若仍被当有效，这里会是个灭不掉的 ▶。
  assert_eq "$(opt '@whistle_count_running')" '0'
  assert_eq "$(opt '@whistle_count_idle')" '1'
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'idle'
  assert_eq "$(wt show -pqv -t "$p" @whistle_eff)" 'idle'
}

@test "sub: 未过期的 @whistle_sub 强制 running" {
  local p w
  p=$(pane_of)
  w=$(win_of)
  wt set -p -t "$p" @whistle_sub "$(($(date +%s) + 600))"

  whistle_recompute_global
  whistle_recompute_window "$w"

  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_idle')" '0'
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'running'
}

@test "sub: @whistle_sub=0 表示永不过期" {
  local p
  p=$(pane_of)
  wt set -p -t "$p" @whistle_sub 0

  whistle_recompute_global

  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_idle')" '0'
}

@test "sub: 清掉 @whistle_sub 后回落到 idle" {
  local p
  p=$(pane_of)
  # 先坐在一个有效标记上，确认「回落」是清标记带来的，而不是本来就 idle
  wt set -p -t "$p" @whistle_sub "$(($(date +%s) + 600))"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'

  wt set -p -t "$p" @whistle_sub ''

  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '0'
  assert_eq "$(opt '@whistle_count_idle')" '1'
}

# -- 安全阀本体（静态断言） ---------------------------------------------------
#
# 不在这里跑真进程 / 真循环：`@whistle_spin_interval` 调到极小来观测重算是
# 秒级的 sleep 竞态，必然 flaky。起真推进器换帧的用例已经在 spin.bats 里，
# 这里守住「代码里确实有这条节拍」即可。

@test "spin.sh: 语法通过" {
  run sh -n "$WHISTLE_ROOT/lib/spin.sh"
  assert_eq "$status" 0
}

@test "spin.sh: 周期调用 whistle_recompute_global 作为自愈节拍" {
  local s
  s=$(command cat "$WHISTLE_ROOT/lib/spin.sh")

  assert_contains "$s" 'whistle_recompute_global'
}

@test "spin.sh: 节拍间隔读 @whistle_recompute_every，读不到用 60 兜底" {
  local s
  s=$(command cat "$WHISTLE_ROOT/lib/spin.sh")

  assert_contains "$s" "@whistle_recompute_every"
  # 兜底值写死在这段里；option 还没进 WHISTLE_DEFAULTS，
  # 读不到时必须是 60（否则每个 0.5 秒都重算一次）。
  assert_contains "$s" '_rce_every=60'
}
