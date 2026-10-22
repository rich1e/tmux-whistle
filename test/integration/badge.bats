#!/usr/bin/env bats
# shellcheck shell=bash
#
# KP-1 / KP-2 / KP-4 / KP-5：徽章渲染与幂等注入。
#
# 这三条 KP 在方案里标着"待验证"—— 实测已确认成立（见 KP-1/KP-2/KP-7 的探针实验），
# 这里的测试把它们固化成回归保护。

load '../test_helper/whistle'

setup() {
    wt_start
    wt_fake_omt_format
}

teardown() {
    wt_stop
}

# -- KP-1: #{@whistle} 在 window-status-format 中按窗口解析 --------------------

@test "KP-1: 徽章按窗口各自渲染，而不是所有窗口显示同一个" {
    wt new-window -d -n w2
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "done"
    wt set -w -t w2 @whistle_win "wait"

    run wt_render_windows
    assert_contains "$output" 'w1✔'
    assert_contains "$output" 'w2⏳'
    # 交叉验证：w1 不该出现 wait 的符号，反之亦然
    assert_not_contains "$output" 'w1⏳'
    assert_not_contains "$output" 'w2✔'
}

@test "KP-1: 无状态的窗口不显示任何徽章" {
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    run wt_render_windows
    assert_contains "$output" 'w1▌'
    assert_not_contains "$output" '✔'
}

@test "KP-1: 三种状态各自有对应符号" {
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "error"
    run wt_render_windows
    assert_contains "$output" 'w1✗'
}

@test "KP-1: running 显示 ● 徽章（不是待处理，但要让窗口列表看出有 agent）" {
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "running"
    run wt_render_windows
    assert_contains "$output" 'w1●'
    # running 只亮 ●，不该串到其余三个状态的符号上
    assert_not_contains "$output" '✔'
    assert_not_contains "$output" '⏳'
    assert_not_contains "$output" '✗'
}

@test "KP-1: 四种状态各自渲染自己的符号，互不串台" {
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    for pair in 'done ✔' 'wait ⏳' 'error ✗' 'running ●'; do
        local st="${pair% *}" sym="${pair#* }"
        wt set -w -t w1 @whistle_win "$st"
        run wt_render_windows
        assert_contains "$output" "w1${sym}"
        # 只断言本状态该有的符号：其余三个不该同时出现
        local other
        for other in ✔ ⏳ ✗ ●; do
            [ "$other" = "$sym" ] && continue
            assert_not_contains "$output" "$other"
        done
    done
}

# -- 开关：@whistle_badge ------------------------------------------------------

@test "开关: @whistle_badge off 时不渲染徽章" {
    wt_load core
    wt_load status-line
    wt set -g @whistle_badge off
    whistle_mark_publish
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "done"
    run wt_render_windows
    # 哨兵仍在格式里（幂等注入不受开关影响），但渲染为空
    assert_contains "$output" 'w1'
    assert_not_contains "$output" '✔'
}

@test "开关: @whistle_badge 从 off 改回 on 后徽章恢复" {
    wt_load core
    wt_load status-line
    wt set -g @whistle_badge off
    whistle_mark_publish

    wt set -g @whistle_badge on
    whistle_mark_publish
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "done"
    run wt_render_windows
    assert_contains "$output" 'w1✔'
}

@test "开关: @whistle_badge 只关窗口徽章，全局计数不受影响" {
    wt_load core
    wt_load status-line
    wt set -g @whistle_badge off
    whistle_status_right_publish
    whistle_status_right_patch
    wt set -g @whistle_pending 2

    run opt 'status-right'
    assert_contains "$output" 'whistle_status_right'
}

# -- KP-2: #{E:@whistle_mark} 二次展开保留窗口上下文 -------------------------

@test "KP-2: 经 global option 间接一层后，窗口上下文仍保留" {
    wt new-window -d -n w2
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "done"
    wt set -w -t w2 @whistle_win "error"

    run wt_render_windows
    assert_contains "$output" 'w1✔'
    assert_contains "$output" 'w2✗'
}

@test "KP-2: 徽章内容确实存在 global option 里（改色可不重载配置）" {
    wt_load core
    wt_load status-line
    whistle_mark_publish

    run opt '@whistle_mark'
    assert_contains "$output" '#{@whistle_win}'
    assert_contains "$output" 'done'
    assert_contains "$output" 'wait'
    assert_contains "$output" 'error'
}

