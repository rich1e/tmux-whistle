#!/usr/bin/env bats
# shellcheck shell=bash
#
# Codex hooks.json 的幂等 merge。
#
# 用户实测环境里已经有 ping-island 的 6 个 hook，且 Codex 已把信任绑定到
# event/index。我们新增的条目必须**追加**，不能插到前面；否则第三方已信任
# 的条目会因索引变化而失效。

load '../test_helper/whistle'

setup() {
  INSTALLER="$WHISTLE_ROOT/lib/install-codex-hooks.sh"
  HOOKS="$BATS_TEST_TMPDIR/hooks.json"
  export HOOKS

  cat > "$HOOKS" <<'JSON'
{
  "custom": {"keep": true},
  "hooks": {
    "PermissionRequest": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/tmp/ping-island-bridge --source codex"}]}
    ],
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/tmp/ping-island-bridge --source codex"}]}
    ],
    "PostToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/tmp/ping-island-bridge --source codex"}]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/tmp/ping-island-bridge --source codex"}]}
    ],
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/tmp/ping-island-bridge --source codex"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/tmp/ping-island-bridge --source codex"}]}
    ]
  }
}
JSON
}

commands_of() {
  python3 - "$HOOKS" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for entry in data.get("hooks", {}).get(sys.argv[2], []):
    for h in entry.get("hooks", []):
        print(h.get("command", ""))
PY
}

@test "codex install: 别人的 hook 与顶层字段一字不动" {
  run "$INSTALLER" --hooks "$HOOKS"
  assert_eq "$status" 0

  run commands_of Stop
  assert_contains "$output" 'ping-island-bridge'
  assert_contains "$output" 'tmux-whistle'

  python3 - "$HOOKS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["custom"] == {"keep": True}
PY
}

@test "codex install: 装九个事件，只有 PostToolUse 异步" {
  "$INSTALLER" --hooks "$HOOKS"

  python3 - "$HOOKS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
hooks = data["hooks"]
events = ("SessionStart", "UserPromptSubmit", "PermissionRequest",
          "PostToolUse", "SubagentStart", "SubagentStop", "Stop",
          "Interrupt", "SessionEnd")
for event in events:
    ours = [h for e in hooks[event] for h in e["hooks"]
            if "tmux-whistle" in h["command"]]
    assert len(ours) == 1, f"{event} 应恰好有一个我们的 hook，实际 {len(ours)}"
    want_async = event == "PostToolUse"
    assert bool(ours[0].get("async")) is want_async, f"{event} 的 async 应为 {want_async}"
assert "async" not in [h for e in hooks["SessionEnd"] for h in e["hooks"]
                       if "tmux-whistle" in h["command"]][0]
PY
}

@test "codex install: 我们的条目追加在已有条目之后" {
  "$INSTALLER" --hooks "$HOOKS"

  python3 - "$HOOKS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for event in ("SessionStart", "UserPromptSubmit", "PermissionRequest",
              "PostToolUse", "Stop"):
    entries = data["hooks"][event]
    assert "ping-island" in entries[0]["hooks"][0]["command"], event
    assert "tmux-whistle" in entries[-1]["hooks"][0]["command"], event
PY
}

@test "codex install: 重复执行幂等，不会越装越多" {
  "$INSTALLER" --hooks "$HOOKS"
  local first
  first=$(cat "$HOOKS")

  "$INSTALLER" --hooks "$HOOKS"
  "$INSTALLER" --hooks "$HOOKS"

  assert_eq "$(cat "$HOOKS")" "$first"
  run commands_of Stop
  assert_eq "$(printf '%s\n' "$output" | grep -c tmux-whistle)" '1'
}

@test "codex uninstall: 只摘自己的条目，第三方原样保留" {
  "$INSTALLER" --hooks "$HOOKS"
  run "$INSTALLER" --uninstall --hooks "$HOOKS"
  assert_eq "$status" 0

  run commands_of Stop
  assert_not_contains "$output" 'tmux-whistle'
  assert_contains "$output" 'ping-island-bridge'

  run commands_of SessionStart
  assert_not_contains "$output" 'tmux-whistle'
  assert_contains "$output" 'ping-island-bridge'

  python3 - "$HOOKS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["custom"] == {"keep": True}
PY
}

@test "codex uninstall 之后再 install 能装回来" {
  "$INSTALLER" --hooks "$HOOKS"
  "$INSTALLER" --uninstall --hooks "$HOOKS"
  "$INSTALLER" --hooks "$HOOKS"
  run commands_of Stop
  assert_contains "$output" 'tmux-whistle'
}

@test "codex install: 文件不存在时创建最小骨架" {
  local fresh="$BATS_TEST_TMPDIR/nested/new-hooks.json"
  run "$INSTALLER" --hooks "$fresh"
  assert_eq "$status" 0
  [ -f "$fresh" ]
  assert_contains "$(cat "$fresh")" 'tmux-whistle'
}

@test "codex install: 已有 hooks 字段但缺目标事件时补齐" {
  local partial="$BATS_TEST_TMPDIR/partial.json"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}\n' > "$partial"
  run "$INSTALLER" --hooks "$partial"
  assert_eq "$status" 0

  python3 - "$partial" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
