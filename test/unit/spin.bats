#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1 纯函数：running 的 Braille 帧。
#
# 帧定义与帧选择器生成都是纯的（不碰 tmux），所以能放这一层。
# tmux 不在这里的原因是：格式里能写的只有 #{@whistle_spin} 这个 option 名，
# 真正的取值发生在 tmux 渲染时，不在本进程。

load '../test_helper/whistle'

setup() {
    : "${WHISTLE_ROOT:?helper 未加载}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    # shellcheck source=lib/core.sh
    source "$WHISTLE_ROOT/lib/core.sh"
}

@test "spin: 四帧就是设计的那四个，顺序固定" {
    assert_eq "$(whistle_spin_frame 0)" '◐'
    assert_eq "$(whistle_spin_frame 1)" '◓'
    assert_eq "$(whistle_spin_frame 2)" '◑'
    assert_eq "$(whistle_spin_frame 3)" '◒'
    assert_eq "$WHISTLE_SPIN_FRAMES" '4'
}

@test "spin: 序号越界或非法一律回落到第 0 帧" {
    # 帧号是 option 的值，可能被手改成任何东西 —— 不能因此崩。
    assert_eq "$(whistle_spin_frame 4)" '◐'
    assert_eq "$(whistle_spin_frame 99)" '◐'
    assert_eq "$(whistle_spin_frame -1)" '◐'
    assert_eq "$(whistle_spin_frame '')" '◐'
    assert_eq "$(whistle_spin_frame banana)" '◐'
}

@test "spin: 帧选择器的大括号配平（畸形 format 会被 tmux 静默渲染成空）" {
    run whistle_spin_build
    local open close
    open=$(printf '%s' "$output" | tr -cd '{' | wc -c | tr -d ' ')
    close=$(printf '%s' "$output" | tr -cd '}' | wc -c | tr -d ' ')
    assert_eq "$open" "$close"
}

@test "spin: 帧选择器读 @whistle_spin_frame，三个条件式分支" {
    run whistle_spin_build
    # 三个 #{==:#{@whistle_spin_frame},X} —— 第 4 帧是兜底，不需要比较。
    # ⚠️ 这里必须断言 _frame 而不是 @whistle_spin：后者是 on/off 开关。
    # 两者曾经撞名，导致开关被自己的帧号覆盖成 0，动画被永久判成「关」。
    assert_eq "$(count_occurrences "$output" '#{@whistle_spin_frame}')" '3'
    assert_eq "$(count_occurrences "$output" '#{@whistle_spin},')" '0'
}

@test "spin: 四个帧字符都出现在选择器里" {
    run whistle_spin_build
    assert_contains "$output" '◐'
    assert_contains "$output" '◓'
    assert_contains "$output" '◑'
    assert_contains "$output" '◒'
}

@test "spin: 帧选择器不过消毒（消毒会剔掉 #{} 把 format 毁掉）" {
    # 这是它与 @whistle_icon_* 最大的不同：图标要过 whistle_sanitize，
    # 帧选择器**绝不能**过，否则 #{@whistle_spin} 会被剔成空串，
    # 动画就永远停在同一帧 —— 而且不报错。
    run whistle_spin_build
    assert_contains "$output" '#{'
    run whistle_sanitize "$(whistle_spin_build)"
    assert_not_contains "$output" '#{'
}