@test "KP-2: 徽章 format 的大括号配平（畸形 format 会被 tmux 静默渲染成空）" {
    wt_load core
    wt_load status-line
    whistle_mark_publish

    run opt '@whistle_mark'
    local open close
    open=$(printf '%s' "$output" | tr -cd '{' | wc -c | tr -d ' ')
    close=$(printf '%s' "$output" | tr -cd '}' | wc -c | tr -d ' ')
    assert_eq "$open" "$close"
}

@test "KP-2: 改 @whistle_color_* 后重跑 mark_publish 即生效" {
    wt_load core
    wt_load status-line
    wt set -g @whistle_color_done '#123456'
    whistle_mark_publish

    run opt '@whistle_mark'
    assert_contains "$output" '#123456'
}

# -- KP-4 / KP-5: 幂等注入与插入位置 ------------------------------------------

@test "KP-4: 注入的哨兵恰好出现一次" {
    wt_load core
    wt_load status-line
    whistle_format_patch window-status-format

    run optw 'window-status-format'
    assert_eq "$(count_occurrences "$output" '#{E:@whistle_mark}')" "1"
}

@test "KP-4: 连续 patch 三次仍然是恰好一次（prefix r / tpm install 不叠徽章）" {
    wt_load core
    wt_load status-line
    whistle_format_patch window-status-format
    whistle_format_patch window-status-format
    whistle_format_patch window-status-format

    run optw 'window-status-format'
    assert_eq "$(count_occurrences "$output" '#{E:@whistle_mark}')" "1"
}

@test "KP-4: patch 后渲染结果里也只有一个符号" {
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format
    whistle_format_patch window-status-format

    wt set -w -t w1 @whistle_win "done"
    run wt_render_windows
    assert_contains "$output" 'w1✔'
    assert_not_contains "$output" '✔✔'
}

@test "KP-4: 已注入过时 patch 是幂等空操作，不改内容" {
    wt_load core
    wt_load status-line
    whistle_format_patch window-status-format
    before=$(optw 'window-status-format')

    whistle_format_patch window-status-format
    after=$(optw 'window-status-format')
    assert_eq "$after" "$before"
}

@test "KP-5: 哨兵插在末位分隔符之前，不掉到 chip 外面" {
    wt_load core
    wt_load status-line
    whistle_format_patch window-status-format

    run optw 'window-status-format'
    # 哨兵后面还剩末位分隔符，说明插入位置是"末尾之前"而不是"末尾"
    assert_contains "$output" '#{E:@whistle_mark}▌'
    assert_not_contains "$output" '▌#{E:@whistle_mark}'
}

@test "KP-5: 徽章插在末位分隔符之前，仍在芯片内部" {
    wt_load core
    wt_load status-line
    whistle_format_patch window-status-format

    run optw 'window-status-format'
    # 哨兵紧挨着末位分隔符前面，说明没掉到 chip 外面
    assert_contains "$output" '#{E:@whistle_mark}▌'
    # 且整段仍在窗口内容之后、结尾之前
    assert_contains "$output" '#{window_name}'
}

# -- unpatch ----------------------------------------------------------------

@test "unpatch 移除哨兵且保留其余内容" {
    wt_load core
    wt_load status-line
    whistle_format_patch window-status-format
    whistle_format_unpatch window-status-format

    run optw 'window-status-format'
    assert_not_contains "$output" '#{E:@whistle_mark}'
    assert_contains "$output" '#{window_name}'
}

# -- 图标可配置 --------------------------------------------------------------

@test "图标: 默认各状态符号不变" {
  wt_load core
  wt_load status-line
  whistle_mark_publish
  whistle_format_patch window-status-format

  wt set -w -t w1 @whistle_win "done"
  run wt_render_windows
  assert_contains "$output" 'w1✔'
}

@test "图标: @whistle_icon_done 可改成任意符号" {
  wt_load core
  wt_load status-line
  wt set -g @whistle_icon_done '✓'
  whistle_mark_publish
  whistle_format_patch window-status-format

  wt set -w -t w1 @whistle_win "done"
  run wt_render_windows
  assert_contains "$output" 'w1✓'
  assert_not_contains "$output" '✔'
}

@test "图标: running 也可改成任意符号" {
  wt_load core
  wt_load status-line
  wt set -g @whistle_icon_running '▶'
  whistle_mark_publish
  whistle_format_patch window-status-format

  wt set -w -t w1 @whistle_win "running"
  run wt_render_windows
  assert_contains "$output" 'w1▶'
  assert_not_contains "$output" '●'
}

