#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1 纯函数：菜单共享模型，不碰 tmux。

bats_require_minimum_version 1.5.0

load '../test_helper/whistle'

setup() {
    : "${WHISTLE_ROOT:?helper 未加载}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    # shellcheck source=lib/core.sh
    source "$WHISTLE_ROOT/lib/core.sh"
    # shellcheck source=lib/menu.sh
    source "$WHISTLE_ROOT/lib/menu.sh"

    # 渲染测试使用固定值，绝不因读取配置而访问 tmux。
    # shellcheck disable=SC2329 # 由渲染器间接调用
    whistle_menu_state_icon() {
        case "$1" in
        running) printf '▶' ;;
        idle) printf '◉' ;;
        done) printf '◆' ;;
        wait) printf '◔' ;;
        error) printf '⚠' ;;
        *) printf '' ;;
        esac
    }
    # shellcheck disable=SC2329 # 由渲染器间接调用
    whistle_menu_state_color() {
        case "$1" in
        running) printf '#00af00' ;;
        idle) printf '#8a8a8a' ;;
        done) printf '#af5fff' ;;
        wait) printf '#af8700' ;;
        error) printf '#d70000' ;;
        *) printf '' ;;
        esac
    }
    # shellcheck disable=SC2329 # 由渲染器间接调用
    # 真实实现用一次 tmux 调用取齐十项配置；L1 里由上面两个假实现拼出来，
    # 保持测试完全不碰 tmux。
    whistle_menu_palette() {
        local _s
        for _s in running idle 'done' wait error; do
            printf '%s|%s|%s\n' "$_s" \
                "$(whistle_menu_state_icon "$_s")" \
                "$(whistle_menu_ansi_fg "$(whistle_menu_state_color "$_s")")"
        done
    }
    # shellcheck disable=SC2329 # 由渲染器间接调用
    whistle_state_label() {
        case "$1" in
        running) printf '运行中' ;;
        idle) printf '空闲' ;;
        done) printf '完成' ;;
        wait) printf '等待' ;;
        error) printf '错误' ;;
        *) printf '%s' "$1" ;;
        esac
    }
    WHISTLE_PROG=tmux-whistle
}

@test "menu model: 待处理优先，消息里的竖线完整保留在末列" {
    run whistle_menu_model << 'EOF'
dayfold|@1|editor|1|%1|idle||idle|等待输入
dayfold|@2|claude.exe|2|%2|done|done|running|完成|含竖线
EOF
    assert_eq "$status" 0
    assert_eq "$(printf '%s\n' "$output" | sed -n '1p')" \
        'item|1|@2|%2|dayfold|claude.exe|done|完成|含竖线'
    assert_eq "$(printf '%s\n' "$output" | sed -n '2p')" \
        'item|2|@1|%1|dayfold|editor|idle|等待输入'
}

@test "menu model: 27 项只输出 26 个可选项与一条溢出提示" {
    local input='' i
    for ((i = 1; i <= 27; i++)); do
        input+="dayfold|@$i|w$i|$i|%$i|done|done||消息 $i"$'\n'
    done

    run whistle_menu_model <<< "$input"
    assert_eq "$status" 0
    assert_eq "$(printf '%s\n' "$output" | grep -c '^item|')" '26'
    assert_eq "$(printf '%s\n' "$output" | sed -n '26p' | cut -d'|' -f2)" 'q'
    assert_contains "$output" 'overflow|1'
}

@test "menu model: 空输入输出为空" {
    run whistle_menu_model < /dev/null
    assert_eq "$status" 0
    assert_eq "$output" ''
}

@test "menu selection: 重排后按 window id 跟随选中项" {
    run whistle_menu_reconcile_selection '@2' 2 << 'EOF'
item|1|@2|%2|dayfold|w2|done|完成
item|2|@1|%1|dayfold|w1|idle|等待
EOF
    assert_eq "$status" 0
    assert_eq "$output" '@2|1'
}

@test "menu selection: 选中项被藏到第 27 项时退回第 26 个可见项" {
    local input='' model i
    for ((i = 1; i <= 27; i++)); do
        input+="dayfold|@$i|w$i|$i|%$i|done|done||消息 $i"$'\n'
    done
    model=$(whistle_menu_model <<< "$input")

    run whistle_menu_reconcile_selection '@27' 26 <<< "$model"
    assert_eq "$status" 0
    assert_eq "$output" '@26|26'
}

