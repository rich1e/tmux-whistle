#!/usr/bin/env bats
# shellcheck shell=bash
#
# L3 端到端：把构造的 Codex hook JSON 喂进 hooks/codex.sh，
# 断言退出码、stdout 为空、以及写出的 tmux 状态。
#
# Codex 与 Claude 的事件集不同：
#   · 权限等待是 PermissionRequest，不是 Notification
#   · 子 agent 用 SubagentStart / SubagentStop
#   · 用户打断是 Interrupt（不会有 Stop 收尾）

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  export TMUX_PANE
  TMUX_PANE=$(wt display -p -t w1 '#{pane_id}')
  export WHISTLE_TMUX_SOCKET
  wt set -g @whistle_codex_pane_mode legacy
}

teardown() {
  wt_stop
}

HOOK="$WHISTLE_ROOT/hooks/codex.sh"

feed() {
  run env TMUX_PANE="$TMUX_PANE" "$HOOK"
  assert_eq "$status" 0
  assert_eq "$output" ''
}

feed_bound() {
  local target="$TMUX_PANE"
  run env TMUX_PANE='%999999' WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_CODEX_BINDING=v1 WHISTLE_CODEX_PANE="$target" \
    WHISTLE_CODEX_CLIENT='test-client' "$HOOK"
  assert_eq "$status" 0
  assert_eq "$output" ''
}

pane_act() { optp @whistle "$TMUX_PANE"; }
pane_act_at() { optp @whistle "$1"; }
pane_eff() { optp @whistle_eff "$TMUX_PANE"; }
pane_notice() { optp @whistle_notice "$TMUX_PANE"; }
pane_notice_msg() { optp @whistle_notice_msg "$TMUX_PANE"; }
pane_notice_body() { optp @whistle_notice_body "$TMUX_PANE"; }
pane_sub() { optp @whistle_sub "$TMUX_PANE"; }
pane_cx_quiet() { optp @whistle_cx_quiet "$TMUX_PANE"; }

seed_notice() {
  TMUX_PANE="$TMUX_PANE" "$WHISTLE_ROOT/bin/tmux-whistle" "$1" "${2:-}" > /dev/null
}

feed_os_spy() {
  local bindir="$BATS_TEST_TMPDIR/os-bin"
  local calls="$BATS_TEST_TMPDIR/os-calls"
  mkdir -p "$bindir"
  cat > "$bindir/terminal-notifier" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WHISTLE_OS_SPY"
exit 0
EOF
  chmod +x "$bindir/terminal-notifier"

  run env TMUX_PANE="$TMUX_PANE" PATH="$bindir:$PATH" \
    WHISTLE_OS_SPY="$calls" "$HOOK"
  assert_eq "$status" 0
  assert_eq "$output" ''
}

# -- SessionStart / UserPromptSubmit ---------------------------------------

@test "codex: PaneBinding 优先于 daemon 里陈旧的 TMUX_PANE" {
  local target="$TMUX_PANE"
  feed_bound <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"bound-1","prompt":"在正确的 pane 里运行"}
EOF
  assert_eq "$(pane_act_at "$target")" 'running'
  assert_eq "$(optp @whistle '%999999')" ''
}

@test "codex: 两个 pane 的 Codex session 独立上报" {
  local p1="$TMUX_PANE"
  local p2
  p2=$(wt split-window -d -P -F '#{pane_id}' -t w1)

  run env TMUX_PANE='%999999' WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_CODEX_BINDING=v1 WHISTLE_CODEX_PANE="$p1" \
    WHISTLE_CODEX_CLIENT='client-1' "$HOOK" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"pane-1","prompt":"pane 1"}
EOF
  run env TMUX_PANE='%999999' WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_CODEX_BINDING=v1 WHISTLE_CODEX_PANE="$p2" \
    WHISTLE_CODEX_CLIENT='client-2' "$HOOK" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"pane-2","prompt":"pane 2"}
