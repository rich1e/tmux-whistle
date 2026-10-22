#!/usr/bin/env bats
# shellcheck shell=bash
#
# L3 端到端：喂构造的 Claude Code hook JSON 进 hooks/claude-code.sh，
# 断言退出码、stdout 为空、以及写出的 tmux 状态。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  # hook 进程靠 $TMUX_PANE 定位 pane，模拟"Claude Code 跑在这个 pane 里"
  export TMUX_PANE
  TMUX_PANE=$(wt display -p -t w1 '#{pane_id}')
  export WHISTLE_TMUX_SOCKET
  WHISTLE_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export WHISTLE_ROOT
}

teardown() {
  wt_stop
}

HOOK="$WHISTLE_ROOT/hooks/claude-code.sh"

feed() {
  run env TMUX_PANE="$TMUX_PANE" "$HOOK"
  assert_eq "$status" 0
  # Claude Code 会把 stdout 当 JSON 解析，任何输出都会干扰它
  assert_eq "$output" ''
}

# -- Stop ------------------------------------------------------------------

@test "e2e: Stop → done，消息取自 last_assistant_message 首行" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp",
 "last_assistant_message":"重构完成：抽出了 core.sh\n\n其余细节在这里"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'done'
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle_msg)" '重构完成：抽出了 core.sh'
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle_src)" 'hook'
}

@test "e2e: Stop 会连带更新窗口徽章与全局计数" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'done'
  assert_eq "$(opt '@whistle_pending')" '1'
}

@test "e2e: Stop 消息里的 format 注入串被消毒" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"#{?window_active,EVIL,x}"}
EOF
  local m
  m=$(wt show -pqv -t "$TMUX_PANE" @whistle_msg)
  assert_not_contains "$m" '#'
  assert_not_contains "$m" '{'
}

@test "e2e: Stop 缺 last_assistant_message 时也能置状态" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'done'
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle_msg)" ''
}

# -- Notification ----------------------------------------------------------

@test "e2e: permission_prompt → wait（等待下一步）" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt",
 "message":"Claude needs your permission","title":"Permission needed"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'wait'
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle_msg)" 'Claude needs your permission'
}

@test "e2e: agent_needs_input → wait" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"teammate 在问你"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'wait'
}

@test "e2e: agent_completed → done" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_completed","message":"后台任务完成"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'done'
}

@test "e2e: 无关的通知类型被忽略，不污染状态栏" {
  for t in auth_success elicitation_complete quota_auto_resume_fired plugin_notification; do
    feed <<EOF
{"hook_event_name":"Notification","notification_type":"$t","message":"噪音"}
EOF
    assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" ''
  done
}

@test "e2e: 通知类型缺失时不写任何状态" {
  feed <<'EOF'
{"hook_event_name":"Notification","message":"没有类型的通知"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" ''
}

# -- 交互开始 --------------------------------------------------------------

@test "e2e: UserPromptSubmit → running，之前点亮的徽章被压掉" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'done'

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"继续"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'running'
}

@test "e2e: SessionStart → running" {
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'running'
}

# -- 边界 ------------------------------------------------------------------

@test "e2e: 未知事件静默退出" {
  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Bash"}
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" ''
}

@test "e2e: 空 stdin 不报错也不写状态" {
  feed < /dev/null
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" ''
}

@test "e2e: 畸形 JSON 不崩、不写状态" {
  feed <<'EOF'
{not valid json at all
EOF
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" ''
}

@test "e2e: 不在 tmux 内时静默退出（没有 pane 可标记）" {
  run env -u TMUX_PANE -u WHISTLE_TMUX_SOCKET -u TMUX_SOCKET "$HOOK" <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$status" 0
  assert_eq "$output" ''
}

# -- JSON 解析降级 ---------------------------------------------------------

@test "e2e: 无 jq 时 sed 启发式也能取出字段" {
  # 造一个只含 sh 工具的 PATH，强制走 sed 分支
  local shdir="$BATS_TEST_TMPDIR/shonly"
  mkdir -p "$shdir"
  for t in sh cat sed head printf tmux date grep tr cut wc basename dirname; do
    ln -sf "$(command -v "$t")" "$shdir/$t" 2> /dev/null || true
  done

  run env PATH="$shdir" TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    "$HOOK" <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"需要你批准"}
EOF
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle)" 'wait'
  assert_eq "$(wt show -pqv -t "$TMUX_PANE" @whistle_msg)" '需要你批准'
}