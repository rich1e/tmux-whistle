#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1：OpenCode 事件映射的纯函数层（lib/opencode.sh）。
#
# 这一层**不碰 tmux**，所以每条用例都只调函数、断输出。
# 拆分理由见 docs/opencode-integration-plan.md §3.1：
# hooks/opencode.sh 有 `cat` 与 `exit`，source 不了，只能由 L3 测。
#
# 本文件守的核心是三条「一律映射就会错」的地方：
#   1. interrupted 必须按 reason 分派（superseded 不能写 idle）
#   2. permission.replied 的 reject 要收尾（否则留永不灭的 ▶）
#   3. succeeded 在有后台在飞时不能报 done（done 3 > running 2）

load '../test_helper/whistle'

setup() {
  : "${WHISTLE_ROOT:?helper 未加载}"
  # shellcheck source=../../lib/opencode.sh
  source "$WHISTLE_ROOT/lib/opencode.sh"
}

# -- 活动通道 ---------------------------------------------------------------

@test "oc: execution.started 点亮 running（唯一入口之一）" {
  run whistle_oc_actions session.execution.started
  assert_eq "$status" 0
  assert_eq "$output" 'activity:running'
}

@test "oc: tool.called 也点亮 running（覆盖 plan 批准后继续跑）" {
  run whistle_oc_actions session.tool.called
  assert_eq "$output" 'activity:running'
}

@test "oc: execution.succeeded = 活动 idle + 通知 done（且 done 走 guarded）" {
  run whistle_oc_actions session.execution.succeeded
  assert_contains "$output" 'activity:idle'
  assert_contains "$output" 'notice:done-guarded'
}

@test "oc: execution.failed = 活动 idle + 通知 error" {
  run whistle_oc_actions session.execution.failed
  assert_contains "$output" 'activity:idle'
  assert_contains "$output" 'notice:error'
}

# -- interrupted 的 reason 分派（最易踩的一处）------------------------------

@test "oc: interrupted=user 回落 idle（用户按了 Esc，TUI 还在）" {
  run whistle_oc_actions session.execution.interrupted user
  assert_eq "$output" 'activity:idle'
}

@test "oc: interrupted=inactivity 回落 idle（超时中断）" {
  run whistle_oc_actions session.execution.interrupted inactivity
  assert_eq "$output" 'activity:idle'
}

@test "oc: interrupted=shutdown 写 gone（否则留一盏灭不掉的 ◉）" {
  run whistle_oc_actions session.execution.interrupted shutdown
  assert_eq "$output" 'activity:gone'
}

@test "oc: interrupted=superseded 不动活动通道（正在跑新的一轮）" {
  # 这条是关键：写 idle 会把 ▶ 打成 ◉，而下一个事件可能很久才来。
  run whistle_oc_actions session.execution.interrupted superseded
  assert_eq "$output" ''
}

@test "oc: interrupted 未知 reason 兜底 idle（宁可少报不可误报）" {
  run whistle_oc_actions session.execution.interrupted weird-value
  assert_eq "$output" 'activity:idle'
}

# -- 通知通道 ---------------------------------------------------------------

@test "oc: permission.asked 写 wait（即时，不需要 idle_prompt 那 60 秒）" {
  run whistle_oc_actions permission.asked
  assert_eq "$output" 'notice:wait'
}

@test "oc: permission.replied=once 只清通知，不动活动态" {
  run whistle_oc_actions permission.replied "" once
  assert_eq "$output" 'read-notice'
}

@test "oc: permission.replied=always 只清通知，不动活动态" {
  run whistle_oc_actions permission.replied "" always
  assert_eq "$output" 'read-notice'
}

@test "oc: permission.replied=reject 必须收尾活动态（之后可能没有终态事件）" {
  run whistle_oc_actions permission.replied "" reject
  assert_contains "$output" 'read-notice'
  assert_contains "$output" 'activity:idle'
}

# -- 后台 shell -------------------------------------------------------------

@test "oc: shell.started(status=running) 进在飞集合" {
  run whistle_oc_actions session.shell.started "" "" running
  assert_eq "$output" 'shell-add'
}

@test "oc: shell.started 缺 status 也当在飞（保守）" {
  run whistle_oc_actions session.shell.started "" "" ''
  assert_eq "$output" 'shell-add'
}

@test "oc: shell.started(status=exited) 不进集合" {
  run whistle_oc_actions session.shell.started "" "" exited
  assert_eq "$output" ''
}

@test "oc: shell.ended 一律出集合（exited/timeout/killed 都是结束）" {
  for st in exited timeout killed; do
    run whistle_oc_actions session.shell.ended "" "" "$st"
    assert_eq "$output" 'shell-del'
  done
}

# -- 刻意不映射 -------------------------------------------------------------