@test "图标: wait 与 error 也各自可改" {
  wt_load core
  wt_load status-line
  wt set -g @whistle_icon_wait '⏸'
  wt set -g @whistle_icon_error '⚠'
  whistle_mark_publish
  whistle_format_patch window-status-format

  wt set -w -t w1 @whistle_win "wait"
  run wt_render_windows
  assert_contains "$output" 'w1⏸'

  wt set -w -t w1 @whistle_win "error"
  run wt_render_windows
  assert_contains "$output" 'w1⚠'
}

@test "图标: @whistle_icon_pending 改的是全局计数前面的符号" {
  wt_load core
  wt_load status-line
  wt set -g @whistle_icon_pending '●'
  whistle_status_right_publish
  wt set -g status-right ''
  whistle_status_right_patch
  wt set -g @whistle_pending 3

  run wt display -pF '#{E:status-right}'
  assert_contains "$output" '●3'
  assert_not_contains "$output" '🔔'
}

@test "图标: 显式设成空串表示不要图标（区别于未设置）" {
  wt_load core
  wt_load status-line
  # 未设置 → 用默认 ✔
  wt set -w -t w1 @whistle_win "done"
  whistle_mark_publish
  whistle_format_patch window-status-format
  run wt_render_windows
  assert_contains "$output" 'w1✔'

  # 显式空串 → 徽章位置什么都没有
  wt set -g @whistle_icon_done ''
  whistle_mark_publish
  run wt_render_windows
  assert_not_contains "$output" '✔'
  assert_contains "$output" 'w1'
}

@test "图标: 填进 format 特殊字符会被消毒，不破坏渲染" {
  wt_load core
  wt_load status-line
  wt set -g @whistle_icon_done '#{host}'
  whistle_mark_publish
  whistle_format_patch window-status-format

  wt set -w -t w1 @whistle_win "done"
  run wt_render_windows
  # # { } 被剔掉，剩下 host —— 关键是没有被二次展开成主机名
  assert_contains "$output" 'host'
  assert_not_contains "$output" '#{'
}

# -- status-right 的全局计数（跨 session 可见性） ------------------------------

@test "status-right: 幂等注入，连续 patch 只有一处" {
  wt_load core
  wt_load status-line
  wt set -g status-right '%%H:%%M'
  whistle_status_right_patch
  whistle_status_right_patch
  whistle_status_right_patch

  run opt 'status-right'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_status_right}')" "1"
  assert_contains "$output" '%%H:%%M'
}

@test "status-right: 计数插在最前面（左端最显眼）" {
  wt_load core
  wt_load status-line
  wt set -g status-right 'TAIL'
  whistle_status_right_patch

  run opt 'status-right'
  case "$output" in
  '#{E:@whistle_status_right}TAIL') ;;
  *)
    printf '期望以哨兵开头，实际: [%s]\n' "$output" >&2
    return 1
    ;;
  esac
}

@test "status-right: 没有待处理项时什么也不显示" {
  wt_load core
  wt_load status-line
  whistle_status_right_publish
  wt set -g status-right 'X'
  whistle_status_right_patch
  wt set -g @whistle_pending 0

  run wt display -pF '#{E:status-right}'
  assert_not_contains "$output" '🔔'
}

@test "status-right: 有待处理项时显示 🔔N" {
  wt_load core
  wt_load status-line
  whistle_status_right_publish
  wt set -g status-right 'X'
  whistle_status_right_patch
  wt set -g @whistle_pending 3

  run wt display -pF '#{E:status-right}'
  assert_contains "$output" '🔔3'
}

@test "status-right: unpatch 精确还原原值" {
  wt_load core
  wt_load status-line
  wt set -g status-right 'ORIGINAL'
  whistle_status_right_patch
  whistle_status_right_unpatch

  run opt 'status-right'
  assert_eq "$output" 'ORIGINAL'
}

# -- KP-3: 恶意消息不破坏状态栏 ------------------------------------------------

@test "KP-3: 消息含 #{ } 时不进 format，渲染不崩" {
    wt_load core
    wt_load status-line
    whistle_mark_publish
    whistle_format_patch window-status-format

    evil=$(whistle_sanitize '#{?window_active,HI,BYE}')
    assert_not_contains "$evil" '#'
    assert_not_contains "$evil" '{'

    wt set -w -t w1 @whistle_win "done"
    run wt_render_windows
    assert_contains "$output" 'w1✔'
}