EOF
  assert_eq "$(pane_act_at "$p1")" 'running'
  assert_eq "$(pane_act_at "$p2")" 'running'

  run env TMUX_PANE='%999999' WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_CODEX_BINDING=v1 WHISTLE_CODEX_PANE="$p1" \
    WHISTLE_CODEX_CLIENT='client-1' "$HOOK" <<'EOF'
{"hook_event_name":"Stop","session_id":"pane-1","last_assistant_message":"pane 1 done"}
EOF
  assert_eq "$(pane_act_at "$p1")" 'idle'
  assert_eq "$(optp @whistle_notice "$p1")" 'done'
  assert_eq "$(pane_act_at "$p2")" 'running'
  assert_eq "$(optp @whistle_notice "$p2")" ''
}

@test "codex: strict 模式缺少 PaneBinding 时不写任何状态" {
  wt set -g -u @whistle_codex_pane_mode
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"unbound-1","prompt":"不应写入"}
EOF
  assert_eq "$(pane_act)" ''
}

@test "codex: 无效 PaneBinding fail closed，不回退到 TMUX_PANE" {
  run env TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    WHISTLE_CODEX_BINDING=v1 WHISTLE_CODEX_PANE='%999999' \
    WHISTLE_CODEX_CLIENT='broken-client' "$HOOK" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"broken-1","prompt":"不应写入"}
EOF
  assert_eq "$status" 0
  assert_eq "$output" ''
  assert_eq "$(pane_act)" ''
}

@test "codex: legacy 模式允许无 binding 的旧启动方式" {
  wt set -g @whistle_codex_pane_mode legacy
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"legacy-1","prompt":"旧模式"}
EOF
  assert_eq "$(pane_act)" 'running'
}

@test "codex: 同 pane 多 session 时单个 Stop 不覆盖仍在运行的 session" {
  feed_bound <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"任务一"}
EOF
  feed_bound <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s2","prompt":"任务二"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed_bound <<'EOF'
{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"任务一完成"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'done'

  "$WHISTLE_ROOT/bin/tmux-whistle" --read-pane "$TMUX_PANE" > /dev/null
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_act)" 'running'

  feed_bound <<'EOF'
{"hook_event_name":"Stop","session_id":"s2","last_assistant_message":"任务二完成"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'
}

@test "codex: 同 pane 多 session 时 SessionEnd 不写 gone 直到最后一个结束" {
  feed_bound <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"任务一"}
EOF
  feed_bound <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s2","prompt":"任务二"}
EOF

  feed_bound <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other","session_id":"s1"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed_bound <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other","session_id":"s2"}
EOF
  assert_eq "$(pane_act)" 'gone'
  assert_eq "$(optp @whistle_cx_running "$TMUX_PANE")" ''
  assert_eq "$(optp @whistle_cx_idle "$TMUX_PANE")" ''
}

@test "codex: 并发 subagent 停一个后仍保持 running" {
  feed_bound <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"worker"}
EOF
  feed_bound <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"a2","agent_type":"worker"}
EOF
  assert_eq "$(pane_eff)" 'running'

  feed_bound <<'EOF'
{"hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"worker"}
EOF
  assert_eq "$(pane_eff)" 'running'

  feed_bound <<'EOF'
{"hook_event_name":"SubagentStop","agent_id":"a2","agent_type":"worker"}
EOF
  assert_eq "$(pane_eff)" ''
}

@test "codex: SessionStart startup → idle；stdout 为空" {
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup","session_id":"s1"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(optp @whistle_src "$TMUX_PANE")" 'hook'
}

@test "codex: SessionStart 清掉上一会话残留的子 agent 标记" {
  feed <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"old","agent_type":"worker"}
EOF
  [ -n "$(pane_sub)" ]

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"resume"}
EOF
  assert_eq "$(pane_sub)" ''
  assert_eq "$(pane_act)" 'idle'
}

@test "codex: SessionStart fork 不覆盖父会话的活动态与未读通知" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"parent","prompt":"父会话在跑"}
EOF
  seed_notice 'done' '父会话待读'
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice_msg)" '父会话待读'

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"fork","session_id":"summary-1"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '父会话待读'
}

