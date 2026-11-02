#!/usr/bin/env bats
# shellcheck shell=bash
#
# 状态读写、窗口聚合、全局计数、清除、列表。
#
# 两条正交通道：活动（@whistle）与通知（@whistle_notice）。
# 本文件守的最要紧的一条是「已读只清通知通道」——
# 以前已读清的是整个 @whistle，于是「在跑 → 空闲」的降级有了执行者。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  # 测试本身可能就跑在真实 tmux pane 里（开发时的常态）。
  # $TMUX_PANE 会让 whistle_resolve_pane 指向真实 server 的 pane，
  # 所以这里清掉，强制走 WHISTLE_TMUX_SOCKET 指向的隔离 server。
  unset TMUX_PANE TMUX
}

teardown() {
  wt_stop
}

pane_of() {
  wt display -p -t w1 '#{pane_id}'
}

# -- 活动通道 ---------------------------------------------------------------

@test "activity_set: 写活动通道的五个 option" {
  run whistle_activity_set running '' manual '在跑'
  assert_eq "$status" 0

  local p
  p=$(pane_of)
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
  assert_eq "$(wt show -pqv -t "$p" @whistle_msg)" '在跑'
  [ -n "$(wt show -pqv -t "$p" @whistle_at)" ]
  assert_eq "$(wt show -pqv -t "$p" @whistle_src)" 'manual'
}

@test "activity_set: 未知状态被拒且不写任何东西" {
  local p
  p=$(pane_of)
  run whistle_activity_set banana '' manual 'x'
  assert_eq "$status" 1
  assert_eq "$(wt show -pqv -t "$p" @whistle)" ''
}

@test "activity_set: 消息落盘前已消毒（KP-3）" {
  whistle_activity_set running '' manual '#{evil}{x}|y'
  local p m
  p=$(pane_of)
  m=$(wt show -pqv -t "$p" @whistle_msg)
  assert_not_contains "$m" '#'
  assert_not_contains "$m" '{'
  assert_not_contains "$m" '}'
  assert_not_contains "$m" '|'
}

@test "activity_set: 绝不碰通知通道" {
  local p
  p=$(pane_of)
  whistle_notice_set 'done' '做完了' '' "$p"
  whistle_activity_set running "$p" manual '在跑'
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" 'done'
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice_msg)" '做完了'
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
}

# -- 通知通道 ---------------------------------------------------------------

@test "notice_set: 写通知通道的四个 option，活动通道不受影响" {
  local p
  p=$(pane_of)
  whistle_activity_set running "$p" manual '在跑'

  run whistle_notice_set 'done' '做完了' '正文在这里'
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" 'done'
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice_msg)" '做完了'
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice_body)" '正文在这里'
  [ -n "$(wt show -pqv -t "$p" @whistle_notice_at)" ]

  # 活动通道一个字节都没动
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
  assert_eq "$(wt show -pqv -t "$p" @whistle_msg)" '在跑'
}

@test "notice_set: 未知状态被拒且不写任何东西" {
  local p
  p=$(pane_of)
  run whistle_notice_set running 'x' ''
  assert_eq "$status" 1
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" ''
}

@test "state_set: 按状态分流到两条通道（兼容入口）" {
  local p
  p=$(pane_of)
  whistle_state_set running '在跑' "$p"
  whistle_state_set 'done' '做完了' "$p"
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" 'done'
}

@test "state_set: 未知状态被拒" {
  run whistle_state_set banana 'x'
  assert_eq "$status" 1
}

# -- 已读路径：只清通知通道 -------------------------------------------------

@test "read: state_clear 只清通知通道，活动通道原样保留" {
  # 这一条守本次的 bug：已读以前清的是整个 @whistle，
  # 于是「在跑 → 空闲」的降级有了执行者 —— 主 agent 明明还在干活，
  # 用户切进窗口读掉一条通知，活动态就被清空，接着被「按进程发现空闲」
  # 判成 idle，徽章从此显示「空闲」，且零报错。
  local p
  p=$(pane_of)
  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"

  whistle_state_clear "$p" > /dev/null

  # 活动通道原样
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
  assert_eq "$(wt show -pqv -t "$p" @whistle_msg)" '在跑'
  # 通知通道被清空
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" ''
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice_msg)" ''
}

@test "read_window: 切进窗口走已读路径，只清通知不动活动态" {
  # 走真实的 whistle_read_window（渲染层）：它按 @whistle_win（有效态）判断
  # 「这个窗口有事等我」。有效态是通知态时才会清 —— 清的是通知通道。
  wt_load status-line
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'

  whistle_read_window "$w"

  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win_notice)" ''
}