@test "menu selection: 选中窗口消失且原索引越界时夹到最后一项" {
    run whistle_menu_reconcile_selection '@2' 9 << 'EOF'
item|1|@1|%1|dayfold|w1|idle|一
item|2|@3|%3|dayfold|w3|idle|三
item|3|@4|%4|dayfold|w4|idle|四
EOF
    assert_eq "$status" 0
    assert_eq "$output" '@4|3'
}

@test "menu selection: 模型没有 item 时输出为空" {
    run whistle_menu_reconcile_selection '@1' 1 < /dev/null
    assert_eq "$status" 0
    assert_eq "$output" ''
}

@test "menu decode: 识别方向键、Esc、Enter 与普通字符" {
    local expected args
    local -a octets
    while read -r expected args; do
        read -r -a octets <<< "$args"
        run whistle_menu_decode_key "${octets[@]}"
        assert_eq "$status" 0
        assert_eq "$output" "$expected"
    done << 'EOF'
up 27 91 65
down 27 91 66
exit 27
enter 13
char:q 113
char:1 49
char:a 97
EOF
}

@test "menu decode: 不完整或规格外的输入返回 unknown" {
    local args
    local -a octets
    for args in '27 91' '27 91 67' '113 91' '10'; do
        read -r -a octets <<< "$args"
        run whistle_menu_decode_key "${octets[@]}"
        assert_eq "$status" 0
        assert_eq "$output" 'unknown'
    done
}

@test "menu decode: 前导零仍按十进制 octet 解码" {
    local octet expected
    while read -r octet expected; do
        run --separate-stderr whistle_menu_decode_key "$octet"
        assert_eq "$status" 0
        assert_eq "$output" "$expected"
        assert_eq "$stderr" ''
    done << 'EOF'
0113 char:q
049 char:1
EOF
}

@test "menu decode: 非数值与超大数只返回 unknown 且无诊断输出" {
    local octet
    for octet in '12x' '9999999999999999999999999999999999999999'; do
        run --separate-stderr whistle_menu_decode_key "$octet"
        assert_eq "$status" 0
        assert_eq "$output" 'unknown'
        assert_eq "$stderr" ''
    done
}

@test "menu select-key: q 选择第 26 个可见项" {
    local input='' model i
    for ((i = 1; i <= 26; i++)); do
        input+="dayfold|@$i|w$i|$i|%$i|done|done||消息 $i"$'\n'
    done
    model=$(whistle_menu_model <<< "$input")

    run whistle_menu_select_key q <<< "$model"
    assert_eq "$status" 0
    assert_eq "$output" '@26|%26|26'
}

@test "menu select-key: 不足 26 项时 q 不执行操作" {
    local input='' model i
    for ((i = 1; i <= 25; i++)); do
        input+="dayfold|@$i|w$i|$i|%$i|done|done||消息 $i"$'\n'
    done
    model=$(whistle_menu_model <<< "$input")

    run whistle_menu_select_key q <<< "$model"
    assert_eq "$status" 0
    assert_eq "$output" ''
}

@test "menu ansi: #RRGGBB 映射 truecolor，非法颜色安全回退" {
    local esc
    esc=$(printf '\033')

    run whistle_menu_ansi_fg '#00af00'
    assert_eq "$status" 0
    assert_eq "$output" "${esc}[38;2;0;175;0m"

    local color
    for color in 'colour123' '#12xz00' '#12345' ''; do
        run whistle_menu_ansi_fg "$color"
        assert_eq "$status" 0
        assert_eq "$output" "${esc}[39m"
    done
}

@test "menu render: 帧包含标题、状态、窗口、消息与快捷键" {
    run whistle_menu_render '@1' 120 << 'EOF'
item|1|@1|%1|dayfold|editor|done|做完了
item|2|@2|%2|main|shell|running|继续执行
EOF
    assert_eq "$status" 0
    assert_contains "$output" 'tmux-whistle'
    assert_contains "$output" '(1)'
    assert_contains "$output" '(2)'
    assert_contains "$output" '◆ 完成 [dayfold]: editor 做完了'
    assert_contains "$output" '▶ 运行中 [main]: shell 继续执行'
    assert_not_contains "$output" '#['
}

@test "menu render: 反显只施加在 selected window 对应行" {
    local esc first second
    esc=$(printf '\033')
    run whistle_menu_render '@2' 120 << 'EOF'
item|1|@1|%1|dayfold|editor|done|一
item|2|@2|%2|dayfold|shell|idle|二
EOF
    assert_eq "$status" 0
    first=$(printf '%s\n' "$output" | sed -n '2p')
    second=$(printf '%s\n' "$output" | sed -n '3p')
    assert_not_contains "$first" "${esc}[7m"
    assert_contains "$second" "${esc}[7m"
    assert_not_contains "$second" "${esc}[7m${esc}[7m"
}

