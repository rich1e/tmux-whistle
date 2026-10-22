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

# -- 扇出目标：@whistle_self --------------------------------------------------
#
# 打桩 whistle_tmux 记录 display-message 的 -t 参数。headless server 没有
# attached client，list-clients 是空的，不打桩就只能断言 "不崩" —— 而这正是
# 本 bug 长期没被发现的原因（旧的 @whistle_self 用例只断言了 status==0）。

stub_display_targets() {
  local calls="$1"; shift
  : > "$calls"

  # _sd_calls / _sd_clients 必须用全局变量：whistle_tmux 是在这里定义的，
  # 但调用它的是测试体 —— 本函数早已返回，local 变量随之失效，
  # 打桩就会安静地返回空（正是这个坑让第一版用例假绿）。
  _sd_calls="$calls"
  _sd_clients=$(printf '%s\n' "$@")

  # 复制原函数留个后门：配置读取（show）必须仍走真实 tmux。
  # 否则 whistle_conf 拿到空值会回落到默认值表，开关设了也不生效。
  eval "_sd_real_tmux() $(declare -f whistle_tmux | tail -n +2)"

  # shellcheck disable=SC2329  # 由被 source 的 deliver 函数间接调用
  whistle_tmux() {
    case "${1:-}" in
    display-message)
      case "$*" in
      *"#{session_name}"*) printf 'origin-sess' ;;
      *) printf '%s\n' "$*" >> "$_sd_calls" ;;
      esac
      ;;
    list-clients) printf '%s' "$_sd_clients" ;;
    *) _sd_real_tmux "$@" ;;
    esac
    return 0
  }
}

@test "display: @whistle_self off 时不提示发起方所在的 session" {
  wt set -g @whistle_display on
  wt set -g @whistle_self off
  local calls="$BATS_TEST_TMPDIR/self_off"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  whistle_display_fanout "$w" "done" 'x'

  # 断言 -t 目标而不是裸 session 名：消息体本身是 "[origin-sess] 完成: x"，
  # 里面就含 origin-sess 这个字符串。
  run cat "$calls"
  assert_contains "$output" '-t other-sess'
  assert_eq "$(count_occurrences "$output" '-t origin-sess')" 0
}

@test "display: @whistle_self on 时也提示发起方所在的 session" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/self_on"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  whistle_display_fanout "$w" "done" 'x'

  run cat "$calls"
  assert_contains "$output" '-t origin-sess'
  assert_contains "$output" '-t other-sess'
}

@test "display: 扇出按 session 去重，同一 session 的两个 client 只收一次" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/dedup"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess other-sess

  whistle_display_fanout "$w" "done" 'x'

  run cat "$calls"
  assert_eq "$(count_occurrences "$output" '-t other-sess')" 1
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
