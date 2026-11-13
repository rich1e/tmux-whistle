#!/usr/bin/env bats
# shellcheck shell=bash
#
# L3 端到端：把构造的事件 JSON 喂进 hooks/opencode.sh，断言写出的 tmux 状态。
#
# 与 test/e2e/claude_hook.bats 同构，差别只在于「pane 怎么定位」：
#   Claude Code  hook 进程在 pane 进程树里，靠继承的 TMUX_PANE
#   OpenCode     插件在 TUI 进程里，TMUX_PANE 由 TUI 显式传给子进程
# 两者在本测试里都表现为「环境里有 TMUX_PANE」，所以桩子是同一个。
#
# 本文件重点守「真源该是什么」：不看中间过程，只看最终的 @whistle /
# @whistle_notice —— 双通道正交最容易在集成层被悄悄破坏。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX TMUX_SOCKET
  export TMUX_PANE
  TMUX_PANE=$(wt display -p -t w1 '#{pane_id}')
  export WHISTLE_TMUX_SOCKET
  WHISTLE_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export WHISTLE_ROOT
}

teardown() {
  wt_stop
}

HOOK="$WHISTLE_ROOT/hooks/opencode.sh"

# 喂一个事件；断言退出码 0 且 stdout 为空（这条链的硬约定）
feed() {
  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$output" = '' ]
}

activity() {
  wt show -pqv -t "$TMUX_PANE" @whistle
}

notice() {
  wt show -pqv -t "$TMUX_PANE" @whistle_notice
}

# -- 活动通道 ---------------------------------------------------------------

@test "oc-e2e: execution.started 点亮活动 running" {
  echo '{"event":"session.execution.started","sessionID":"s1","message":"修一下 bug"}' | feed
  [ "$(activity)" = "running" ]
  # 点亮 running 不该顺手写通知
  [ -z "$(notice)" ]
}

@test "oc-e2e: execution.succeeded 写 idle + done（双通道同时动）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"做完了"}' | feed
  [ "$(activity)" = "idle" ]
  [ "$(notice)" = "done" ]
}

@test "oc-e2e: execution.failed 写 idle + error" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.execution.failed","sessionID":"s1","message":"API Error: Rate limit"}' | feed
  [ "$(activity)" = "idle" ]
  [ "$(notice)" = "error" ]
}

@test "oc-e2e: interrupted=shutdown 写 gone" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.execution.interrupted","sessionID":"s1","reason":"shutdown"}' | feed
  [ "$(activity)" = "gone" ]
}

@test "oc-e2e: interrupted=superseded 不动活动通道（正在跑新一轮）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  [ "$(activity)" = "running" ]
  echo '{"event":"session.execution.interrupted","sessionID":"s1","reason":"superseded"}' | feed
  [ "$(activity)" = "running" ]
}

@test "oc-e2e: interrupted=user 回落 idle" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.execution.interrupted","sessionID":"s1","reason":"user"}' | feed
  [ "$(activity)" = "idle" ]
}

# -- 通知通道 ---------------------------------------------------------------

@test "oc-e2e: permission.asked 写 wait 且不动活动通道" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"permission.asked","sessionID":"s1","message":"bash: rm -rf"}' | feed
  [ "$(activity)" = "running" ]
  [ "$(notice)" = "wait" ]
}

@test "oc-e2e: permission.replied=once 清通知但保留 running" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"permission.asked","sessionID":"s1","message":"x"}' | feed
  [ "$(notice)" = "wait" ]
  echo '{"event":"permission.replied","sessionID":"s1","reply":"once"}' | feed
  # 已读只清通知通道 —— 抹掉活动态后就再没有事件能点回来了
  [ -z "$(notice)" ]
  [ "$(activity)" = "running" ]
}

@test "oc-e2e: permission.replied=reject 收尾活动态（否则留永不灭的 ▶）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"permission.asked","sessionID":"s1","message":"x"}' | feed
  echo '{"event":"permission.replied","sessionID":"s1","reply":"reject"}' | feed
  [ -z "$(notice)" ]
  [ "$(activity)" = "idle" ]
}

