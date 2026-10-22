#!/usr/bin/env bats
# shellcheck shell=bash
#
# KP-12：settings.json 的幂等 merge。
#
# 这是整个插件风险最高的写操作 —— 用户已经有 obsidian-wiki 的 SessionStart / Stop hooks，
# 覆盖它们会直接弄坏别人的东西。所以重点测"别人的条目一字不动"。

load '../test_helper/whistle'

setup() {
  INSTALLER="$WHISTLE_ROOT/lib/install-hooks.sh"
  SETTINGS="$BATS_TEST_TMPDIR/settings.json"
  export SETTINGS

  # 一份贴近真实的 settings.json：已有别人的 hooks，且结构不完全规整
  cat > "$SETTINGS" <<'JSON'
{
  "env": { "FOO": "bar" },
  "permissions": { "allow": ["Bash(git *)"] },
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash wiki-session-recap.sh" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash wiki-stop-capture.sh" }] }
    ]
  },
  "statusLine": { "type": "command", "command": "sh statusline.sh" }
}
JSON
}

jqf() {
  # 在 settings.json 的上下文里求值一个 python 表达式（变量名 d）
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print(v if not isinstance(v, (dict, list)) else json.dumps(v, ensure_ascii=False))
" "$SETTINGS" "$1" 2> /dev/null
}

commands_of() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for entry in data.get("hooks", {}).get(sys.argv[2], []):
    for h in entry.get("hooks", []):
        print(h.get("command", ""))
PY
}

@test "install: 别人的 hook 条目一字不动" {
  run "$INSTALLER" --settings "$SETTINGS"
  assert_eq "$status" 0

  run commands_of Stop
  assert_contains "$output" 'wiki-stop-capture.sh'
  run commands_of SessionStart
  assert_contains "$output" 'wiki-session-recap.sh'
}

@test "install: 其它顶层字段原样保留" {
  "$INSTALLER" --settings "$SETTINGS"
  assert_eq "$(jqf "d['env']['FOO']")" 'bar'
  assert_eq "$(jqf "d['permissions']['allow'][0]")" 'Bash(git *)'
  assert_contains "$(jqf "d['statusLine']['command']")" 'statusline.sh'
}

@test "install: 装上六个事件；除 SessionEnd 外都带 async true" {
  "$INSTALLER" --settings "$SETTINGS"

  python3 - "$SETTINGS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
hooks = data["hooks"]
events = ("Stop", "StopFailure", "Notification", "SessionStart", "UserPromptSubmit", "SessionEnd")
for event in events:
    ours = [h for e in hooks[event] for h in e["hooks"] if "tmux-whistle" in h["command"]]
    assert len(ours) == 1, f"{event} 应恰好有一个我们的 hook，实际 {len(ours)}"
    want_async = event != "SessionEnd"
    assert bool(ours[0].get("async")) is want_async, f"{event} 的 async 应为 {want_async}"
# StopFailure 必须订阅全部错误类型：不能有 matcher 把某些类型挡在外面
sf = [e for e in hooks["StopFailure"] if any("tmux-whistle" in h["command"] for h in e["hooks"])][0]
assert "matcher" not in sf, f"StopFailure 不该设 matcher，实际 {sf.get('matcher')!r}"
PY
}

@test "install: Notification matcher 只订阅相关类型" {
  "$INSTALLER" --settings "$SETTINGS"

  python3 - "$SETTINGS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
entry = [e for e in data["hooks"]["Notification"]
         if any("tmux-whistle" in h["command"] for h in e["hooks"])][0]
m = entry["matcher"]
for want in ("permission_prompt", "agent_needs_input", "agent_completed"):
    assert want in m, f"matcher 缺 {want}"
for unwanted in ("auth_success", "quota_auto_resume_fired", "plugin_notification"):
    assert unwanted not in m, f"matcher 不该含 {unwanted}"
PY
}

