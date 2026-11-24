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

# -- Codex hooks 明细 -------------------------------------------------------

write_codex_hooks() {
  local path="$1" cmd="$2" post_async="${3:-1}" session_end_async="${4:-0}" omit="${5:-}"
  CODEX_HOOK_CMD="$cmd" POST_ASYNC="$post_async" \
    SESSION_END_ASYNC="$session_end_async" OMIT="$omit" \
    python3 - "$path" << 'PY'
import json, os, sys

cmd = os.environ["CODEX_HOOK_CMD"]
post_async = os.environ["POST_ASYNC"] == "1"
se_async = os.environ["SESSION_END_ASYNC"] == "1"
omit = set(x for x in os.environ["OMIT"].split(",") if x)
events = ("SessionStart", "UserPromptSubmit", "PermissionRequest",
          "PostToolUse", "SubagentStart", "SubagentStop", "Stop",
          "Interrupt", "SessionEnd")

hooks = {}
for event in events:
    if event in omit:
        continue
    hook = {"type": "command", "command": cmd}
    if event == "PostToolUse" and post_async:
        hook["async"] = True
    if event == "SessionEnd" and se_async:
        hook["async"] = True
    hooks[event] = [{"hooks": [hook]}]

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"hooks": hooks}, f, ensure_ascii=False, indent=2)
PY
}

@test "doctor: 逐事件列出 Codex 订阅（含 async 与 matcher）" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh"

  run env CODEX_HOOKS="$h" "$CLI" doctor

  assert_contains "$output" '9/9 个事件已订阅'
  assert_contains "$output" 'PostToolUse      async'
  assert_contains "$output" 'SessionEnd       sync'
  assert_contains "$output" '在 Codex 里输入 /hooks 审核并信任'
  assert_not_contains "$output" '命令指向'
}

@test "doctor: Codex PostToolUse 被改成 sync 时告警" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh" 0

  run env CODEX_HOOKS="$h" "$CLI" doctor

  assert_contains "$output" 'PostToolUse 是 sync'
}

@test "doctor: Codex SessionEnd 被改成 async 时告警" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh" 1 1

  run env CODEX_HOOKS="$h" "$CLI" doctor

  assert_contains "$output" 'SessionEnd 是 async'
  assert_contains "$output" '生命周期写入可能乱序'
}

@test "doctor: Codex 命令路径指向别处时提示改了不生效" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  write_codex_hooks "$h" "/tmp/tmux-whistle-old/hooks/codex.sh"

  run env CODEX_HOOKS="$h" "$CLI" doctor

  assert_contains "$output" '命令指向 /tmp/tmux-whistle-old/hooks/codex.sh'
  assert_contains "$output" '改了这边不会生效'
}

@test "doctor: Codex 缺事件时点名缺了哪些" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh" 1 0 'Interrupt,SubagentStart'

  run env CODEX_HOOKS="$h" "$CLI" doctor

  assert_contains "$output" '缺 2 个事件'
  assert_contains "$output" 'Interrupt'
  assert_contains "$output" 'SubagentStart'
}

@test "doctor: Codex hooks.json 与 inline [hooks] 并存时告警" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  local c="$BATS_TEST_TMPDIR/codex-config.toml"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh"
  printf '[[hooks.Stop]]\nmatcher = "*"\n\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "x"\n' > "$c"

  run env CODEX_HOOKS="$h" CODEX_CONFIG="$c" "$CLI" doctor

  assert_contains "$output" 'config.toml 里还有 inline [hooks]'
}

# -- Codex pane attribution --------------------------------------------------

install_fake_codex_features() {
  cat > "$FAKE_BIN/codex" << 'EOF'
#!/bin/sh
if [ "${1:-}" = features ] && [ "${2:-}" = list ]; then
  printf 'daemon_auto_start                        stable             true\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/codex"
}