# -- 后台 shell 的门控（TODO-18 的现场）-------------------------------------

@test "oc-e2e: 后台在飞时 succeeded 不写 done，活动保持 running" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.shell.started","sessionID":"s1","shellID":"sh1","shellStatus":"running"}' | feed
  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"这一轮完了但后台还在跑"}' | feed

  # done(3) > running(2)：报了 done 就会把后台的 ▶ 盖成 ◆
  [ -z "$(notice)" ]
  [ "$(activity)" = "running" ]
}

@test "oc-e2e: 后台结束后那一轮 succeeded 才写 done" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.shell.started","sessionID":"s1","shellID":"sh1","shellStatus":"running"}' | feed
  echo '{"event":"session.execution.succeeded","sessionID":"s1"}' | feed
  [ -z "$(notice)" ]

  # 后台结束 → 集合空 → 下一次 succeeded 才报 done
  echo '{"event":"session.shell.ended","sessionID":"s1","shellID":"sh1","shellStatus":"exited"}' | feed
  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"真做完了"}' | feed
  [ "$(notice)" = "done" ]
  [ "$(activity)" = "idle" ]
}

@test "oc-e2e: 两条 shell 在飞时结束一条还不够（按 id 精确移除）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.shell.started","sessionID":"s1","shellID":"sh1","shellStatus":"running"}' | feed
  echo '{"event":"session.shell.started","sessionID":"s1","shellID":"sh2","shellStatus":"running"}' | feed
  echo '{"event":"session.shell.ended","sessionID":"s1","shellID":"sh1","shellStatus":"exited"}' | feed

  echo '{"event":"session.execution.succeeded","sessionID":"s1"}' | feed
  # 还有 sh2 在飞 → 仍然不能报 done
  [ -z "$(notice)" ]
  [ "$(activity)" = "running" ]
}

@test "oc-e2e: 同一条 shell.started 重复到达不会把计数加成两条" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.shell.started","sessionID":"s1","shellID":"sh1","shellStatus":"running"}' | feed
  echo '{"event":"session.shell.started","sessionID":"s1","shellID":"sh1","shellStatus":"running"}' | feed
  echo '{"event":"session.shell.ended","sessionID":"s1","shellID":"sh1","shellStatus":"exited"}' | feed

  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"done"}' | feed
  # 幂等：一次 started 就要一次 ended 清掉，重复的 started 不该留下残余
  [ "$(notice)" = "done" ]
}

# -- 子 session -------------------------------------------------------------

@test "oc-e2e: 子 session 的事件不碰活动通道（只清标记层）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  [ "$(activity)" = "running" ]

  # 子 agent 结束 —— 主 agent 通常还在等结果，绝不能把它标成 idle
  echo '{"event":"session.execution.succeeded","sessionID":"s2","child":"1","message":"子任务完成"}' | feed
  [ "$(activity)" = "running" ]
}

# -- 收尾 ------------------------------------------------------------------

@test "oc-e2e: --tui-exit 写 gone（不是清空）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  [ "$(activity)" = "running" ]

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK" --tui-exit
  [ "$status" -eq 0 ]
  [ "$(activity)" = "gone" ]
}

@test "oc-e2e: --tui-exit 不清通知通道（agent 走了不等于你看过）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"完成了"}' | feed
  [ "$(notice)" = "done" ]

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK" --tui-exit
  [ "$status" -eq 0 ]
  [ "$(notice)" = "done" ]
}

@test "oc-e2e: --probe 在 debug 开时写一行自检（R3 的可观测出口）" {
  local probe_log="$BATS_TEST_TMPDIR/probe.log"
  wt set -g @whistle_debug on

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_HOOK_LOG="$probe_log" "$HOOK" --probe
  [ "$status" -eq 0 ]
  [ "$output" = '' ]

  # 没加载 → 这行根本不会出现；加载进 server → TMUX_PANE 会是错的
  grep -q 'event=tui-probe' "$probe_log"
  grep -q "TMUX_PANE=$TMUX_PANE" "$probe_log"
}

