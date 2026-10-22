#!/bin/sh
# tmux-whistle 本地安装 / 卸载。
#
# 三件事：
#   1. 把仓库符号链接进 $TMUX_PLUGIN_MANAGER_PATH/tmux-whistle
#   2. 把 CLI 链接进 ~/.local/bin（hook 与 shell 都要能找到它）
#   3. 往 tmux.conf.local 追加一段带 marker 的配置块
#
# 只改自己那段 marker 块，绝不碰别的配置。重复执行安全。
#
# 用法：
#   ./install.sh [--dry-run] [--cleanup] [--no-hooks]
#   ./install.sh --uninstall [--dry-run]

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MARK_BEGIN='# >>> tmux-whistle >>>'
MARK_END='# <<< tmux-whistle <<<'

# 刻意不装进 $TMUX_PLUGIN_MANAGER_PATH：
# oh-my-tmux 重载时会跑 tpm 的 clean_plugins，把没有 @plugin 声明的目录直接删掉。
# 本地开发（符号链接、仓库没有 remote）会被它误杀，所以用独立的数据目录。
WHISTLE_HOME="${WHISTLE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/tmux-whistle}"
TMUX_CONF_LOCAL="${TMUX_CONF_LOCAL:-$HOME/.config/tmux/tmux.conf.local}"
BIN_DIR="${WHISTLE_BIN_DIR:-$HOME/.local/bin}"

DRY=0
UNINSTALL=0
CLEANUP=0
INSTALL_HOOKS=1

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
  --cleanup)
    CLEANUP=1
    shift
    ;;
  --no-hooks)
    INSTALL_HOOKS=0
    shift
    ;;
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'install: 未知参数 %s\n' "$1" >&2
    exit 1
    ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

PLUGIN_DIR="$WHISTLE_HOME"

# -- tmux.conf.local 的 marker 块 ------------------------------------------

write_block() {
  _file="$1"
  _tmp="$_file.tmux-whistle.$$"

  # 去掉旧块（如果存在），保留其余内容
  if [ -f "$_file" ]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip
    ' "$_file" > "$_tmp" || die "读取 $_file 失败"
  else
    : > "$_tmp"
  fi

  {
    printf '\n%s\n' "$MARK_BEGIN"
    printf '# 由 tmux-whistle/install.sh 生成，卸载请跑 install.sh --uninstall\n'
    printf "\n# 本地开发：直接执行插件入口（不用 tpm 去 git clone）\n"
    printf "run-shell '%s/tmux-whistle.tmux'\n" "$PLUGIN_DIR"
    printf '\n# 徽章落在 powerline 芯片内部（官方扩展点）。\n'
    printf '# 不想要这行也可以删掉——插件会自动 patch window-status-format 作为兜底。\n'
    printf 'tmux_conf_theme_window_status_format="#I #W#{?window_bell_flag,!,}#{?window_zoomed_flag,Z,}#{E:@whistle_mark}"\n'
    printf 'tmux_conf_theme_window_status_current_format="#I #W#{?window_bell_flag,!,}#{?window_zoomed_flag,Z,}#{E:@whistle_mark}"\n'
    printf '%s\n' "$MARK_END"
  } >> "$_tmp"

  if [ "$DRY" = 1 ]; then
    printf '[dry-run] 将写入 %s：\n' "$_file"
    sed -n "/$(printf '%s' "$MARK_BEGIN" | sed 's/[.[\*^$]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[.[\*^$]/\\&/g')/p" "$_tmp" | sed 's/^/    /'
    command rm -f "$_tmp"
  else
    # 用户的 tmux.conf.local 可能有几千行自定义内容，改之前先留一份
    [ -f "$_file" ] && cp "$_file" "$_file.bak.$(date +%Y%m%d%H%M%S)" 2> /dev/null
    mv "$_tmp" "$_file" || die "写入 $_file 失败"
    say "  已更新 ${_file}（备份在 ${_file}.bak.*）"
  fi
}

