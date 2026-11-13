#!/usr/bin/env bats
# shellcheck shell=bash
# doctor 的 terminal-notifier 诊断：不能只检查命令是否存在。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  wt set -g @whistle_os on
}

teardown() {
  wt_stop
}

@test "doctor: terminal-notifier 3.x 执行 diagnose 并展示授权结果" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 3.1.0.\n'
  exit 0
fi
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/tn.args"
printf 'authorization       authorized\n'
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_eq "$(cat "$BATS_TEST_TMPDIR/tn.args")" '-diagnose'
  assert_contains "$output" 'authorization       authorized'
}

@test "doctor: diagnose rc0 只声明已授权，仍原样列出其它投递问题" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 3.1.0.\n'
  exit 0
fi
printf 'authorization       authorized\n'
printf 'alert style         banners only; alerts recommended\n'
exit 0
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" 'terminal-notifier 已授权（其它投递设置见上方诊断）'
  assert_contains "$output" 'alerts recommended'
  assert_not_contains "$output" 'terminal-notifier 诊断通过'
}

@test "doctor: 旧版 terminal-notifier 提示升级而不是误报未授权" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 2.0.0.\n'
  exit 0
fi
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/tn.unexpected"
exit 99
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" '升级'
  [ ! -e "$BATS_TEST_TMPDIR/tn.unexpected" ]
}

@test "doctor: diagnose 未授权时展示结果但不影响其它检查" {
  cat > "$FAKE_BIN/terminal-notifier" << EOF
#!/bin/sh
if [ "\${1:-}" = '-version' ]; then
  printf 'terminal-notifier 3.1.0.\n'
  exit 0
fi
printf 'authorization       denied\n'
exit 3
EOF
  chmod +x "$FAKE_BIN/terminal-notifier"

  run env PATH="$FAKE_BIN:$PATH" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" 'authorization       denied'
  assert_contains "$output" '系统设置 → 通知 → terminal-notifier'
  assert_contains "$output" '已读钩子'
}

# -- Claude Code hooks 明细（逐事件展开，方便排查）--------------------------
#
# 这一节的价值在于「能看出具体哪一条不对」。只报「已配置」在排查时没有用：
# 路径过期、matcher 缺项、SessionEnd 被改成 async 都不报错，只是行为不对。

# 写一份 settings.json：用当前仓库的 hook 路径，事件与 matcher 按 install-hooks 的规格。
write_settings() {
  local path="$1" cmd="$2" notify_matcher="$3" session_end_async="${4:-0}" omit="${5:-}"
  HOOK_CMD="$cmd" NOTIFY_MATCHER="$notify_matcher" \
    SESSION_END_ASYNC="$session_end_async" OMIT="$omit" \
    python3 - "$path" << 'PY'
import json, os, sys

path = os.environ["HOOK_CMD"].replace("", "")
cmd = os.environ["HOOK_CMD"]
matcher = os.environ["NOTIFY_MATCHER"]
se_async = os.environ["SESSION_END_ASYNC"] == "1"
omit = set(x for x in os.environ["OMIT"].split(",") if x)

events = ["Stop", "StopFailure", "PreToolUse", "SubagentStop",
          "Notification", "SessionStart", "UserPromptSubmit", "SessionEnd"]
hooks = {}
for ev in events:
    if ev in omit:
        continue
    hook = {"type": "command", "command": cmd}
    if ev == "SessionEnd":
        if se_async:
            hook["async"] = True
    else:
        hook["async"] = True
    entry = {"hooks": [hook]}
    if ev == "Notification":
        entry["matcher"] = matcher
    hooks[ev] = [entry]

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"hooks": hooks}, f, ensure_ascii=False, indent=2)
PY
}

OK_MATCHER='permission_prompt|agent_completed|idle_prompt'

@test "doctor: 逐事件列出 Claude Code 订阅（含 async 与 matcher）" {
  local s="$BATS_TEST_TMPDIR/settings.json"
  write_settings "$s" "$WHISTLE_ROOT/hooks/claude-code.sh" "$OK_MATCHER"

  run env CLAUDE_SETTINGS="$s" "$CLI" doctor

  assert_contains "$output" '8/8 个事件已订阅'
  assert_contains "$output" 'Stop             async'
  assert_contains "$output" 'Notification     async matcher='
  assert_contains "$output" 'idle_prompt'
  # SessionEnd 必须是同步 —— 否则退出时清不掉
  assert_contains "$output" 'SessionEnd       sync'
  assert_not_contains "$output" '命令指向'
}

@test "doctor: Notification 的 matcher 缺 idle_prompt 时告警" {
  local s="$BATS_TEST_TMPDIR/settings.json"
  write_settings "$s" "$WHISTLE_ROOT/hooks/claude-code.sh" 'permission_prompt|agent_completed'

  run env CLAUDE_SETTINGS="$s" "$CLI" doctor

  assert_contains "$output" 'matcher 少了 idle_prompt'
}

@test "doctor: SessionEnd 被改成 async 时报错（会留灭不掉的 ▶）" {
  local s="$BATS_TEST_TMPDIR/settings.json"
  write_settings "$s" "$WHISTLE_ROOT/hooks/claude-code.sh" "$OK_MATCHER" 1

  run env CLAUDE_SETTINGS="$s" "$CLI" doctor

  assert_contains "$output" 'SessionEnd 是 async'
  assert_eq "$status" 1
}

@test "doctor: 命令路径指向别处时提示「改了这边不会生效」" {
  local s="$BATS_TEST_TMPDIR/settings.json"
  # 路径里必须含 tmux-whistle —— 那正是 install-hooks 用来识别「自己的条目」的
  # 标记。不含标记的 hook 会被当成别人的，doctor 报「缺事件」而不是「路径过期」。
  write_settings "$s" "/tmp/tmux-whistle-old/hooks/claude-code.sh" "$OK_MATCHER"

  run env CLAUDE_SETTINGS="$s" "$CLI" doctor

  assert_contains "$output" '命令指向 /tmp/tmux-whistle-old/hooks/claude-code.sh'
  assert_contains "$output" '改了这边不会生效'
}

@test "doctor: 缺事件时点名缺了哪些" {
  local s="$BATS_TEST_TMPDIR/settings.json"
  write_settings "$s" "$WHISTLE_ROOT/hooks/claude-code.sh" "$OK_MATCHER" 0 'StopFailure,SubagentStop'

  run env CLAUDE_SETTINGS="$s" "$CLI" doctor

  assert_contains "$output" '缺 2 个事件'
  assert_contains "$output" 'StopFailure'
  assert_contains "$output" 'SubagentStop'
}

@test "doctor: 完全没有 hooks 时提示跑 install-hooks" {
  local s="$BATS_TEST_TMPDIR/settings.json"
  printf '{"hooks":{}}\n' > "$s"

  run env CLAUDE_SETTINGS="$s" "$CLI" doctor

  assert_contains "$output" '缺 8 个事件'
  assert_contains "$output" 'install-hooks'
}
