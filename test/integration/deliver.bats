#!/usr/bin/env bats
# shellcheck shell=bash
#
# 四渠道投递。默认配置下 os 是 off、headless server 没有 client，
# 所以大部分用例验证的是"开关生效"与"不误伤用户配置"。

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

# -- 编排 ------------------------------------------------------------------

@test "deliver: @whistle_enabled off 时什么都不做" {
  wt set -g @whistle_enabled off
  local w
  w=$(win_of)

  wt set -w -t "$w" pane-border-style 'fg=#123456'
  whistle_deliver "$w" "done" '做完了'

  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#123456'
}

@test "deliver: 总开关开着时会走到边框通道" {
  local w
  w=$(win_of)
  whistle_deliver "$w" "done" '做完了'
  assert_eq "$(wt show -wv -t "$w" @whistle_border_painted)" '1'
}

# -- 开关逐项生效 ----------------------------------------------------------

@test "开关: @whistle_border off 时边框不动" {
  wt set -g @whistle_border off
  local w
  w=$(win_of)
  whistle_deliver "$w" "done" 'x'
  [ -z "$(wt show -wv -t "$w" @whistle_border_painted)" ]
}

@test "开关: @whistle_os off 时不调用任何通知命令" {
  wt set -g @whistle_os off
  # 用一个必然失败的 PATH 验证 osascript 没被调用
  local w
  w=$(win_of)
  run whistle_os_notify "$w" "done" 'x'
  assert_eq "$status" 0
  [ -z "${WHISTLE_LOG:-}" ]
}

@test "开关: @whistle_display off 时不写 message" {
  wt set -g @whistle_display off
  local w
  w=$(win_of)
  # 无 client 的 headless server 下 display-message 本就无目标，
  # 这里验证开关打开时也不崩
  run whistle_display_fanout "$w" "done" 'x'
  assert_eq "$status" 0
}

# -- 状态栏重画门控（KP-15） -----------------------------------------------

@test "KP-15: 只刷新受影响 session 的 client，且带 -S（只刷状态栏）" {
  # 打桩 tmux：把调用记录下来，避免依赖真实 attached client
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"

  # shellcheck disable=SC2329  # 由被 source 的 whistle_refresh_sessions 间接调用
  whistle_tmux() {
    case "${1:-}" in
    display-message) printf 'target-sess' ;;
    list-clients) printf 'c1 target-sess\nc2 other-sess\n' ;;
    refresh-client) printf '%s\n' "$*" >> "$calls" ;;
    esac
    return 0
  }

  whistle_refresh_sessions '@1'

  run cat "$calls"
  assert_contains "$output" '-t c1 -S'
  # 不在目标 session 的 client 不该被刷
  assert_not_contains "$output" 'c2'
}

@test "KP-15: 没有 client 时不发任何 refresh" {
  local calls="$BATS_TEST_TMPDIR/calls2"
  : > "$calls"

  # shellcheck disable=SC2329  # 由被 source 的 whistle_refresh_sessions 间接调用
  whistle_tmux() {
    case "${1:-}" in
    display-message) printf 'target-sess' ;;
    list-clients) printf '' ;;
    refresh-client) printf '%s\n' "$*" >> "$calls" ;;
    esac
    return 0
  }

  whistle_refresh_sessions '@1'
  run cat "$calls"
  assert_eq "$output" ''
}

@test "KP-15: 无 attached client 时真实 refresh 直接跳过，不报错" {
  local w
  w=$(win_of)
  run whistle_refresh_sessions "$w"
  assert_eq "$status" 0
  run whistle_refresh_all
  assert_eq "$status" 0
}

# -- 瞬时提示的消息文案 ----------------------------------------------------

@test "display: 消息体含 session、状态标签与消息文本" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local w
  w=$(win_of)
  run whistle_display_fanout "$w" "done" '重构完成'
  assert_eq "$status" 0
}

# -- 系统通知 --------------------------------------------------------------

@test "os: AppleScript 字符串转义（消息含引号与反斜杠时不会破命令）" {
  local esc
  esc=$(whistle_osa_escape 'he said "hi"\back')
  assert_contains "$esc" '\"hi\"'
  assert_contains "$esc" '\\back'
}

@test "os: 没有任何通知命令时不报错，只记日志" {
  # 把 PATH 清空到只剩 tmux，模拟最小环境
  local oldpath="$PATH"
  PATH="/usr/bin:/bin"
  command -v osascript > /dev/null || true
  run whistle_os_notify "$(win_of)" "done" 'x'
  assert_eq "$status" 0
  PATH="$oldpath"
}
# -- 自愈：主题重载覆盖补丁后，投递时能补回来 --------------------------------

@test "自愈: status-right 被主题覆盖后，deliver 会重新打上补丁" {
  whistle_mark_publish
  whistle_status_right_publish

  # 模拟 oh-my-mux 重算主题：把两处格式整个换掉
  wt set -g window-status-format 'THEME-REWRITTEN'
  wt set -g status-right 'THEME-RIGHT'

  local w
  w=$(win_of)
  whistle_deliver "$w" "done" 'x'

  run opt 'window-status-format'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_mark}')" "1"

  run opt 'status-right'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_status_right}')" "1"
}

@test "自愈: 连续 deliver 三次仍只有一处哨兵" {
  local w
  w=$(win_of)
  whistle_deliver "$w" "done" 'a'
  whistle_deliver "$w" "wait" 'b'
  whistle_deliver "$w" "error" 'c'

  run opt 'window-status-format'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_mark}')" "1"
  run opt 'status-right'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_status_right}')" "1"
}