@test "install: 重复执行幂等，不会越装越多" {
  "$INSTALLER" --settings "$SETTINGS"
  local first
  first=$(cat "$SETTINGS")

  "$INSTALLER" --settings "$SETTINGS"
  "$INSTALLER" --settings "$SETTINGS"

  assert_eq "$(cat "$SETTINGS")" "$first"
  run commands_of Stop
  assert_eq "$(printf '%s\n' "$output" | grep -c tmux-whistle)" '1'
}

@test "install: 重复执行后别人的条目依然完好" {
  "$INSTALLER" --settings "$SETTINGS"
  "$INSTALLER" --settings "$SETTINGS"
  run commands_of SessionStart
  assert_contains "$output" 'wiki-session-recap.sh'
  assert_contains "$output" 'tmux-whistle'
}

@test "uninstall: 精确摘除我们的条目，别人的留着" {
  "$INSTALLER" --settings "$SETTINGS"
  run "$INSTALLER" --uninstall --settings "$SETTINGS"
  assert_eq "$status" 0

  run commands_of Stop
  assert_not_contains "$output" 'tmux-whistle'
  assert_contains "$output" 'wiki-stop-capture.sh'

  run commands_of SessionStart
  assert_not_contains "$output" 'tmux-whistle'
  assert_contains "$output" 'wiki-session-recap.sh'
}

@test "uninstall 之后再 install 能装回来" {
  "$INSTALLER" --settings "$SETTINGS"
  "$INSTALLER" --uninstall --settings "$SETTINGS"
  "$INSTALLER" --settings "$SETTINGS"
  run commands_of Stop
  assert_contains "$output" 'tmux-whistle'
}

@test "install: 文件不存在时创建最小骨架" {
  local nested="$BATS_TEST_TMPDIR/nested/dir/new-settings.json"
  run "$INSTALLER" --settings "$nested"
  assert_eq "$status" 0
  [ -f "$nested" ]
  assert_contains "$(cat "$nested")" 'tmux-whistle'
}

@test "install: 已有 hooks 字段但缺目标事件时补齐" {
  local partial="$BATS_TEST_TMPDIR/partial.json"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x"}]}]}}\n' > "$partial"
  run "$INSTALLER" --settings "$partial"
  assert_eq "$status" 0

  python3 - "$partial" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
for event in ("Stop", "Notification", "SessionStart", "UserPromptSubmit"):
    assert event in hooks, f"缺 {event}"
assert any(h["command"] == "x" for e in hooks["SessionStart"] for h in e["hooks"])
PY
}

@test "install: 备份文件在改写之前就生成" {
  local before
  before=$(cat "$SETTINGS")
  "$INSTALLER" --settings "$SETTINGS"

  run bash -c "find '$BATS_TEST_TMPDIR' -maxdepth 1 -name 'settings.json.bak.*' | head -1"
  assert_eq "$status" 0

  local bak
  bak=$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'settings.json.bak.*' | head -1)
  assert_eq "$(cat "$bak")" "$before"
}

@test "install: --dry-run 不碰磁盘" {
  local before
  before=$(cat "$SETTINGS")
  run "$INSTALLER" --dry-run --settings "$SETTINGS"
  assert_eq "$status" 0
  assert_eq "$(cat "$SETTINGS")" "$before"
  run bash -c "find '$BATS_TEST_TMPDIR' -maxdepth 1 -name 'settings.json.bak.*'"
  assert_eq "$status" 0
  assert_eq "$output" ""
}

@test "install: --dry-run 仍然输出合并后的完整 JSON（可人工核对）" {
  run "$INSTALLER" --dry-run --settings "$SETTINGS"
  assert_contains "$output" 'tmux-whistle'
  assert_contains "$output" 'wiki-stop-capture.sh'
}

@test "install: 非法 JSON 时拒绝改写而不是毁掉文件" {
  printf '{ this is not json\n' > "$SETTINGS"
  run "$INSTALLER" --settings "$SETTINGS"
  assert_eq "$status" 1
  assert_eq "$(cat "$SETTINGS")" '{ this is not json'
}