remove_block() {
  _file="$1"
  [ -f "$_file" ] || return 0
  grep -qF "$MARK_BEGIN" "$_file" || return 0

  _tmp="$_file.tmux-whistle.$$"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$_file" > "$_tmp" || die "读取 $_file 失败"

  if [ "$DRY" = 1 ]; then
    printf '[dry-run] 将从 %s 移除 marker 块\n' "$_file"
    command rm -f "$_tmp"
  else
    mv "$_tmp" "$_file"
    say "  已从 $_file 移除 marker 块"
  fi
}

# -- 卸载 ------------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
  say 'tmux-whistle 卸载'
  remove_block "$TMUX_CONF_LOCAL"
  [ -L "$BIN_DIR/tmux-whistle" ] && run command rm -f "$BIN_DIR/tmux-whistle"
  [ -L "$PLUGIN_DIR" ] && run command rm -f "$PLUGIN_DIR"
  say '  完成。重载 tmux：prefix + r（或 tmux source-file ~/.config/tmux/tmux.conf）'
  [ "$DRY" = 1 ] && say '（dry-run：以上均未真正执行）'
  exit 0
fi

# -- 安装 ------------------------------------------------------------------

say 'tmux-whistle 安装'

[ -f "$ROOT/bin/tmux-whistle" ] || die "$ROOT 不像插件仓库（缺 bin/tmux-whistle）"
[ -x "$ROOT/hooks/claude-code.sh" ] || run chmod +x "$ROOT/hooks/claude-code.sh"
[ -x "$ROOT/tmux-whistle.tmux" ] || run chmod +x "$ROOT/tmux-whistle.tmux"
[ -x "$ROOT/scripts/setup.sh" ] || run chmod +x "$ROOT/scripts/setup.sh"
[ -x "$ROOT/lib/detect.sh" ] || run chmod +x "$ROOT/lib/detect.sh"

mkdir -p "$(dirname "$PLUGIN_DIR")" "$BIN_DIR" || die '创建目录失败'

# 1. 插件目录符号链接
if [ -e "$PLUGIN_DIR" ] && [ ! -L "$PLUGIN_DIR" ]; then
  die "$PLUGIN_DIR 已存在且不是符号链接，请先手动处理。"
fi
run ln -sfn "$ROOT" "$PLUGIN_DIR"
say "  插件目录 -> $PLUGIN_DIR"

# 2. CLI 进 PATH
run ln -sfn "$ROOT/bin/tmux-whistle" "$BIN_DIR/tmux-whistle"
say "  CLI        -> $BIN_DIR/tmux-whistle"
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) say "  注意：$BIN_DIR 不在 PATH 里，Claude Code hook 用的是绝对路径所以仍可用，
        但命令行里需要自己加到 PATH。" ;;
esac

# 3. tmux.conf.local marker 块
write_block "$TMUX_CONF_LOCAL"

# 4. 可选：清理失效的 tmux-notify 绑定
if [ "$CLEANUP" = 1 ]; then
  if [ -d "${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.config/tmux/plugins}/tmux-notify" ]; then
    say '  tmux-notify 仍安装着，跳过绑定清理'
  else
    say '  清理失效的 tmux-notify 绑定（C-m / M-m / M）'
    for k in C-m M-m M; do
      run tmux unbind-key -T prefix "$k" 2> /dev/null || true
    done
  fi
fi

# 5. Claude Code hooks
if [ "$INSTALL_HOOKS" = 1 ]; then
  if [ "$DRY" = 1 ]; then
    "$ROOT/lib/install-hooks.sh" --dry-run > /dev/null 2>&1 \
      && say "  [dry-run] 会合并 Claude Code hooks 到 ~/.claude/settings.json"
  else
    if "$ROOT/lib/install-hooks.sh"; then
      :
    else
      say '  Claude Code hooks 未安装（可稍后手动跑 lib/install-hooks.sh）'
    fi
  fi
fi

say ''
say '完成。接下来：'
say '  1. tmux source-file ~/.config/tmux/tmux.conf    （或 prefix + r）'
say '  2. tmux-whistle doctor'
say '  3. macOS 上先跑一次 osascript 测试通知，并在系统设置里给 Script Editor 授权：'
say '     osascript -e '"'"'display notification "test"'"'"''
[ "$DRY" = 1 ] && say ''
[ "$DRY" = 1 ] && say '（dry-run：以上改动均未真正落盘）'
exit 0
