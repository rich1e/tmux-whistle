#!/bin/sh
# 把 tmux-whistle 的 hooks 幂等地合并进 ~/.codex/hooks.json。
#
# 三条铁律（与 lib/install-hooks.sh 相同）：
#   1. 先备份
#   2. 只增删带 tmux-whistle marker 的条目，绝不覆盖别人已有的 hook
#   3. 重复执行结果一致
#
# Codex 的信任绑定在原文件的 event/index 上。所以我们的条目**总是追加**，
# 不插到前面 —— 否则用户已经信任的第三方 hook 会因为索引变化而失效。
#
# 用法：
#   install-codex-hooks.sh [--dry-run] [--uninstall] [--hooks PATH]

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HOOK_CMD="$WHISTLE_ROOT/hooks/codex.sh"
MARKER='tmux-whistle'
HOOKS="${CODEX_HOOKS:-${CODEX_HOME:-$HOME/.codex}/hooks.json}"

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
  --hooks)
    HOOKS="${2:-}"
    shift 2
    ;;
  -h | --help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf '用法: install-codex-hooks.sh [--dry-run] [--uninstall] [--hooks PATH]\n' >&2
    exit 1
    ;;
  esac
done

die() {
  printf 'install-codex-hooks: %s\n' "$*" >&2
  exit 1
}

command -v python3 > /dev/null 2>&1 \
  || die '需要 python3 来安全地合并 JSON（手改 hooks.json 容易毁掉已有条目）。'

[ -n "$HOOKS" ] || die 'hooks 路径为空'

if [ "$UNINSTALL" = 0 ] && [ ! -x "$HOOK_CMD" ]; then
  printf 'install-codex-hooks: %s 不可执行，请先 chmod +x\n' "$HOOK_CMD" >&2
  exit 1
fi

[ "$DRY" = 1 ] || {
  mkdir -p "$(dirname "$HOOKS")" || die "创建 $(dirname "$HOOKS") 失败"
  if [ -f "$HOOKS" ]; then
    cp "$HOOKS" "$HOOKS.bak.$(date +%Y%m%d%H%M%S)" \
      || die "备份 $HOOKS 失败"
  fi
}

export WHISTLE_MARKER="$MARKER"
export WHISTLE_HOOK_CMD="$HOOK_CMD"
export WHISTLE_CODEX_HOOKS="$HOOKS"
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
import stat
import sys

path = os.environ["WHISTLE_CODEX_HOOKS"]
marker = os.environ["WHISTLE_MARKER"]
cmd = os.environ["WHISTLE_HOOK_CMD"]
action = os.environ["WHISTLE_ACTION"]

# Codex 生命周期事件。PostToolUse 是唯一异步的：
#   · 它只负责「权限批准后清 wait」，不改活动通道
#   · 工具调用频率高，同步会拖慢每一次工具执行
# 其余事件全部同步，保证 SessionStart → UserPromptSubmit → Stop 的写入顺序；
# SessionEnd / Interrupt 是 Codex 强制同步的事件，不设 async。
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PermissionRequest",
    "PostToolUse",
    "SubagentStart",
    "SubagentStop",
    "Stop",
    "Interrupt",
    "SessionEnd",
]


def hook_for(event):
    hook = {"type": "command", "command": cmd}
    if event in ("SessionEnd", "Interrupt"):
        hook["timeout"] = 2
    else:
        hook["timeout"] = 5
    if event == "PostToolUse":
        hook["async"] = True
    return hook


def our_entry(event):
    # 刻意不写 matcher：省略 matcher 在 Codex 里等价于匹配全部。
    # 少一个可漂移字段，也避免把支持 matcher 与不支持 matcher 的事件混在一起。
    return {"hooks": [hook_for(event)]}


def is_ours(entry):
    if not isinstance(entry, dict):
        return False
    for hook in entry.get("hooks", []) or []:
        if isinstance(hook, dict) and marker in str(hook.get("command", "")):
            return True
    return False


def load():
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        sys.exit(f"install-codex-hooks: {path} 不是合法 JSON（{e}），请先修好再重试")


if action == "uninstall" and not os.path.exists(path):
    print(f"install-codex-hooks: {path} 不存在，无需卸载")
    sys.exit(0)

data = load()
if not isinstance(data, dict):
    sys.exit(f"install-codex-hooks: {path} 顶层不是对象，请先修好再重试")

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(f"install-codex-hooks: {path} 的 hooks 字段不是对象，请先修好再重试")

changed = []
for event in EVENTS:
    entries = hooks.get(event, [])
    if not isinstance(entries, list):
        sys.exit(f"install-codex-hooks: hooks.{event} 不是数组，请先修好再重试")

    kept = [entry for entry in entries if not is_ours(entry)]
    if action == "install":
        # 必须 append：Codex 的 trust key 带 event/index，插到前面会让别人的
        # 已信任条目整体错位。
        kept.append(our_entry(event))
    if kept:
        hooks[event] = kept
    elif event in hooks:
        del hooks[event]
    changed.append(event)

if action == "uninstall" and not hooks:
    data.pop("hooks", None)

out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

if os.environ.get("WHISTLE_DRY") == "1":
    sys.stdout.write(out)
    sys.exit(0)

# 用户可能把 hooks.json 软链到 dotfiles。直接 os.replace(path, ...) 会把
# 软链本身换成普通文件，等于悄悄破坏 dotfile 管理；替换真实目标才安全。
target = os.path.realpath(path) if os.path.islink(path) else path
tmp = f"{target}.tmp.{os.getpid()}"
try:
    try:
        mode = stat.S_IMODE(os.stat(target).st_mode)
    except FileNotFoundError:
        mode = None
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, target)
except OSError as e:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(f"install-codex-hooks: 写入 {path} 失败（{e}）")

verb = "已写入" if action == "install" else "已移除"
print(f"install-codex-hooks: {verb} {len(changed)} 个事件 -> {path}")
print(f"install-codex-hooks: 事件 = {', '.join(changed)}")
if action == "install":
    print("install-codex-hooks: 启动 Codex 后输入 /hooks，审核并信任新增的 tmux-whistle hooks")
    print("install-codex-hooks: Codex 把信任绑定到 hook 哈希；重装或改命令后需要重新审核")
PY
rc=$?

[ "$rc" = 0 ] || exit "$rc"

if [ "$DRY" = 1 ]; then
  exit 0
fi

if [ "$UNINSTALL" = 1 ]; then
  printf 'install-codex-hooks: 已从 %s 移除（其它 hook 条目原样保留）\n' "$HOOKS"
else
  printf 'install-codex-hooks: 其它 hook 条目原样保留（备份在 %s.bak.*）\n' "$HOOKS"
fi

# 同一层同时有 hooks.json 和 inline [hooks] 时 Codex 会合并并警告。
# 我们不改用户的 config.toml；只把这个容易忽略的冲突明确指出来。
_ic_config="${CODEX_CONFIG:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
if [ -f "$_ic_config" ] \
  && grep -Eq '^[[:space:]]*\[\[hooks\.(SessionStart|UserPromptSubmit|PermissionRequest|PostToolUse|SubagentStart|SubagentStop|Stop|Interrupt|SessionEnd)\]\]' "$_ic_config" 2> /dev/null; then
  printf 'install-codex-hooks: 注意 %s 里还有 inline [hooks]；Codex 会同时加载并提示重复来源\n' "$_ic_config" >&2
fi

exit 0
