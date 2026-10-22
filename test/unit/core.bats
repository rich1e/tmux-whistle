#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1 纯函数单测：不碰 tmux，只测 §4.0 的消毒 / 优先级 / 聚合。

load '../test_helper/whistle'

setup() {
    # WHISTLE_ROOT 由 helper 的 setup_file 设好（仓库根）
    : "${WHISTLE_ROOT:?helper 未加载}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    # shellcheck source=lib/core.sh
    source "$WHISTLE_ROOT/lib/core.sh"
}

# -- whistle_sanitize ------------------------------------------------------

@test "sanitize: 剔除会破坏 format 的 # { } |" {
    run whistle_sanitize 'a#{b}c{d}e|f'
    assert_eq "$status" 0
    assert_eq "$output" 'abcdef'
}

@test "sanitize: 控制字符被剔除，换行折叠成空格" {
    run whistle_sanitize "$(printf '重构\n完成\t啦\r')"
    assert_eq "$output" '重构 完成 啦'
}

@test "sanitize: 连续空格折叠，两端去空白" {
    run whistle_sanitize '   重构   完成   '
    assert_eq "$output" '重构 完成'
}

@test "sanitize: 保留逗号（display-menu 引号标签内安全）" {
    run whistle_sanitize '重构完成, 已提交'
    assert_eq "$output" '重构完成, 已提交'
}

@test "sanitize: 保留中文与 emoji" {
    run whistle_sanitize '重构完成 ✅'
    assert_eq "$output" '重构完成 ✅'
}

@test "sanitize: 截断到 80 字符" {
    local long
    long="$(printf '文%.0s' $(seq 1 200))"
    run whistle_sanitize "$long"
    assert_eq "${#output}" 80
}

@test "sanitize: 空输入得到空输出" {
    run whistle_sanitize ''
    assert_eq "$output" ''
    run whistle_sanitize
    assert_eq "$output" ''
}

@test "sanitize: 纯 format 注入串不产生可展开结构" {
    # KP-3 的核心断言：消毒后不可能再出现 "#{"
    run whistle_sanitize '#{?a,b}'
    assert_not_contains "$output" '#'
    assert_not_contains "$output" '{'
}

# -- whistle_rank ----------------------------------------------------------

@test "rank: error > wait > done > running > 空" {
    assert_eq "$(whistle_rank error)" 4
    assert_eq "$(whistle_rank wait)" 3
    assert_eq "$(whistle_rank "done")" 2
    assert_eq "$(whistle_rank running)" 1
    assert_eq "$(whistle_rank '')" 0
}

@test "rank: 未知状态当 0（脏数据不会顶高徽章优先级）" {
    assert_eq "$(whistle_rank banana)" 0
    assert_eq "$(whistle_rank DONE)" 0
    assert_eq "$(whistle_rank)" 0
}

# -- whistle_is_state / is_notified ----------------------------------------

@test "is_state: 只认四种状态" {
    whistle_is_state "running" && true || return 1
    whistle_is_state "done" && true || return 1
    whistle_is_state "wait" && true || return 1
    whistle_is_state "error" && true || return 1
    run whistle_is_state idle
    assert_eq "$status" 1
}

@test "is_notified: done/wait/error 算待处理，running 不算" {
    whistle_is_notified "done" && true || return 1
    whistle_is_notified "wait" && true || return 1
    whistle_is_notified "error" && true || return 1
    run whistle_is_notified "running"
    assert_eq "$status" 1
    run whistle_is_notified ''
    assert_eq "$status" 1
}

# -- whistle_aggregate -----------------------------------------------------

@test "aggregate: 单个 pane 的状态原样透出" {
    run whistle_aggregate <<'EOF'
%1|done|重构完成
EOF
    assert_eq "$output" 'done|重构完成|1'
}

@test "aggregate: 优先级 error > wait > done > running" {
    run whistle_aggregate <<'EOF'
%1|running|在跑
%2|done|做完了
%3|wait|等你批
EOF
    assert_eq "$output" 'wait|等你批|2'
}

@test "aggregate: error 压过一切" {
    run whistle_aggregate <<'EOF'
%1|done|做完了
%2|wait|等你批
%3|error|炸了
EOF
    assert_eq "$output" 'error|炸了|3'
}

@test "aggregate: 全部 running 时输出 running，计数 0" {
    run whistle_aggregate <<'EOF'
%1|running|在跑
%2|running|也在跑
EOF
    assert_eq "$output" 'running|在跑|0'
}

@test "aggregate: 全部为空时输出空状态" {
    run whistle_aggregate <<'EOF'
%1||
%2||
EOF
    assert_eq "$output" '||0'
}

@test "aggregate: 空输入" {
    run whistle_aggregate </dev/null
    assert_eq "$output" '||0'
}

@test "aggregate: @whistle 为空时消息不会被误读成状态（非空白分隔符的意义）" {
    # 若分隔符用 TAB 或空格，read 会折叠连续分隔符：
    # "%1<TAB><TAB>done" 会被读成 _pane_id=%1 _state=done _msg=空 ——
    # 也就是消息被误当成状态，徽章会凭空点亮。
    # 用 '|' 作分隔符（非空白）则不会折叠。字面量 "done" 正是这个陷阱的探针。
    # 期望仍是空状态：state 为空时没有"胜出"的状态，消息槽随之留空。
    run whistle_aggregate <<'EOF'
%1||done
EOF
    assert_eq "$output" '||0'
}

@test "aggregate: 消息含分隔符不会挤掉后续字段" {
    run whistle_aggregate <<'EOF'
%1|done|a|b|c
EOF
    assert_eq "$output" 'done|a|b|c|1'
}

@test "aggregate: 跳过格式错误的行" {
    run whistle_aggregate <<'EOF'
garbage-without-separator
%1|done|做完了
EOF
    assert_eq "$output" 'done|做完了|1'
}

@test "aggregate: 跳过空行" {
    run whistle_aggregate <<'EOF'

%1|wait|等你

%2|done|好了
EOF
    assert_eq "$output" 'wait|等你|2'
}

@test "aggregate: 未知状态不计入 pending，也不顶优先级" {
    run whistle_aggregate <<'EOF'
%1|banana|脏数据
%2|running|在跑
EOF
    assert_eq "$output" 'running|在跑|0'
}

@test "aggregate: 最后一行没有换行符也要处理" {
    printf '%%1|done|最后一行' | whistle_aggregate >"$BATS_TEST_TMPDIR/out"
    run cat "$BATS_TEST_TMPDIR/out"
    assert_eq "$output" 'done|最后一行|1'
}

# -- whistle_count_states ---------------------------------------------------

@test "count_states: 四态各数各的" {
    run whistle_count_states <<'EOF'
%1|running|
%2|running|
%3|done|好了
%4|wait|等着
%5|error|炸了
EOF
    assert_eq "$output" '2|1|1|1'
}

@test "count_states: 空输入全是 0" {
    run whistle_count_states </dev/null
    assert_eq "$output" '0|0|0|0'
}

@test "count_states: 跳过空状态与格式错误的行" {
    run whistle_count_states <<'EOF'
garbage
%1||
%2||消息误读探针
%3|banana|
%4|done|
EOF
    assert_eq "$output" '0|1|0|0'
}