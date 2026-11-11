#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1 纯函数：running 的 spinner 帧。
#
# 设计要点：插件把**当前帧字符本身**写进 @whistle_spin_char，format 里只写
# #{@whistle_spin_char}，一层都不嵌套。早先存帧号 + N 层嵌套条件式，4 帧
# 还勉强，10 帧就要嵌 9 层 —— 大括号必然配错，而配错了 tmux 只会静默
# 渲染成空字符串。这里测的就是「字符表怎么走」这一段纯逻辑。

load '../test_helper/whistle'

setup() {
    : "${WHISTLE_ROOT:?helper 未加载}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    # shellcheck source=lib/core.sh
    source "$WHISTLE_ROOT/lib/core.sh"
}

@test "spin: 第一帧是 ·" {
    assert_eq "$(whistle_spin_first)" '·'
}

@test "spin: 七帧按表依次前进（星形逐级长大）" {
    local cur
    cur=$(whistle_spin_first)
    local expect="✢✳✷✸✻✽"
    local got=''
    local i=0
    while [ "$i" -lt 6 ]; do
        cur=$(whistle_spin_next_char "$cur")
        got="$got$cur"
        i=$((i + 1))
    done
    assert_eq "$got" "$expect"
}

@test "spin: 最后一帧之后回到第一帧" {
    assert_eq "$(whistle_spin_next_char '✽')" '·'
}

@test "spin: 当前值不在表里（未初始化或被改坏）回到第一帧" {
    # 帧值存在 user option 里，可能被手改成任何东西，不能因此崩。
    # 老版本的 Braille 帧（⠋ / ⢹ 等）已不在表里，同样落到第一帧。
    assert_eq "$(whistle_spin_next_char '')" '·'
    assert_eq "$(whistle_spin_next_char 'banana')" '·'
    assert_eq "$(whistle_spin_next_char '◐')" '·'
    assert_eq "$(whistle_spin_next_char '⠋')" '·'
}

@test "spin: 帧表里没有重复字形（重复会让动画卡死）" {
    # whistle_spin_next_char 是「查当前字 → 取下一个」的无状态查表：同一个字
    # 出现两次时，查找永远匹配到前面那一个，动画会卡在它身上打转。
    # Claude Code 原版是 12 帧「长—缩」循环，缩的半段与长的半段同字形，所以
    # 这里只搬长的半段；这条用例守着「别把缩的半段抄进来」。
    local cur next seen=' ' i=0
    cur=$(whistle_spin_first)
    while [ "$i" -lt 7 ]; do
        case "$seen" in
        *" $cur "*) echo "字形重复：$cur" && return 1 ;;
        esac
        seen="$seen$cur "
        next=$(whistle_spin_next_char "$cur")
        [ "$next" != "$cur" ] || {
            echo "第 $i 帧没有前进：$cur"
            return 1
        }
        cur="$next"
        i=$((i + 1))
    done
    assert_eq "$cur" '·'
}

@test "spin: 表里的每一帧都能接上，没有断链" {
    local cur next
    cur=$(whistle_spin_first)
    local i=0
    while [ "$i" -lt 7 ]; do
        next=$(whistle_spin_next_char "$cur")
        [ -n "$next" ] || {
            echo "第 $i 帧之后接不上了"
            return 1
        }
        cur="$next"
        i=$((i + 1))
    done
    # 转满一圈应当回到起点
    assert_eq "$cur" '·'
}

@test "spin: format 片段只引用 option，不嵌套条件式" {
    run whistle_spin_build
    assert_contains "$output" '#{@whistle_spin_char}'
    local open close
    open=$(printf '%s' "$output" | tr -cd '{' | wc -c | tr -d ' ')
    close=$(printf '%s' "$output" | tr -cd '}' | wc -c | tr -d ' ')
    assert_eq "$open" "$close"
    # 只有一个条件式（#{?）。这是这版设计的核心约束：存字符本身，
    # 不需要「帧号 → 字符」的 N 层查表，帧数再多也不会加深嵌套。
    assert_eq "$(count_occurrences "$output" '#{?')" '1'
}

@test "spin: format 片段不过消毒（消毒会剔掉 #{} 把 format 毁掉）" {
    # 这是它与 @whistle_icon_* 最大的不同：图标要过 whistle_sanitize，
    # 帧片段**绝不能**过，否则 #{@whistle_spin_char} 被剔成空串，
    # 动画永远停在同一帧 —— 而且不报错。
    run whistle_spin_build
    assert_contains "$output" '#{'
    run whistle_sanitize "$(whistle_spin_build)"
    assert_not_contains "$output" '#{'
}
