#!/bin/sh
# 插件加载时执行的初始化。由 .tmux-whistle.conf 通过 run-shell -b 调用。
#
# 只做"设置"，不做"投递"：这里没有任何通知语义。
#
# 全程幂等：prefix r、tpm install、插件更新都会重跑一遍。

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export WHISTLE_ROOT

# 由 .tmux-whistle.conf 传入当前 server 的 socket 路径。
# 必须锁定它：$TMUX_SOCKET 会被子进程跨 server 继承，
# 不锁就可能把状态写进用户正在用的另一个 server。
if [ -n "${1:-}" ]; then
  WHISTLE_TMUX_SOCKET="$1"
  export WHISTLE_TMUX_SOCKET
fi

for _m in core status-line deliver; do
  if [ ! -f "$WHISTLE_ROOT/lib/$_m.sh" ]; then
    printf 'tmux-whistle: 缺少 lib/%s.sh\n' "$_m" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$WHISTLE_ROOT/lib/$_m.sh"
done
unset _m

# 让 conf 与 CLI 都能定位到插件
whistle_tmux set -g @whistle_root "$WHISTLE_ROOT"

# 发布徽章 format。改色之后重跑本脚本即可生效，不必重载配置。
whistle_mark_publish
whistle_status_right_publish

# 幂等注入窗口状态栏（连续执行不会叠出双徽章，KP-4）
whistle_format_patch window-status-format
whistle_format_patch window-status-current-format
# 跨 session 可见性：不管你在哪个 session，右侧都能看到 🔔N
whistle_status_right_patch

# prefix r 之后主题已重刷，把上次残留的边框染色清掉（KP-6）
whistle_border_release_all
whistle_border_status_release_all

# 注册读侧 hooks：切进窗口即已读 + pane 增删后重算（原理 4.3）
whistle_hooks_install "$WHISTLE_ROOT/bin/tmux-whistle"

# 可选：关键词兜底检测（默认关）
if [ "$(whistle_conf '@whistle_detect')" = on ]; then
  if [ -f "$WHISTLE_ROOT/lib/detect.sh" ]; then
    # shellcheck source=/dev/null
    . "$WHISTLE_ROOT/lib/detect.sh"
    whistle_detect_ensure_daemon
  fi
fi

exit 0