@test "oc-e2e: --probe 在 debug 关时不写日志（默认零副作用）" {
  local probe_log="$BATS_TEST_TMPDIR/probe-off.log"
  wt set -g @whistle_debug off

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_HOOK_LOG="$probe_log" "$HOOK" --probe
  [ "$status" -eq 0 ]
  [ ! -f "$probe_log" ]
}

@test "oc-e2e: --probe 不写任何 tmux 状态" {
  wt set -g @whistle_debug on
  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_HOOK_LOG="$BATS_TEST_TMPDIR/p.log" "$HOOK" --probe
  [ "$status" -eq 0 ]
  [ -z "$(activity)" ]
  [ -z "$(notice)" ]
}

@test "oc-e2e: --tui-start 把 gone 推回 idle（重启后要能看见 ◉）" {
  # 上一轮退出的收尾是 gone（rank 0，不显示）。不写 idle 的话，
  # 重启 TUI 后这个 pane 在状态栏上彻底不存在 —— 用户会以为插件没装。
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK" --tui-exit
  [ "$status" -eq 0 ]
  [ "$(activity)" = "gone" ]

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK" --tui-start
  [ "$status" -eq 0 ]
  [ "$(activity)" = "idle" ]
}

@test "oc-e2e: --tui-start 不覆盖已有的 running（热重载不能把干活的打回空闲）" {
  echo '{"event":"session.execution.started","sessionID":"s1"}' | feed
  [ "$(activity)" = "running" ]

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK" --tui-start
  [ "$status" -eq 0 ]
  [ "$(activity)" = "running" ]
}

@test "oc-e2e: --tui-start 不碰通知通道（空闲不代表已读）" {
  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"完成"}' | feed
  [ "$(notice)" = "done" ]

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" "$HOOK" --tui-start
  [ "$status" -eq 0 ]
  [ "$(notice)" = "done" ]
}

# -- 健壮性 ----------------------------------------------------------------

@test "oc-e2e: 未知事件不写任何状态" {
  echo '{"event":"some.future.event","sessionID":"s1"}' | feed
  [ -z "$(activity)" ]
  [ -z "$(notice)" ]
}

@test "oc-e2e: 空 stdin 不报错也不写状态" {
  printf '' | feed
  [ -z "$(activity)" ]
}

@test "oc-e2e: 畸形 JSON 不报错（hook 必须恒成功）" {
  printf 'not json at all' | feed
  [ -z "$(activity)" ]
}

@test "oc-e2e: 不在 tmux 里时静默退出（非 tmux 启动的 TUI）" {
  # shellcheck disable=SC2016  # 单引号是刻意的：这段在子 sh 里执行，$1 由它展开
  run env -u TMUX_PANE -u WHISTLE_TMUX_SOCKET -u TMUX -u TMUX_SOCKET \
    sh -c 'echo "{\"event\":\"session.execution.started\"}" | "$1"' _ "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "oc-e2e: 消息进徽章时只取首行" {
  printf '%s\n' '{"event":"session.execution.succeeded","sessionID":"s1","message":"第一行\n第二行"}' | feed
  [ "$(wt show -pqv -t "$TMUX_PANE" @whistle_notice_msg)" = "第一行" ]
}

@test "oc-e2e: 消息里的 format 元字符被消毒（不破坏状态栏）" {
  echo '{"event":"session.execution.succeeded","sessionID":"s1","message":"危险 #{session_name} 之类"}' | feed
  local msg
  msg=$(wt show -pqv -t "$TMUX_PANE" @whistle_notice_msg)
  # whistle_sanitize 会剔掉 # { } |，否则 #{ 会被 tmux 二次展开
  case "$msg" in
  *'#{'*) return 1 ;;
  esac
}
