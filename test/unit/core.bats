#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1 纯函数单测：不碰 tmux，只测 §4.0 的消毒 / 优先级 / 聚合 / 推导层。

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

@test "rank: error > wait > done > running > idle > 空" {
    assert_eq "$(whistle_rank error)" 5
    assert_eq "$(whistle_rank wait)" 4
    assert_eq "$(whistle_rank "done")" 3
    assert_eq "$(whistle_rank running)" 2
    assert_eq "$(whistle_rank idle)" 1
    assert_eq "$(whistle_rank '')" 0
}

@test "rank: idle 严格低于 running，又必须高过 0" {
    # 低于 running：同一窗口里既有在跑的、又有空闲的 pane 时，徽章要显示 ▶。
    # 高过 0：整个窗口的 agent 都空闲时，idle 必须赢得过初始值 0，
    #         否则徽章什么都不显示（那正是恢复 tmux 后最想看到 ◉ 的时刻）。
    [ "$(whistle_rank running)" -gt "$(whistle_rank idle)" ] || return 1
    [ "$(whistle_rank idle)" -gt 0 ] || return 1
}

@test "rank: 未知状态当 0（脏数据不会顶高徽章优先级）" {
    assert_eq "$(whistle_rank banana)" 0
    assert_eq "$(whistle_rank DONE)" 0
    assert_eq "$(whistle_rank)" 0
}

# -- whistle_is_state / is_activity / is_notified --------------------------

@test "is_state: 只认五种用户能报的状态" {
    whistle_is_state "running" && true || return 1
    whistle_is_state "idle" && true || return 1
    whistle_is_state "done" && true || return 1
    whistle_is_state "wait" && true || return 1
    whistle_is_state "error" && true || return 1
    run whistle_is_state banana
    assert_eq "$status" 1
}

@test "is_activity: 活动通道只有 running / idle" {
    whistle_is_activity "running" && true || return 1
    whistle_is_activity "idle" && true || return 1
    run whistle_is_activity "done"
    assert_eq "$status" 1
    run whistle_is_activity "wait"
    assert_eq "$status" 1
    run whistle_is_activity "error"
    assert_eq "$status" 1
    run whistle_is_activity "gone"
    assert_eq "$status" 1
}

@test "is_notified: 通知通道是 done/wait/error，running / idle 不算" {
    whistle_is_notified "done" && true || return 1
    whistle_is_notified "wait" && true || return 1
    whistle_is_notified "error" && true || return 1
    run whistle_is_notified "running"
    assert_eq "$status" 1
    run whistle_is_notified "idle"
    assert_eq "$status" 1
    run whistle_is_notified ''
    assert_eq "$status" 1
}

@test "is_transient: running / idle 跟着 agent 进程活，待处理通知不是" {
    whistle_is_transient "running" && true || return 1
    whistle_is_transient "idle" && true || return 1
    run whistle_is_transient "done"
    assert_eq "$status" 1
    run whistle_is_transient "wait"
    assert_eq "$status" 1
    run whistle_is_transient "error"
    assert_eq "$status" 1
    run whistle_is_transient ''
    assert_eq "$status" 1
}

# -- gone（只有 SessionEnd 会写的内部状态） ----------------------------------
#
# gone 的全部语义都靠「rank = 0 且状态列非空」这两点实现：
#   - rank 0 → 赢不过任何真实状态，窗口徽章不会显示它
#   - 状态列非空 → 「按进程发现」不会把它认成空闲
# 它不是用户能报的状态，所以 is_state 必须不认它。

@test "gone: rank 是 0，不认它是可报状态，也不算待处理/临时状态" {
    assert_eq "$(whistle_rank gone)" 0
    run whistle_is_state gone
    assert_eq "$status" 1
    run whistle_is_activity gone
    assert_eq "$status" 1
    run whistle_is_notified gone
    assert_eq "$status" 1
    run whistle_is_transient gone
    assert_eq "$status" 1
}

# -- whistle_effective_state -----------------------------------------------
#
# 有效态 = 活动态与通知态按 rank 取高者。
# 这是双通道模型的核心：两条通道互不排斥，显示时按优先级合成一个。

@test "effective_state: 通知 rank 高于活动时取通知" {
    assert_eq "$(whistle_effective_state running 'done')" 'done'
    assert_eq "$(whistle_effective_state idle wait)" 'wait'
    assert_eq "$(whistle_effective_state running error)" 'error'
}

@test "effective_state: 活动 rank 高于通知时取活动" {
    # 通知通道只有 done/wait/error（rank ≥ 3），活动最高是 running（2），
    # 所以「活动胜出」实际只发生在通知为空时。
    assert_eq "$(whistle_effective_state running '')" 'running'
    assert_eq "$(whistle_effective_state idle '')" 'idle'
}