@test "oc: session.idle 不映射（瞬时信号，持久语义已由 succeeded 覆盖）" {
  run whistle_oc_actions session.idle
  assert_eq "$output" ''
}

@test "oc: retry.scheduled 不映射（不是终态，报 error 是噪音）" {
  run whistle_oc_actions session.retry.scheduled
  assert_eq "$output" ''
}

@test "oc: pty.* 不映射（OpenCode 的终端面板不是 agent 后台命令）" {
  for ev in pty.created pty.updated pty.exited pty.deleted; do
    run whistle_oc_actions "$ev"
    assert_eq "$output" ''
  done
}

@test "oc: 未知事件静默忽略，不猜" {
  run whistle_oc_actions some.future.event
  assert_eq "$output" ''
}

# -- 在飞集合的幂等 ---------------------------------------------------------

@test "oc: set_add 对已存在的 id 幂等（重试不该把计数加两次）" {
  run whistle_oc_set_add "s1 s2" s2
  assert_eq "$output" "s1 s2"
}

@test "oc: set_add 追加新 id" {
  run whistle_oc_set_add "s1" s2
  assert_eq "$output" "s1 s2"
}

@test "oc: set_add 空集合起步" {
  run whistle_oc_set_add "" s1
  assert_eq "$output" "s1"
}

@test "oc: set_del 精确摘掉对应 id，不动别人" {
  run whistle_oc_set_del "s1 s2 s3" s2
  assert_eq "$output" "s1 s3"
}

@test "oc: set_del 不存在的 id 是无操作" {
  run whistle_oc_set_del "s1 s2" nope
  assert_eq "$output" "s1 s2"
}

@test "oc: set_has 空串为假、非空为真" {
  run whistle_oc_set_has ""
  [ "$status" -ne 0 ]
  run whistle_oc_set_has "s1"
  [ "$status" -eq 0 ]
}

@test "oc: set_count 数空格分隔的 id，不受调用方 IFS 影响" {
  run whistle_oc_set_count "a b c"
  assert_eq "$output" "3"

  # 关键回归：hooks 里不要在遍历动作列表时改 IFS，这里钉住「计数不依赖 IFS」。
  local old_ifs=$IFS
  IFS='
'
  run whistle_oc_set_count "a b c"
  IFS=$old_ifs
  assert_eq "$output" "3"
}

@test "oc: bg_title 单数为「1 个任务」、复数为「N 个任务」" {
  run whistle_oc_bg_title 1
  assert_eq "$output" "后台: 1 个任务"
  run whistle_oc_bg_title 3
  assert_eq "$output" "后台: 3 个任务"
}

@test "oc: bg_title 非数字按 0 处理（不输出半个标题）" {
  run whistle_oc_bg_title abc
  assert_eq "$output" ''
}

# -- 子 session 判定 --------------------------------------------------------

@test "oc: child 事件里的活动动作可被识别（调用方据此跳过）" {
  run whistle_oc_action_is_activity activity:idle
  [ "$status" -eq 0 ]
  run whistle_oc_action_is_activity notice:done
  [ "$status" -ne 0 ]
}

@test "oc: notice 动作可被识别" {
  run whistle_oc_action_is_notice notice:wait
  [ "$status" -eq 0 ]
  run whistle_oc_action_is_notice activity:running
  [ "$status" -ne 0 ]
}

@test "oc: done 类动作可被识别（子 session 据此单独走守卫）" {
  run whistle_oc_action_is_done notice:done
  [ "$status" -eq 0 ]
  run whistle_oc_action_is_done notice:done-guarded
  [ "$status" -eq 0 ]
  run whistle_oc_action_is_done notice:wait
  [ "$status" -ne 0 ]
  run whistle_oc_action_is_done activity:idle
  [ "$status" -ne 0 ]
}

@test "oc: 子 session 的 done 文案有兜底（空标题也不能是空串）" {
  run whistle_oc_child_done_msg ''
  assert_eq "$output" '子 agent 完成'
  run whistle_oc_child_done_msg '子任务标题'
  assert_eq "$output" '子任务标题'
}

# -- 消息截断 ---------------------------------------------------------------

@test "oc: first_line 只取首行（徽章只有一行宽度）" {
  run whistle_oc_first_line "第一行
第二行
第三行"
  assert_eq "$output" "第一行"
}

@test "oc: first_line 单行原样返回" {
  run whistle_oc_first_line "只有一行"
  assert_eq "$output" "只有一行"
}

# -- JSON 取值（三级降级）---------------------------------------------------

@test "oc: json_get 取顶层字符串字段" {
  run whistle_oc_json_get '{"event":"session.idle","sessionID":"ses_1"}' event
  assert_eq "$output" "session.idle"
}

@test "oc: json_get 缺字段返回空" {
  run whistle_oc_json_get '{"event":"x"}' nope
  assert_eq "$output" ""
}
