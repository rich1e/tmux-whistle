#!/usr/bin/env bats
# shellcheck shell=bash
#
# KP-6：pane 边框变色必须可还原。
#
# pane-border-style 是 window option，一改就盖住用户主题里 inactive pane 的边框色。
# 忘了还原，用户会在 prefix r 之后看到一堆"过期"的染色窗口。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  wt_load status-line
  wt_load deliver
  unset TMUX_PANE TMUX
}

teardown() {
  wt_stop
}

win_of() {
  wt display -p -t w1 '#{window_id}'
}

@test "KP-6: 着色前先记录原值" {
  wt set -w -t w1 pane-border-style 'fg=#123456,bg=#654321'
  local w
  w=$(win_of)

  whistle_border_paint "$w" "done"

  assert_eq "$(wt show -wv -t "$w" @whistle_border_orig)" 'fg=#123456,bg=#654321'
  assert_eq "$(wt show -wv -t "$w" @whistle_border_painted)" '1'
}

@test "KP-6: 着色只染 inactive 边框，pane-active-border-style 不动" {
  local w
  w=$(win_of)
  wt set -w -t "$w" pane-active-border-style 'fg=#00ff00'

  whistle_border_paint "$w" "done"

  assert_eq "$(wt show -wv -t "$w" pane-active-border-style)" 'fg=#00ff00'
  assert_contains "$(wt show -wv -t "$w" pane-border-style)" '#af5fff'
}

@test "KP-6: 重复着色不会把我们的颜色当成原值记下来" {
  wt set -w -t w1 pane-border-style 'fg=#123456'
  local w
  w=$(win_of)

  whistle_border_paint "$w" "done"
  whistle_border_paint "$w" "error"
  whistle_border_paint "$w" "wait"

  # 原值必须始终是最初那个
  assert_eq "$(wt show -wv -t "$w" @whistle_border_orig)" 'fg=#123456'
  assert_contains "$(wt show -wv -t "$w" pane-border-style)" '#af8700'
}

@test "KP-6: release 精确还原原值" {
  wt set -w -t w1 pane-border-style 'fg=#123456,bg=#654321'
  local w
  w=$(win_of)

  whistle_border_paint "$w" "done"
  whistle_border_release "$w"

  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#123456,bg=#654321'
}

@test "KP-6: 原值是继承自全局时，release 改为 unset 窗口级覆盖" {
  # oh-my-tmux 用 setw -g 设 pane-border-style，窗口级本来没有值
  wt set -g pane-border-style 'fg=#080808,bg=#202020'
  local w
  w=$(win_of)
  [ -z "$(wt show -wv -t "$w" pane-border-style)" ]

  whistle_border_paint "$w" "done"
  assert_contains "$(wt show -wv -t "$w" pane-border-style)" '#af5fff'

  whistle_border_release "$w"
  # 窗口级覆盖已删除，回到继承全局
  [ -z "$(wt show -wv -t "$w" pane-border-style)" ]
  assert_eq "$(wt show -gwv pane-border-style)" 'fg=#080808,bg=#202020'
}

@test "KP-6: release 清掉自己的追踪 option" {
  local w
  w=$(win_of)
  whistle_border_paint "$w" "done"
  whistle_border_release "$w"

  [ -z "$(wt show -wv -t "$w" @whistle_border_painted)" ]
  [ -z "$(wt show -wv -t "$w" @whistle_border_orig)" ]
}

@test "KP-6: 没画过的窗口 release 是空操作，不动用户主题" {
  wt set -w -t w1 pane-border-style 'fg=#abcdef'
  local w
  w=$(win_of)

  whistle_border_release "$w"
  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#abcdef'
}

@test "KP-6: @whistle_border off 时不着色" {
  wt set -g @whistle_border off
  local w
  w=$(win_of)
  wt set -w -t "$w" pane-border-style 'fg=#123456'

  whistle_border_paint "$w" "done"
  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#123456'
}

@test "KP-6: release_all 清掉所有画过的窗口（prefix r 之后用）" {
  wt new-window -d -n w2
  local w1 w2
  w1=$(wt display -p -t w1 '#{window_id}')
  w2=$(wt display -p -t w2 '#{window_id}')
  wt set -w -t "$w1" pane-border-style 'fg=#111111'
  wt set -w -t "$w2" pane-border-style 'fg=#222222'

  whistle_border_paint "$w1" "done"
  whistle_border_paint "$w2" "wait"

  whistle_border_release_all

  assert_eq "$(wt show -wv -t "$w1" pane-border-style)" 'fg=#111111'
  assert_eq "$(wt show -wv -t "$w2" pane-border-style)" 'fg=#222222'
}

@test "KP-6: running 状态不着色（不是待处理信号）" {
  local w
  w=$(win_of)
  whistle_border_paint "$w" "running"
  [ -z "$(wt show -wv -t "$w" @whistle_border_painted)" ]
}

# -- 状态标签 --------------------------------------------------------------

@test "state_label: 四种状态各有中文标签" {
  assert_eq "$(whistle_state_label "done")" '完成'
  assert_eq "$(whistle_state_label "wait")" '等待'
  assert_eq "$(whistle_state_label "error")" '错误'
}
# -- 边框状态行（分屏时按 pane 显示）------------------------------------------

@test "border-status: off 时完全不碰 pane-border-status" {
  wt set -g @whistle_border_status off
  local w
  w=$(win_of)
  whistle_border_status_apply "$w"
  [ -z "$(wt show -wv -t "$w" @whistle_bs_painted)" ]
}

@test "border-status: top 时设置状态行并记录原值" {
  wt set -g @whistle_border_status top
  wt set -w -t w1 pane-border-status bottom
  local w
  w=$(win_of)

  whistle_border_status_apply "$w"

  assert_eq "$(wt show -wv -t "$w" pane-border-status)" 'top'
  assert_contains "$(wt show -wv -t "$w" pane-border-format)" '#{E:@whistle_pane_mark}'
  assert_eq "$(wt show -wv -t "$w" @whistle_bs_orig_status)" 'bottom'
}

@test "border-status: release 精确还原" {
  wt set -g @whistle_border_status top
  wt set -w -t w1 pane-border-status bottom
  wt set -w -t w1 pane-border-format 'ORIGINAL'
  local w
  w=$(win_of)

  whistle_border_status_apply "$w"
  whistle_border_status_release "$w"

  assert_eq "$(wt show -wv -t "$w" pane-border-status)" 'bottom'
  assert_eq "$(wt show -wv -t "$w" pane-border-format)" 'ORIGINAL'
  [ -z "$(wt show -wv -t "$w" @whistle_bs_painted)" ]
}

@test "border-status: 原值不存在时 release 改为 unset" {
  wt set -g @whistle_border_status top
  local w
  w=$(win_of)

  whistle_border_status_apply "$w"
  whistle_border_status_release "$w"

  [ -z "$(wt show -wv -t "$w" pane-border-status)" ]
  [ -z "$(wt show -wv -t "$w" pane-border-format)" ]
}

@test "border-status: 重复 apply 不会把我们的值当成原值" {
  wt set -g @whistle_border_status top
  wt set -w -t w1 pane-border-status bottom
  local w
  w=$(win_of)

  whistle_border_status_apply "$w"
  whistle_border_status_apply "$w"

  assert_eq "$(wt show -wv -t "$w" @whistle_bs_orig_status)" 'bottom'
}