@test "codex: 用户 fork 的首个真实 UserPromptSubmit 仍点亮 running" {
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"fork","session_id":"user-fork"}
EOF
  assert_eq "$(pane_act)" ''

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"user-fork","prompt":"继续修改代码"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_cx_quiet)" ''
}

@test "codex: SessionStart compact 不打断正在跑的回合" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"开始干活"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"compact"}
EOF
  assert_eq "$(pane_act)" 'running'
}

@test "codex: UserPromptSubmit → running，并清掉上一轮未读通知" {
  seed_notice 'done' '上一轮完成'
  assert_eq "$(pane_notice)" 'done'

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"继续"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" ''
}

@test "codex: 内部摘要会话的 Stop 不顶掉父通知、不发系统通知" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"parent","prompt":"父会话在跑"}
EOF
  seed_notice 'done' '父会话待读'
  wt set -g @whistle_os on

  feed_os_spy <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"summary-1",
 "prompt":"Context: This summary will be shown in a list to help users and Claude choose which conversations are relevant.\nYou are running in an ephemeral Codex fork."}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '父会话待读'
  assert_eq "$(pane_cx_quiet)" 'summary-1'

  feed_os_spy <<'EOF'
{"hook_event_name":"Stop","session_id":"summary-1",
 "last_assistant_message":"<summary>内部摘要完成</summary>"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '父会话待读'
  [ ! -e "$BATS_TEST_TMPDIR/os-calls" ]
}

@test "codex: 内部摘要会话的 SessionEnd 不把父会话写成 gone" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"parent","prompt":"父会话在跑"}
EOF
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"summary-1",
 "prompt":"Context: This summary will be shown in a list to help users and Claude choose which conversations are relevant.\nYou are running in an ephemeral Codex fork."}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other","session_id":"summary-1"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_cx_quiet)" ''
}

@test "codex: quiet id 不影响同一 pane 里的其它 Codex session" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"summary-1",
 "prompt":"Context: This summary will be shown in a list to help users and Claude choose which conversations are relevant.\nYou are running in an ephemeral Codex fork."}
EOF

  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"real-1",
 "last_assistant_message":"真实会话完成"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '真实会话完成'
}

@test "codex: 连续内部摘要 fork 结束后 quiet id 不残留" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"parent","prompt":"父会话在跑"}
EOF

  for i in 1 2 3; do
    feed <<EOF
{"hook_event_name":"SessionStart","source":"fork","session_id":"summary-$i"}
EOF
    feed <<EOF
{"hook_event_name":"UserPromptSubmit","session_id":"summary-$i",
 "prompt":"Context: This summary will be shown in a list to help users and Claude choose which conversations are relevant.\n摘要 $i"}
EOF
    feed <<EOF
{"hook_event_name":"Stop","session_id":"summary-$i","last_assistant_message":"<summary>$i</summary>"}
EOF
    feed <<EOF
{"hook_event_name":"SessionEnd","reason":"other","session_id":"summary-$i"}
EOF
  done

  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_cx_quiet)" ''
}

# -- PermissionRequest / PostToolUse --------------------------------------

@test "codex: PermissionRequest 用 tool_input.description 写即时 wait" {
  feed <<'EOF'
{"hook_event_name":"PermissionRequest","tool_name":"Bash",
 "tool_input":{"command":"rm -rf build","description":"删除构建目录"}}
EOF
  assert_eq "$(pane_notice)" 'wait'
  assert_eq "$(pane_notice_msg)" '删除构建目录'
  assert_eq "$(pane_notice_body)" '删除构建目录'
}

@test "codex: PermissionRequest 没有 description 时退回命令首行" {
  feed <<'EOF'
{"hook_event_name":"PermissionRequest","tool_name":"Bash",
 "tool_input":{"command":"npm test\n--watch"}}
EOF
  assert_eq "$(pane_notice)" 'wait'
  assert_eq "$(pane_notice_msg)" 'npm test'
}

@test "codex: PermissionRequest 只有一个 tool_name 时也能说明在等什么" {
  feed <<'EOF'
{"hook_event_name":"PermissionRequest","tool_name":"mcp__fs__write"}
EOF
  assert_eq "$(pane_notice)" 'wait'
  assert_eq "$(pane_notice_msg)" '需要批准: mcp__fs__write'
}