@test "doctor: 多 Codex TUI 共用 daemon 且无 binding 时报错" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  local c="$BATS_TEST_TMPDIR/codex-config.toml"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh"
  : > "$c"
  install_fake_codex_features

  run env PATH="$FAKE_BIN:$PATH" CODEX_HOOKS="$h" CODEX_CONFIG="$c" \
    WHISTLE_DOCTOR_CODEX_PANES=2 WHISTLE_DOCTOR_CODEX_BOUND=0 "$CLI" doctor

  assert_eq "$status" 1
  assert_contains "$output" '未绑定到 pane'
  assert_contains "$output" 'tmux-whistle-codex'
  assert_contains "$output" 'daemon_auto_start=true'
}

@test "doctor: 多 Codex TUI 全部绑定后不再报错" {
  local h="$BATS_TEST_TMPDIR/codex-hooks.json"
  local c="$BATS_TEST_TMPDIR/codex-config.toml"
  write_codex_hooks "$h" "$WHISTLE_ROOT/hooks/codex.sh"
  : > "$c"
  install_fake_codex_features

  run env PATH="$FAKE_BIN:$PATH" CODEX_HOOKS="$h" CODEX_CONFIG="$c" \
    WHISTLE_DOCTOR_CODEX_PANES=2 WHISTLE_DOCTOR_CODEX_BOUND=2 "$CLI" doctor

  assert_contains "$output" '全部 Codex TUI 已经由 pane 本地启动器绑定（2/2）'
  assert_not_contains "$output" '未绑定到 pane'
}

# -- OpenCode：逐事件列出订阅 --------------------------------------------------
#
# 只说「订阅 11 个事件」看不出订了哪 11 个，也看不出「声明了 12 条、
# 运行时只挂上 11 条」—— 都要能在这里看出来。

write_tui_events() {
  local d="$1"
  mkdir -p "$d/opencode/plugins/tmux-whistle"
  cat > "$d/opencode/plugins/tmux-whistle/tui.js" << 'TUI'
const EVENTS = [
  "session.execution.started",
  "permission.asked",
  "session.idle",
];
TUI
}

@test "doctor: 逐事件列出 OpenCode 插件订阅" {
  local x="$BATS_TEST_TMPDIR/xdg"
  local log="$BATS_TEST_TMPDIR/hooks.log"
  write_tui_events "$x"
  printf '2026-11-13 [1] agent=opencode event=tui-probe TMUX_PANE=%%1 loaded=ok subs=3\n' > "$log"

  run env XDG_CONFIG_HOME="$x" WHISTLE_HOOK_LOG="$log" "$CLI" doctor

  assert_eq "$status" 0
  assert_contains "$output" '插件已加载，订阅 3 个事件'
  assert_contains "$output" '订阅清单（3）'
  assert_contains "$output" 'session.execution.started'
  assert_contains "$output" 'permission.asked'
  assert_contains "$output" 'session.idle'
}

@test "doctor: 订阅失败的事件逐条标出，并告警声明数与实际数不一致" {
  local x="$BATS_TEST_TMPDIR/xdg"
  local log="$BATS_TEST_TMPDIR/hooks.log"
  write_tui_events "$x"
  printf '2026-11-13 [1] agent=opencode event=tui-probe TMUX_PANE=%%1 loaded=ok subs=2 failed=permission.asked\n' > "$log"

  run env XDG_CONFIG_HOME="$x" WHISTLE_HOOK_LOG="$log" "$CLI" doctor

  assert_contains "$output" '声明 3 条、实际挂上 2 条'
  assert_contains "$output" 'permission.asked'
  assert_contains "$output" '← 订阅失败'
}

@test "doctor: debug 关闭（无探针日志）时仍列出声明的事件清单" {
  local x="$BATS_TEST_TMPDIR/xdg"
  write_tui_events "$x"

  run env XDG_CONFIG_HOME="$x" WHISTLE_HOOK_LOG="$BATS_TEST_TMPDIR/none.log" "$CLI" doctor

  assert_contains "$output" '订阅清单（3）'
  assert_contains "$output" 'session.execution.started'
  assert_not_contains "$output" '声明 3 条、实际挂上'
}
