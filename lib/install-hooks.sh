#!/bin/sh
# 把 tmux-whistle 的 hooks 幂等地合并进 ~/.claude/settings.json。
#
# 三条铁律（KP-12）：
#   1. 先备份
#   2. 只追加/摘除带我们 marker 的条目，绝不覆盖别人已有的 hook
#      （用户已经有 SessionStart / Stop 的 obsidian-wiki hooks）
#   3. 重复执行结果一致
#
# 用法：
#   install-hooks.sh [--dry-run] [--uninstall] [--settings PATH]

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HOOK_CMD="$WHISTLE_ROOT/hooks/claude-code.sh"
MARKER='tmux-whistle'
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

DRY=0
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run)
    DRY=1
    shift
    ;;
  --uninstall)
    UNINSTALL=1
    shift
    ;;
  --settings)
    SETTINGS="${2:-}"
    shift 2
    ;;
  *)
    printf '用法: install-hooks.sh [--dry-run] [--uninstall] [--settings PATH]\n' >&2
    exit 1
    ;;
  esac
done

die() {
  printf 'install-hooks: %s\n' "$*" >&2
  exit 1
}

command -v python3 > /dev/null 2>&1 \
  || die '需要 python3 来安全地合并 JSON（手改 settings.json 容易毁掉你已有的 hooks）。
          macOS 自带 Xcode CLT 时就有；否则请手动把 hooks/claude-code.sh 加进 settings.json。'

[ -n "$SETTINGS" ] || die 'settings 路径为空'

if [ "$UNINSTALL" = 0 ] && [ ! -x "$HOOK_CMD" ]; then
  printf 'install-hooks: %s 不可执行，请先 chmod +x\n' "$HOOK_CMD" >&2
  exit 1
fi

[ "$DRY" = 1 ] || {
  mkdir -p "$(dirname "$SETTINGS")" || die "创建 $(dirname "$SETTINGS") 失败"
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)" \
      || die "备份 $SETTINGS 失败"
  fi
}

export WHISTLE_MARKER="$MARKER"
export WHISTLE_HOOK_CMD="$HOOK_CMD"
export WHISTLE_SETTINGS="$SETTINGS"
if [ "$UNINSTALL" = 1 ]; then
  WHISTLE_ACTION=uninstall
else
  WHISTLE_ACTION=install
fi
export WHISTLE_ACTION
export WHISTLE_DRY="$DRY"

python3 << 'PY'
import json
import os
import sys

path = os.environ["WHISTLE_SETTINGS"]
marker = os.environ["WHISTLE_MARKER"]
cmd = os.environ["WHISTLE_HOOK_CMD"]
action = os.environ["WHISTLE_ACTION"]

# 我们管理的五个事件。
#   Stop             agent 一轮结束
#   StopFailure      回合因 API 错误结束（限流 / 过载 / 认证失败 ...）
#                    —— 它**替代** Stop 触发，两者互斥；error 唯一的自动来源
#   Notification     等授权 / 后台 agent 要输入 / 后台 agent 完成
#   SessionStart     会话开始
#   UserPromptSubmit 用户开始交互
EVENTS = ["Stop", "StopFailure", "Notification", "SessionStart", "UserPromptSubmit"]

# Notification 只订阅"需要用户做点什么"的类型。
# auth_success / elicitation_complete / quota_* / plugin_notification 与本插件无关，
# 订阅它们只会让状态栏被无关事件刷满。
NOTIFY_MATCHER = (
    "permission_prompt|elicitation_dialog|elicitation_url_dialog"
    "|agent_needs_input|agent_completed"
)


def is_ours(entry):
    """这个 matcher 块是不是我们装的（含 marker 的 command）。"""
    for h in entry.get("hooks", []):
        if marker in str(h.get("command", "")):
            return True
    return False


def our_entry(event):
    entry = {"hooks": [{"type": "command", "command": cmd, "async": True}]}
    if event == "Notification":
        entry["matcher"] = NOTIFY_MATCHER
    return entry


try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(f"install-hooks: {path} 不是合法 JSON（{e}），请先修好再重试")

if not isinstance(data, dict):
    sys.exit(f"install-hooks: {path} 顶层不是对象，请先修好再重试")

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(f"install-hooks: {path} 的 hooks 字段不是对象，请先修好再重试")

changed = []
for event in EVENTS:
    entries = hooks.get(event, [])
    if not isinstance(entries, list):
        sys.exit(f"install-hooks: hooks.{event} 不是数组，请先修好再重试")

    kept = [e for e in entries if not is_ours(e)]
    if action == "install":
        kept.append(our_entry(event))
    if kept:
        hooks[event] = kept
    elif event in hooks:
        del hooks[event]
    changed.append(event)

if action == "install" and not hooks:
    data.pop("hooks", None)

out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

if os.environ.get("WHISTLE_DRY") == "1":
    sys.stdout.write(out)
    sys.exit(0)

with open(path, "w", encoding="utf-8") as f:
    f.write(out)

verb = "已写入" if action == "install" else "已移除"
print(f"install-hooks: {verb} {len(changed)} 个事件 -> {path}")
print(f"install-hooks: 事件 = {', '.join(changed)}")
if action == "install":
    print("install-hooks: 记得跑 tmux-whistle doctor 确认")
PY
rc=$?

[ "$rc" = 0 ] || exit "$rc"

if [ "$DRY" = 1 ]; then
  exit 0
fi

if [ "$UNINSTALL" = 1 ]; then
  printf 'install-hooks: 已从 %s 移除（本插件的其它 hook 条目原样保留）\n' "$SETTINGS"
else
  printf 'install-hooks: 其它 hook 条目原样保留（备份在 %s.bak.*）\n' "$SETTINGS"
  printf 'install-hooks: 重启 Claude Code 或开新会话后生效。\n'
fi
