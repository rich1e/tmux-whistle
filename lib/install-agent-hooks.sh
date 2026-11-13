#!/bin/sh
# 一次安装所有受支持的 agent hooks：Claude Code + Codex。
#
# `lib/install-hooks.sh` 保持为 Claude Code 专用实现（历史入口与测试都直接用它）；
# 本文件只做参数分发，避免把两套完全不同的配置格式揉进同一个 Python 合并器。
#
# 用法：
#   install-agent-hooks.sh [--dry-run] [--uninstall]
#                          [--settings PATH] [--codex-hooks PATH]
#                          [--claude-only | --codex-only]

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CLAUDE_INSTALLER="$ROOT/lib/install-hooks.sh"
CODEX_INSTALLER="$ROOT/lib/install-codex-hooks.sh"

DRY=0
UNINSTALL=0
SETTINGS=''
CODEX_HOOKS_PATH=''
TARGET=both

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
  --codex-hooks)
    CODEX_HOOKS_PATH="${2:-}"
    shift 2
    ;;
  --claude-only)
    TARGET=claude
    shift
    ;;
  --codex-only)
    TARGET=codex
    shift
    ;;
  -h | --help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf '用法: install-agent-hooks.sh [--dry-run] [--uninstall] [--settings PATH] [--codex-hooks PATH] [--claude-only|--codex-only]\n' >&2
    exit 1
    ;;
  esac
done

[ -n "$SETTINGS" ] || SETTINGS="${CLAUDE_SETTINGS:-}"
[ -n "$CODEX_HOOKS_PATH" ] || CODEX_HOOKS_PATH="${CODEX_HOOKS:-}"

if [ -n "$SETTINGS" ]; then
  CLAUDE_SETTINGS="$SETTINGS"
  export CLAUDE_SETTINGS
fi
if [ -n "$CODEX_HOOKS_PATH" ]; then
  CODEX_HOOKS="$CODEX_HOOKS_PATH"
  export CODEX_HOOKS
fi

# 同时构造两份子命令都接受的公共参数。
set --
[ "$DRY" = 1 ] && set -- "$@" --dry-run
[ "$UNINSTALL" = 1 ] && set -- "$@" --uninstall

_iah_rc=0

if [ "$TARGET" = both ] || [ "$TARGET" = claude ]; then
  printf '\nClaude Code hooks\n'
  "$CLAUDE_INSTALLER" "$@" || _iah_rc=1
fi

if [ "$TARGET" = both ] || [ "$TARGET" = codex ]; then
  printf '\nCodex hooks\n'
  "$CODEX_INSTALLER" "$@" || _iah_rc=1
fi

[ "$_iah_rc" = 0 ] || exit 1

if [ "$DRY" = 1 ]; then
  case "$TARGET" in
  both) printf '\n（dry-run：Claude Code 与 Codex 配置均未真正落盘）\n' ;;
  claude) printf '\n（dry-run：Claude Code 配置未真正落盘）\n' ;;
  codex) printf '\n（dry-run：Codex 配置未真正落盘）\n' ;;
  esac
fi

exit 0