@test "codex: PostToolUse 清掉 wait，但绝不动活动通道" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"执行"}
EOF
  feed <<'EOF'
{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make"}}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'wait'

  feed <<'EOF'
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"exit_code":0}}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" ''
}

@test "codex: PostToolUse 不误清已完成通知" {
  seed_notice 'done' '做完了'

  feed <<'EOF'
{"hook_event_name":"PostToolUse","tool_name":"Bash"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '做完了'
}

# -- 子 agent --------------------------------------------------------------

@test "codex: SubagentStart 只写标记，推导层把活动态合成 running" {
  feed <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"explorer"}
EOF
  assert_eq "$(pane_act)" ''
  [ -n "$(pane_sub)" ]
  assert_eq "$(pane_eff)" 'running'
}

@test "codex: SubagentStop 只清标记，不把主 agent 写成 idle" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"主 agent 在跑"}
EOF
  feed <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"explorer"}
EOF
  feed <<'EOF'
{"hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"explorer",
 "last_assistant_message":"子任务完成"}
EOF

  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_sub)" ''
  assert_eq "$(pane_notice)" ''
}

@test "codex: Stop 与子 agent 重叠时先 done，读掉后回到 running，结束后 idle" {
  feed <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"worker"}
EOF
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"主回合结束"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_eff)" 'done'

  "$WHISTLE_ROOT/bin/tmux-whistle" --read-pane "$TMUX_PANE" > /dev/null
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_eff)" 'running'

  feed <<'EOF'
{"hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"worker"}
EOF
  assert_eq "$(pane_sub)" ''
  assert_eq "$(pane_eff)" 'idle'
}

# -- Stop ------------------------------------------------------------------

@test "codex: Stop → 活动 idle + 通知 done，消息取首行、全文进正文" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1",
 "last_assistant_message":"实现完成：新增 Codex hook\n细节都在这里"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '实现完成：新增 Codex hook'
  assert_eq "$(pane_notice_body)" '实现完成：新增 Codex hook 细节都在这里'
  assert_eq "$(optp @whistle_src "$TMUX_PANE")" 'hook'
}

@test "codex: Stop 缺消息时仍写 done，且不残留上一轮正文" {
  seed_notice 'done' '旧正文'
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" ''
  assert_eq "$(pane_notice_body)" ''
}

@test "codex: Stop 消息里的 format 注入串被消毒" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"#{?window_active,EVIL,x}"}
EOF
  local m
  m=$(pane_notice_msg)
  assert_not_contains "$m" '#'
  assert_not_contains "$m" '{'
}

# -- Interrupt / SessionEnd ------------------------------------------------

@test "codex: Interrupt 收掉 running，并清掉未解决的 wait" {
  feed <<'EOF'
{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"worker"}
EOF
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"执行"}
EOF
  feed <<'EOF'
{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make"}}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'wait'

  feed <<'EOF'
{"hook_event_name":"Interrupt","turn_id":"t1"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_sub)" ''
}

@test "codex: SessionEnd → gone，未读通知保留" {
  seed_notice wait '要你确认'

  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other","session_id":"s1"}
EOF
  assert_eq "$(pane_act)" 'gone'
  assert_eq "$(pane_notice)" 'wait'
  assert_eq "$(pane_eff)" 'wait'
}

# -- 容错与日志 ------------------------------------------------------------

@test "codex: 畸形 JSON 不报错（hook 必须恒成功）" {
  feed <<'EOF'
{not-json
EOF
}

@test "codex: debug 日志带 agent=codex 且能看见事件名" {
  wt set -g @whistle_debug on
  local log="$BATS_TEST_TMPDIR/hooks.log"
  : > "$log"

  run env TMUX_PANE="$TMUX_PANE" WHISTLE_HOOK_LOG="$log" "$HOOK" <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"完成"}
EOF
  assert_eq "$status" 0
  assert_contains "$(cat "$log")" 'agent=codex'
  assert_contains "$(cat "$log")" 'hook_event_name=Stop'
}
