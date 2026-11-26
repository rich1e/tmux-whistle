#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1：读屏防抖状态机（whistle_detect_apply）。
#
# 为什么单独测：这些判据是「几次扫描之后」的语义，放进集成用例里只能靠
# 墙钟时间猜 —— 0.6 秒内有没有发生一次扫描取决于机器忙不忙，断言会假绿。
# 这里直接按调用次数验证，确定性由调用顺序保证。
#
# `→ running` 立即生效，其余切换要连续两次：TUI 重绘、光标闪烁都会让屏幕
# 瞬间「看起来空闲」，一次就信就会让 ▶ 闪成 ◉ 再闪回来。

load '../test_helper/whistle'

setup() {
  : "${WHISTLE_ROOT:?helper 未加载}"
  export WHISTLE_DETECT_STATE_DIR="$BATS_TEST_TMPDIR/detect-state"
  mkdir -p "$WHISTLE_DETECT_STATE_DIR"
  # shellcheck source=/dev/null
  source "$WHISTLE_ROOT/lib/detect.sh"
}

@test "apply: → running 立即生效" {
  run whistle_detect_apply '%1' running
  assert_eq "$status" 0
}

@test "apply: → idle 第一次只记 pending，第二次才生效" {
  run whistle_detect_apply '%1' running
  run whistle_detect_apply '%1' idle
  assert_eq "$status" 1
  run whistle_detect_apply '%1' idle
  assert_eq "$status" 0
}

@test "apply: 已经生效的状态不再重复生效" {
  run whistle_detect_apply '%1' running
  run whistle_detect_apply '%1' running
  assert_eq "$status" 1
}

@test "apply: 中间夹了别的分类要重新数" {
  run whistle_detect_apply '%1' running
  run whistle_detect_apply '%1' idle
  run whistle_detect_apply '%1' running
  run whistle_detect_apply '%1' idle
  assert_eq "$status" 1
  run whistle_detect_apply '%1' idle
  assert_eq "$status" 0
}

@test "apply: forget 之后从头计数" {
  run whistle_detect_apply '%1' running
  run whistle_detect_apply '%1' idle
  whistle_detect_forget '%1'
  run whistle_detect_apply '%1' idle
  assert_eq "$status" 1
}

@test "apply: 不同 pane 的计数互不影响" {
  run whistle_detect_apply '%1' running
  run whistle_detect_apply '%2' idle
  assert_eq "$status" 1
  run whistle_detect_apply '%1' idle
  assert_eq "$status" 1
}

@test "interval: 非法值回落到 15，0 与空也不放行" {
  assert_eq "$(whistle_detect_interval_value '1')" '1'
  assert_eq "$(whistle_detect_interval_value '30')" '30'
  assert_eq "$(whistle_detect_interval_value '1s')" '15'
  assert_eq "$(whistle_detect_interval_value '0')" '15'
  assert_eq "$(whistle_detect_interval_value '')" '15'
}