@test "read: 读完通知后，正在跑的 agent 不降级成 idle（核心回归）" {
  # whistle_read_pane 在 lib/status-line.sh（渲染层），
  # 它的判据必须看 @whistle_notice 而不是 @whistle ——
  # 否则活动通道里的 running 被当成「不是待处理」，通知永远清不掉。
  wt_load status-line
  local cmd p
  cmd=$(wt display -p -t w1 '#{pane_current_command}')
  wt set -g @whistle_agent_cmds "$cmd"
  p=$(pane_of)

  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_done')" '1'
  assert_eq "$(opt '@whistle_count_idle')" '0'

  whistle_read_pane "$p"

  # 活动态仍是 running —— 不被降级成 idle
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'running'
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_idle')" '0'
  # 通知通道被清空
  assert_eq "$(opt '@whistle_count_done')" '0'
}

# -- 窗口聚合 --------------------------------------------------------------

@test "recompute: 单一 pane 时 window 态跟随它" {
  whistle_state_set "done" '做完了'
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_msg)" '做完了'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '1'
}

@test "recompute: 多 pane 按优先级聚合" {
  wt split-window -t w1
  local p1 p2 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  [ "$p1" != "$p2" ]

  whistle_state_set "running" '在跑' "$p1"
  whistle_state_set "wait" '等你批' "$p2"
  whistle_recompute_window "$w"

  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'wait'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_msg)" '等你批'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '1'
}

@test "recompute: window 态记住胜出状态的 pane id（菜单 select-pane 的依据）" {
  wt split-window -t w1
  local p1 p2 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')

  # p1 是 running、p2 是 wait —— wait 胜出，pane id 必须跟着 p2 走
  whistle_state_set "running" '在跑' "$p1"
  whistle_state_set "wait" '等你批' "$p2"
  whistle_recompute_window "$w"

  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'wait'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_pane)" "$p2"
}

@test "recompute: 窗口通知态与通知消息单独记一份" {
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"
  whistle_recompute_window "$w"

  # 有效态 = 通知（rank 高）
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_msg)" '做完了'
  # 通知态与通知消息
  assert_eq "$(wt show -wv -t "$w" @whistle_win_notice)" 'done'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_notice_msg)" '做完了'
}

@test "recompute: 没有通知时窗口通知态为空" {
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_activity_set running "$(pane_of)" manual '在跑'
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'running'
  assert_eq "$(wt show -wv -t "$w" @whistle_win_notice)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win_notice_msg)" ''
}

@test "recompute: pane 级有效态写进 @whistle_eff（徽章读它）" {
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -pqv -t "$p" @whistle_eff)" 'done'
}

@test "recompute: pane 状态清掉后 @whistle_win_pane 回落为空" {
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_state_set "done" '做完了'
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win_pane)" '%0'

  # 这一条锁住「whistle_state_clear 不必清 @whistle_win_pane」那个决定：
  # 残留一个已失效的 pane id 会让菜单里的 select-pane 报错并中断命令链。
  whistle_state_clear '%0' > /dev/null
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win_pane)" ''
}

@test "recompute: 全空时 window 态为空字符串" {
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '0'
}

@test "recompute: pane 关掉后 window 态会降级（window-pane-changed 的意义）" {
  wt split-window -t w1
  local p2 w
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  [ -n "$p2" ]

  whistle_state_set "done" '做完了' "$p2"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'

  wt kill-pane -t "$p2"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

# -- 全局计数 --------------------------------------------------------------

@test "recompute_global: 五态分布写进 global option" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  wt new-window -d -n w4
  local p1 p2 p3 p4
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  p4=$(wt display -p -t w4 '#{pane_id}')
  whistle_state_set "running" '' "$p1"
  whistle_state_set "idle" '' "$p4"
  whistle_state_set "done" 'a' "$p2"
  whistle_state_set "error" 'b' "$p3"

  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_idle')" '1'
  assert_eq "$(opt '@whistle_count_done')" '1'
  assert_eq "$(opt '@whistle_count_wait')" '0'
  assert_eq "$(opt '@whistle_count_error')" '1'
  # idle 与 running 都不算待处理：pending 只有 done + error
  assert_eq "$(opt '@whistle_pending')" '2'
}