@test "effective_state: 只有通知时取通知" {
    assert_eq "$(whistle_effective_state '' 'done')" 'done'
    assert_eq "$(whistle_effective_state '' error)" 'error'
}

@test "effective_state: 两者都空 → 空串" {
    assert_eq "$(whistle_effective_state '' '')" ''
    assert_eq "$(whistle_effective_state)" ''
}

@test "effective_state: gone 不显示（rank 0）" {
    assert_eq "$(whistle_effective_state gone '')" ''
    # 有通知时 gone 不挡着通知
    assert_eq "$(whistle_effective_state gone 'done')" 'done'
}

@test "effective_state: 未知状态当没有状态" {
    assert_eq "$(whistle_effective_state banana '')" ''
    assert_eq "$(whistle_effective_state '' banana)" ''
}

# -- whistle_aggregate -----------------------------------------------------
#
# stdin  = 推导层输出 5 列：<pane_id>|<有效态>|<通知态>|<活动态>|<消息>
# stdout = 6 列：<有效态>|<消息>|<待处理数>|<胜出 pane>|<通知态>|<通知消息>
#
# 第 4 列是「胜出状态」所在的 pane。pane 必须由这个函数产出，不能另扫一遍 ——
# 「哪个状态显示在窗口上」和「pane id 是谁」必须来自同一次判断，
# 两次扫描可能选出不同的 pane，那就是 bug。
#
# 待处理数在第 3 列：whistle_recompute_global 用 `cut -d'|' -f3` 取它，
# 位置不能变。

@test "aggregate: 单个 pane 的状态原样透出" {
    run whistle_aggregate <<'EOF'
%1|done|done||重构完成
EOF
    assert_eq "$output" 'done|重构完成|1|%1|done|重构完成'
}

@test "aggregate: 优先级 error > wait > done > running" {
    run whistle_aggregate <<'EOF'
%1|running||running|在跑
%2|done|done||做完了
%3|wait|wait||等你批
EOF
    assert_eq "$output" 'wait|等你批|2|%3|wait|等你批'
}

@test "aggregate: error 压过一切" {
    run whistle_aggregate <<'EOF'
%1|done|done||做完了
%2|wait|wait||等你批
%3|error|error||炸了
EOF
    assert_eq "$output" 'error|炸了|3|%3|error|炸了'
}

@test "aggregate: 全部 running 时输出 running，计数 0" {
    run whistle_aggregate <<'EOF'
%1|running||running|在跑
%2|running||running|也在跑
EOF
    assert_eq "$output" 'running|在跑|0|%1||'
}

@test "aggregate: 全部为空时输出空状态" {
    run whistle_aggregate <<'EOF'
%1||||
%2||||
EOF
    assert_eq "$output" '||0|||'
}

@test "aggregate: 空输入" {
    run whistle_aggregate </dev/null
    assert_eq "$output" '||0|||'
}

@test "aggregate: 消息不会被误读成状态（非空白分隔符的意义）" {
    # 若分隔符用 TAB 或空格，read 会折叠连续分隔符：
    # "%1<TAB><TAB>done" 会被读成 _pane_id=%1 _eff=done ... ——
    # 也就是消息被误当成状态，徽章会凭空点亮。
    # 用 '|' 作分隔符（非空白）则不会折叠。字面量 "done" 正是这个陷阱的探针。
    run whistle_aggregate <<'EOF'
%1||||done
EOF
    assert_eq "$output" '||0|||'
}

@test "aggregate: 消息含分隔符不会挤掉后续字段" {
    run whistle_aggregate <<'EOF'
%1|done|done||a|b|c
EOF
    assert_eq "$output" 'done|a|b|c|1|%1|done|a|b|c'
}

@test "aggregate: 跳过格式错误的行" {
    run whistle_aggregate <<'EOF'
garbage-without-separator
%1|done|done||做完了
EOF
    assert_eq "$output" 'done|做完了|1|%1|done|做完了'
}

@test "aggregate: 跳过空行" {
    run whistle_aggregate <<'EOF'

%1|wait|wait||等你

%2|done|done||好了
EOF
    assert_eq "$output" 'wait|等你|2|%1|wait|等你'
}

@test "aggregate: 只有 idle 时也能胜出（整窗口空闲要显示 ◉）" {
    run whistle_aggregate <<'EOF'
%1|idle||idle|
%2|idle||idle|
EOF
    assert_eq "$output" 'idle||0|%1||'
}