for event in ("SessionStart", "UserPromptSubmit", "PermissionRequest",
              "PostToolUse", "SubagentStart", "SubagentStop", "Stop",
              "Interrupt", "SessionEnd"):
    assert event in hooks, f"缺 {event}"
assert any(h["command"] == "x" for e in hooks["Stop"] for h in e["hooks"])
PY
}

@test "codex install: 备份文件在改写之前生成" {
  local before
  before=$(cat "$HOOKS")
  "$INSTALLER" --hooks "$HOOKS"

  local bak
  bak=$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'hooks.json.bak.*' | head -1)
  [ -n "$bak" ]
  assert_eq "$(cat "$bak")" "$before"
}

@test "codex install: hooks.json 是软链时保留软链，写真实目标" {
  local target="$BATS_TEST_TMPDIR/dotfiles-hooks.json"
  local link="$BATS_TEST_TMPDIR/linked-hooks.json"
  cp "$HOOKS" "$target"
  ln -s "$target" "$link"

  run "$INSTALLER" --hooks "$link"
  assert_eq "$status" 0
  [ -L "$link" ]
  assert_contains "$(cat "$target")" 'codex.sh'
}

@test "codex install: --dry-run 不碰磁盘" {
  local before
  before=$(cat "$HOOKS")
  run "$INSTALLER" --dry-run --hooks "$HOOKS"
  assert_eq "$status" 0
  assert_contains "$output" 'tmux-whistle'
  assert_eq "$(cat "$HOOKS")" "$before"

  run bash -c "find '$BATS_TEST_TMPDIR' -maxdepth 1 -name 'hooks.json.bak.*'"
  assert_eq "$status" 0
  assert_eq "$output" ""
}

@test "codex install: 非法 JSON 时拒绝改写" {
  printf '{ not json\n' > "$HOOKS"
  run "$INSTALLER" --hooks "$HOOKS"
  assert_eq "$status" 1
  assert_eq "$(cat "$HOOKS")" '{ not json'
}

@test "codex install: hooks 字段不是对象时拒绝改写" {
  printf '{"hooks":[]}\n' > "$HOOKS"
  run "$INSTALLER" --hooks "$HOOKS"
  assert_eq "$status" 1
  assert_eq "$(cat "$HOOKS")" '{"hooks":[]}'
}

# -- 聚合入口 --------------------------------------------------------------

@test "agent install: 默认同时安装 Claude 与 Codex" {
  local settings="$BATS_TEST_TMPDIR/claude.json"
  printf '{}\n' > "$settings"

  run "$WHISTLE_ROOT/lib/install-agent-hooks.sh" \
    --settings "$settings" --codex-hooks "$HOOKS"
  assert_eq "$status" 0
  assert_contains "$output" 'Claude Code hooks'
  assert_contains "$output" 'Codex hooks'

  assert_contains "$(cat "$settings")" 'claude-code.sh'
  assert_contains "$(cat "$HOOKS")" 'codex.sh'
}

@test "agent install: --claude-only 不创建 Codex hooks.json" {
  local settings="$BATS_TEST_TMPDIR/claude-only.json"
  printf '{}\n' > "$settings"
  local fresh="$BATS_TEST_TMPDIR/codex-should-not-exist.json"

  run "$WHISTLE_ROOT/lib/install-agent-hooks.sh" --claude-only \
    --settings "$settings" --codex-hooks "$fresh"
  assert_eq "$status" 0
  [ ! -e "$fresh" ]
}

@test "agent install: --codex-only 不改 Claude settings.json" {
  local settings="$BATS_TEST_TMPDIR/claude-untouched.json"
  printf '{"keep":true}\n' > "$settings"
  local before
  before=$(cat "$settings")

  run "$WHISTLE_ROOT/lib/install-agent-hooks.sh" --codex-only \
    --settings "$settings" --codex-hooks "$HOOKS"
  assert_eq "$status" 0
  assert_eq "$(cat "$settings")" "$before"
  assert_contains "$(cat "$HOOKS")" 'codex.sh'
}

@test "CLI: install-codex-hooks 只调用 Codex 合并器" {
  run env CODEX_HOOKS="$HOOKS" "$WHISTLE_ROOT/bin/tmux-whistle" install-codex-hooks
  assert_eq "$status" 0
  assert_contains "$output" 'install-codex-hooks: 已写入 9 个事件'
  assert_contains "$(cat "$HOOKS")" 'codex.sh'
}

@test "CLI: install-hooks 默认同时安装 Claude 与 Codex" {
  local settings="$BATS_TEST_TMPDIR/cli-claude.json"
  printf '{}\n' > "$settings"

  run env CLAUDE_SETTINGS="$settings" CODEX_HOOKS="$HOOKS" \
    "$WHISTLE_ROOT/bin/tmux-whistle" install-hooks
  assert_eq "$status" 0
  assert_contains "$output" 'Claude Code hooks'
  assert_contains "$output" 'Codex hooks'
  assert_contains "$(cat "$settings")" 'claude-code.sh'
  assert_contains "$(cat "$HOOKS")" 'codex.sh'
}