@test "recompute_global: 分通道计数 —— 同一 pane 同时 running 与 done 各计一次" {
  # 双通道模型的核心语义：▶1 ◆1 说的可能就是同一个 pane ——
  # 一个 agent 在跑，同时有一条通知等你处理。两组**互不排斥**。
  local p
  p=$(pane_of)
  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"

  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(opt '@whistle_count_done')" '1'
  assert_eq "$(opt '@whistle_pending')" '1'
  assert_eq "$(wt show -pqv -t "$p" @whistle_eff)" 'done'
}

@test "recompute_global: 没上报过但前台跑着 agent 的 pane 算 idle" {
  # 「按进程发现空闲」：测试里 pane 跑的是当前 shell，把它写进 agent 清单
  # 就能触发。真实场景是 resurrect 拉起来的 claude --continue ——
  # 它的 SessionStart 还没送到时，插件对那个 pane 一无所知。
  local cmd
  cmd=$(wt display -p -t w1 '#{pane_current_command}')
  wt set -g @whistle_agent_cmds "$cmd"
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  whistle_state_set "done" 'a' "$p2"

  whistle_recompute_global
  # w1 从没上报过，但前台跑着「agent」→ 算空闲
  # w2 的通知在**通知通道**，活动通道是空的 → 同样被推导成空闲，
  # 但它的 done 通知照旧算待处理（两条通道互不排斥）。
  assert_eq "$(opt '@whistle_count_idle')" '2'
  assert_eq "$(opt '@whistle_count_done')" '1'
}

@test "recompute_window: 没上报过但前台跑着 agent 的窗口，聚合态是 idle" {
  local cmd w
  cmd=$(wt display -p -t w1 '#{pane_current_command}')
  wt set -g @whistle_agent_cmds "$cmd"
  w=$(wt display -p -t w1 '#{window_id}')

  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'idle'
}

@test "recompute_global: 只数待处理状态，running 不算" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')

  whistle_state_set "running" '在跑' "$pa"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_pending')" '0'

  whistle_state_set "done" '好了' "$pb"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_pending')" '1'
}

@test "recompute_global: 跨 session 汇总" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')

  whistle_state_set "done" 'a' "$pa"
  whistle_state_set "wait" 'b' "$pb"
  whistle_state_set "error" 'c' "$pa"
  whistle_recompute_global
  assert_eq "$(opt '@whistle_pending')" '2'
}

# -- 子 agent 标记 ---------------------------------------------------------

@test "sub_set: start → 活动态合成为 running" {
  local p
  p=$(pane_of)
  whistle_sub_set start "$p" > /dev/null
  [ -n "$(wt show -pqv -t "$p" @whistle_sub)" ]

  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(wt show -pqv -t "$p" @whistle_eff)" 'running'
}

@test "sub_set: stop → 标记清空，活动态回落" {
  local p
  p=$(pane_of)
  whistle_sub_set start "$p" > /dev/null
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'

  whistle_sub_set stop "$p" > /dev/null
  assert_eq "$(wt show -pqv -t "$p" @whistle_sub)" ''
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '0'
}

@test "sub_set: 标记过期后活动态回落（TTL 自愈，不永久误报 running）" {
  local p
  p=$(pane_of)
  # 直接写一个已经过期的标记
  wt set -p -t "$p" @whistle_sub 1
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '0'

  # 未来的标记 → 强制 running
  wt set -p -t "$p" @whistle_sub 9999999999
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
}

@test "activity_set idle: 真源存 idle，running 由推导层按标记合成" {
  local p
  p=$(pane_of)
  wt set -p -t "$p" @whistle_sub 9999999999
  whistle_activity_set idle "$p" manual '闲着'

  # 真源只存 agent 自己报的值 —— 绝不把「标记有效」翻译成 running 写进去
  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'idle'

  # 但「这个 pane 还在干活」必须看得见：推导层按标记把它撑成 running
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '1'
  assert_eq "$(wt show -pqv -t "$p" @whistle_eff)" 'running'

  # 标记一清就回落 —— 这正是 2026-11-02 那盏亮了 33 分钟的 ▶ 的回归点：
  # 早先把 running 烤进 @whistle，标记清掉后没有任何事件会再改写它。
  wt set -p -t "$p" @whistle_sub ''
  whistle_recompute_global
  assert_eq "$(opt '@whistle_count_running')" '0'
  assert_eq "$(wt show -pqv -t "$p" @whistle_eff)" 'idle'
}

# -- 清除 ------------------------------------------------------------------