@test "aggregate: running 压过 idle（同一窗口有在跑的就不显示空闲）" {
    run whistle_aggregate <<'EOF'
%1|idle||idle|
%2|running||running|在跑
EOF
    assert_eq "$output" 'running|在跑|0|%2||'
}

@test "aggregate: 未知状态不计入 pending，也不顶优先级" {
    run whistle_aggregate <<'EOF'
%1|banana||banana|脏数据
%2|running||running|在跑
EOF
    assert_eq "$output" 'running|在跑|0|%2||'
}

@test "aggregate: 最后一行没有换行符也要处理" {
    printf '%%1|done|done||最后一行' | whistle_aggregate >"$BATS_TEST_TMPDIR/out"
    run cat "$BATS_TEST_TMPDIR/out"
    assert_eq "$output" 'done|最后一行|1|%1|done|最后一行'
}

@test "aggregate: 第 4 列是胜出状态的 pane id" {
    run whistle_aggregate <<'EOF'
%7|running||running|在跑
%12|wait|wait||等你批
%3|done|done||好了
EOF
    assert_eq "$output" 'wait|等你批|2|%12|wait|等你批'
}

@test "aggregate: 等级相同时取先出现的那个 pane" {
    # 窗口里两个 pane 同时 done。断言的是「有确定答案」（先来先得），
    # 不是「答案一定是谁」—— 遍历顺序由 list-panes 决定。
    run whistle_aggregate <<'EOF'
%4|done|done||甲
%9|done|done||乙
EOF
    assert_eq "$output" 'done|甲|2|%4|done|甲'
}

@test "aggregate: 无人胜出时第 4 列是空串" {
    # 所有 pane 都没有状态：没有胜出者，就没有 pane id。
    # 这里特别容易写成 %1 —— _best_rank 为 0 时那个分支根本不进。
    run whistle_aggregate <<'EOF'
%1|banana||banana|脏数据
EOF
    assert_eq "$output" '||0|||'
}

@test "aggregate: 多加一列不改变待处理数的语义" {
    # 防「修过头」：多输出 pane 不能影响 pending 的算法。
    run whistle_aggregate <<'EOF'
%1|done|done||好了
%2|running||running|在跑
%3|error|error||炸了
EOF
    assert_eq "$(printf '%s' "$output" | cut -d'|' -f3)" 2
    # 第 4 列是胜出 pane（不再是末位 —— 末位现在是通知消息）
    assert_eq "$(printf '%s' "$output" | cut -d'|' -f4)" '%3'
}

@test "aggregate: 活动与通知并存时两条通道各记各的" {
    # 同一个 pane：一面在跑、一面有事找你。
    # 有效态取 rank 高者（通知），但待处理数仍要算它。
    run whistle_aggregate <<'EOF'
%1|done|done|running|做完了
EOF
    assert_eq "$output" 'done|做完了|1|%1|done|做完了'
}

# -- whistle_resolve_idle_panes ----------------------------------------------
#
# 输入 6 列：<pane_id>|<活动态>|<通知态>|<活动消息>|<通知消息>|<命令名>
# 输出 5 列：<pane_id>|<有效态>|<通知态>|<活动态>|<消息>
#
# 输出**去掉了命令列**：下游（whistle_aggregate、菜单的 read）按固定列数读，
# POSIX 的 read 会把多出来的字段（含分隔符）塞进最后一个变量。
# 消息必须在**末位**，否则消息会被后面的列顶掉。

@test "resolve_idle_panes: 没上报状态但前台跑着 agent → idle" {
  run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息|通知消息|claude.exe
%2||done|活动消息|通知消息|zsh
EOF
  assert_eq "$output" '%1|done|done|idle|通知消息
%2|done|done||通知消息'
}

@test "resolve_idle_panes: 有上报状态的不动（哪怕前台也是 agent）" {
  # gone 尤其不能被认回 idle：那是「agent 已退出」的标记。
  run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1|running||活动消息|通知消息|claude.exe
%2|idle||活动消息|通知消息|claude.exe
%3|gone||活动消息|通知消息|claude.exe
EOF
  assert_eq "$output" '%1|running||running|通知消息
%2|idle||idle|通知消息
%3|||gone|通知消息'
}

@test "resolve_idle_panes: 清单为空 → 不发现任何 agent，但列数照旧" {
  # 去列与「发现 agent」是两件事：列数必须与清单无关，
  # 否则用户清空 @whistle_agent_cmds 就会把「消息|进程名」当消息。
  run whistle_resolve_idle_panes '' 2 <<'EOF'
%1||done|活动消息|通知消息|claude.exe
EOF
  assert_eq "$output" '%1|done|done||通知消息'
}