@test "menu render: 长 ASCII 按 columns 截断且终止 SGR 完整" {
    local esc line plain
    esc=$(printf '\033')
    run whistle_menu_render '@1' 32 << 'EOF'
item|1|@1|%1|dayfold|editor|done|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
EOF
    assert_eq "$status" 0
    line=$(printf '%s\n' "$output" | sed -n '2p')
    plain=$(printf '%s\n' "$line" | sed -e "s/${esc}\\[[0-9;]*m//g")
    assert_eq "$plain" '(1) ◆ 完成 [dayfold]: editor abc'
    case "$line" in
    *"${esc}[0m") ;;
    *)
        printf '选中行缺少终止 SGR: [%s]\n' "$line" >&2
        return 1
        ;;
    esac
}

@test "menu render: 中文与 emoji 保持完整，窄列不输出半个 UTF-8 字符" {
    run whistle_menu_render '@1' 120 << 'EOF'
item|1|@1|%1|dayfold|编辑器|done|中文🙂🚀完成
EOF
    assert_eq "$status" 0
    assert_contains "$output" '[dayfold]: 编辑器 中文🙂🚀完成'

    run whistle_menu_render '@1' 31 << 'EOF'
item|1|@1|%1|dayfold|editor|done|🙂中文
EOF
    assert_eq "$status" 0
    assert_contains "$output" '🙂'
    assert_not_contains "$output" '�'
    run iconv -f UTF-8 -t UTF-8 <<< "$output"
    assert_eq "$status" 0
}

@test "menu render: render_item 只画一行，选中与否只差反显" {
    local esc line
    esc=$(printf '\033')
    line='item|2|@2|%2|dayfold|编辑器|done|做完了'

    run whistle_menu_render_item "$line" 1 120
    assert_eq "$status" 0
    assert_contains "$output" "${esc}[7m"
    assert_contains "$output" '(2) ◆ 完成 [dayfold]: 编辑器 做完了'

    run whistle_menu_render_item "$line" 0 120
    assert_eq "$status" 0
    assert_not_contains "$output" "${esc}[7m"
    assert_contains "$output" '(2) ◆ 完成'
}

@test "menu model: 最长一行的显示列数就是 popup 的内容宽度" {
    # popup 按内容定宽，所以「多宽」必须和渲染时用的宽度算法一致（同一套 awk）。
    local line width
    line='(1) ◉ 空闲 [main]: w1'
    width="$(printf '%s\n' "$line" | whistle_menu_clip '' 0 maxwidth)"

    run whistle_menu_model_width "$(whistle_menu_palette)" << EOF
item|1|@1|%1|main|w1|idle|
EOF
    assert_eq "$status" 0
    # 标题 "tmux-whistle" 也参与取最大值，但这一行更长。
    assert_eq "$output" "$width"
}

@test "menu render: 🚀 等 U+1F680 之后的 emoji 也按两列计算" {
    # 独立评审 finding #5：宽字符表早先止于 U+1F67F，🚀(U+1F680) 被当成 1 列，
    # clip 出来的行会比 popup 还宽。max=4 应恰好放下 ab + 🚀；max=3 则停在 ab。
    run whistle_menu_clip 'ab🚀cd' 4
    assert_eq "$status" 0
    assert_eq "$output" 'ab🚀'

    run whistle_menu_clip 'ab🚀cd' 3
    assert_eq "$status" 0
    assert_eq "$output" 'ab'
}

@test "menu render: overflow 只有不可选提示且没有快捷键" {
    run whistle_menu_render '@1' 120 << 'EOF'
item|1|@1|%1|dayfold|editor|done|一
overflow|3
EOF
    assert_eq "$status" 0
    local overflow_line esc
    esc=$(printf '\033')
    overflow_line=$(printf '%s\n' "$output" | sed -n '3p')
    assert_contains "$overflow_line" '还有 3 项未显示，用 tmux-whistle list 查看'
    assert_not_contains "$overflow_line" '(2)'
    assert_not_contains "$overflow_line" "${esc}[7m"
}

@test "menu render: 输入中的 ANSI 与 tmux format 不会成为样式" {
    local esc message
    esc=$(printf '\033')
    message=$(printf 'bad\033[7m#[fg=red]text')
    run whistle_menu_render '' 120 << EOF
item|1|@1|%1|day#[blink]fold|editor|done|$message
EOF
    assert_eq "$status" 0
    assert_contains "$output" 'bad'
    assert_contains "$output" 'text'
    assert_not_contains "$output" '#['
    assert_not_contains "$output" "${esc}[7m"
}