@test "clear: 清单个 pane 并同步清 window 态" {
  whistle_state_set "done" '做完了'
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'

  whistle_state_clear "$(pane_of)" > /dev/null
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "clear_window: 清掉整个窗口内所有待处理 pane" {
  wt split-window -t w1
  local p1 p2 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  [ "$p1" != "$p2" ]

  whistle_state_set "done" 'a' "$p1"
  whistle_state_set "wait" 'b' "$p2"
  whistle_recompute_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '2'

  whistle_clear_window "$w"
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win_count)" '0'
}

@test "clear_window: running 状态不算待处理，不会被 clear 误清" {
  whistle_state_set "running" '还在跑'
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  whistle_clear_window "$w"
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" 'running'
}

@test "clear_all: 清掉全 server 的待处理状态" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')
  whistle_state_set "done" 'a' "$pa"
  whistle_state_set "wait" 'b' "$pb"

  whistle_clear_all
  assert_eq "$(wt show -pqv -t "$pa" @whistle_notice)" ''
  assert_eq "$(wt show -pqv -t "$pb" @whistle_notice)" ''
  assert_eq "$(opt '@whistle_pending')" '0'
}

# -- agent 退出 -------------------------------------------------------------

@test "forget_agent: 活动通道置 gone，通知通道不动" {
  local p
  p=$(pane_of)
  whistle_activity_set running "$p" manual '在跑'
  whistle_notice_set 'done' '做完了' '' "$p"

  whistle_forget_agent "$p" > /dev/null

  assert_eq "$(wt show -pqv -t "$p" @whistle)" 'gone'
  # agent 走了不等于你已经看过那条通知
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" 'done'
}

# -- 查询 ------------------------------------------------------------------

@test "list_lines: 只列出待处理项，running 不出现" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')
  whistle_state_set "running" '在跑' "$pa"
  whistle_state_set "done" '做完了' "$pb"

  run whistle_list_lines
  assert_contains "$output" 'other'
  assert_contains "$output" '做完了'
  assert_not_contains "$output" '在跑'
}

@test "pending_windows: 输出含 window_id 供菜单与 jump 使用" {
  whistle_state_set "done" '做完了'
  run whistle_pending_windows
  assert_contains "$output" '@'
  # 六列：session|window_id|window_name|window_index|state|msg
  assert_eq "$(printf '%s\n' "$output" | awk -F'|' '{print NF}')" '6'
}

# -- agent_windows：菜单要列出「所有有 agent 的窗口」，不只是待处理 --------------

@test "agent_windows: 包含 running，而 pending_windows 不含" {
  whistle_state_set "running" '在跑'

  run whistle_agent_windows
  assert_contains "$output" 'running'
  assert_contains "$output" '在跑'

  run whistle_pending_windows
  assert_eq "$output" ''
}

@test "agent_windows: 从未上报过状态的 pane 不出现" {
  run whistle_agent_windows
  assert_eq "$output" ''
}

@test "agent_windows: 每行带 pane id，菜单据此 select-pane" {
  wt split-window -t w1
  local p1 p2
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  whistle_state_set "running" '在跑' "$p1"
  whistle_state_set "done" '做完了' "$p2"

  run whistle_agent_windows
  # 第 5 列是胜出状态的 pane id（session|window_id|window_name|index|pane|…）
  assert_eq "$(printf '%s\n' "$output" | cut -d'|' -f5)" "$p2"
}

@test "agent_windows: 同窗口多 pane 只出一行，取 rank 最高的状态" {
  # list-panes -a 是 pane 粒度；不去重的话菜单里同一个窗口会出现两次。
  wt split-window -t w1
  local p1 p2
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  whistle_state_set "running" '在跑' "$p1"
  whistle_state_set "done" '做完了' "$p2"

  run whistle_agent_windows
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '1'
  assert_contains "$output" 'done'
  assert_contains "$output" '做完了'
}

@test "conf: 未设置的 option 回落到默认表" {
  run whistle_conf '@whistle_color_done'
  assert_eq "$output" '#af5fff'
  run whistle_conf '@whistle_os'
  assert_eq "$output" 'off'
}

@test "conf: 用户显式设置的值优先于默认表" {
  wt set -g @whistle_os on
  run whistle_conf '@whistle_os'
  assert_eq "$output" 'on'
}

@test "conf: 子 agent 标记的 TTL 默认 1800 秒（用户可配）" {
  run whistle_conf '@whistle_sub_ttl'
  assert_eq "$output" '1800'
}