@test "resolve_idle_panes: 状态列号可配（菜单那份状态在第 6 列）" {
  # 菜单那份是 10 列：session|wid|wname|widx|pane_id|活动|通知|活动消息|通知消息|命令
  run whistle_resolve_idle_panes 'claude claude.exe' 6 5 <<'EOF'
s|w1|wn|1|%1|||||claude.exe
EOF
  assert_eq "$output" 's|w1|wn|1|%1|idle||idle|'
}

@test "resolve_idle_panes: 消息里带 '|' 也不会把命令列带偏（命令列取最后一列）" {
  # 命令列用 $(NF) 取，不用固定列号 —— 消息里的 '|' 会把列号带偏。
  run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|a|b|c|claude.exe
EOF
  assert_eq "$output" '%1|done|done|idle|b'
}

@test "resolve_idle_panes: 通知消息优先，空则用活动消息" {
  run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息||claude.exe
%2||done||通知消息|claude.exe
EOF
  assert_eq "$output" '%1|done|done|idle|活动消息
%2|done|done|idle|通知消息'
}

@test "resolve_idle_panes: 有效态取 rank 高者" {
  run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息|通知消息|claude.exe
%2||error|活动消息|通知消息|claude.exe
%3||wait|活动消息|通知消息|claude.exe
EOF
  assert_eq "$output" '%1|done|done|idle|通知消息
%2|error|error|idle|通知消息
%3|wait|wait|idle|通知消息'
}

@test "resolve_idle_panes: 子 agent 标记有效 → 活动态强制 running" {
  # 子 agent 标记列在状态块之后（第 sc+4 列），存的是过期时间戳。
  WHISTLE_NOW=1700000000 run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息|通知消息|1700000001|claude.exe
EOF
  assert_eq "$output" '%1|done|done|running|通知消息'
}

@test "resolve_idle_panes: 子 agent 标记过期 → 不再强制 running" {
  WHISTLE_NOW=1700000000 run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息|通知消息|1699999999|claude.exe
EOF
  assert_eq "$output" '%1|done|done|idle|通知消息'
}

@test "resolve_idle_panes: 子 agent 标记为 0 表示永不过期" {
  WHISTLE_NOW=1700000000 run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息|通知消息|0|claude.exe
EOF
  assert_eq "$output" '%1|done|done|running|通知消息'
}

@test "resolve_idle_panes: 没有子 agent 标记列时列数照旧" {
  # 子 agent 列是可选的：给了就用，没给就是没有子 agent。
  run whistle_resolve_idle_panes 'claude claude.exe' 2 <<'EOF'
%1||done|活动消息|通知消息|claude.exe
EOF
  assert_eq "$output" '%1|done|done|idle|通知消息'
}

# -- whistle_count_states ---------------------------------------------------

@test "count_states: 五种状态各数各的" {
    run whistle_count_states <<'EOF'
%1|running||running|
%2|running||running|
%3|idle||idle|
%4|done|done||好了
%5|wait|wait||等着
%6|error|error||炸了
EOF
    assert_eq "$output" '2|1|1|1|1'
}

@test "count_states: 分通道计数 —— 同一个 pane 同时 running 与 done 各计一次" {
    # 双通道模型的核心语义：▶1 ◆1 说的可能就是同一个 pane ——
    # 一个 agent 在跑，同时有一条通知等你处理。两组**互不排斥**。
    run whistle_count_states <<'EOF'
%1|done|done|running|在跑
EOF
    assert_eq "$output" '1|0|1|0|0'
}

@test "count_states: 活动通道的 running 不计入通知计数" {
    run whistle_count_states <<'EOF'
%1|running||running|在跑
%2|running||running|在跑
EOF
    assert_eq "$output" '2|0|0|0|0'
}

@test "count_states: 空输入全是 0" {
    run whistle_count_states </dev/null
    assert_eq "$output" '0|0|0|0|0'
}

@test "count_states: 跳过空状态与格式错误的行" {
    run whistle_count_states <<'EOF'
garbage
%1||||
%2|||消息误读探针
%3||banana||
%4||done||
%5|||idle||
EOF
    assert_eq "$output" '0|1|1|0|0'
}

@test "count_states: 菜单那份 9 列布局也能数" {
    # 菜单用的推导输出有 5 列前导（session|wid|wname|widx|pane_id），
    # 计数要按 pane id 那一列定位，不能写死列号。
    run whistle_count_states <<'EOF'
s|w1|wn|1|%1|running||running|在跑|
s|w1|wn|1|%2|done|done||做完了
EOF
    assert_eq "$output" '1|0|1|0|0'
}
