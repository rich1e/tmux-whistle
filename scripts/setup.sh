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

# 重算一次聚合，然后同步 running 动画帧的启停。
#
# **必须在插件加载时就做，不能只靠 whistle_deliver。**
# deliver 只在**状态变化**时才跑 —— 一个「早就报了 running、之后一直没人动过」
# 的 pane 不会再有 deliver。只靠 deliver 启停的话，prefix + r 之后动画就永远
# 转不起来，而界面上看不出任何异常（帧号停在 0，看起来就是「不转」）。
whistle_recompute_global
whistle_spin_sync

# prefix r 之后主题已重刷，把上次残留的边框染色清掉（KP-6）
whistle_border_release_all
whistle_border_status_release_all

# 注册读侧 hooks：切进窗口即已读 + pane 增删后重算（原理 4.3）
whistle_hooks_install "$WHISTLE_ROOT/bin/tmux-whistle"

# 重新应用菜单键绑定（自愈）。
#
# 为什么绑定要写两遍：tmux.conf 里可能有 `unbind n` 之类 —— 用 `unbind`
# 干掉 tmux 默认的 next-window 是常见做法 —— 而它排在 tmux.conf.local
# **之后**执行，会把 .tmux-whistle.conf 里的绑定解掉。
# 本脚本是 `run-shell -b -d 0.5` 之后跑的，此时整份配置已经加载完，
# 在这里重绑一次就绕开了顺序问题。与 whistle_ensure_status_line 同一思路：
# 与其猜顺序，不如在确定安全的那一刻补一次。
#
# ⚠️ 键位必须与 .tmux-whistle.conf 保持一致，两处都要改。
#
# ⚠️ `'\;'` 必须是单引号包着的。从 shell 传参时裸 `\;` 会被 shell 吃掉反斜杠，
#    tmux 收到裸 `;` 就当成**命令分隔符** —— 结果是 `display-message` 被立刻
#    执行掉、根本没进 binding，按键时只是菜单打开了却不出提示。
#    在 .tmux-whistle.conf 里写 `\;` 是对的（那是 tmux 自己解析的），
#    但从 shell 调 tmux 时必须把反斜杠原样送过去。
whistle_tmux bind-key -T prefix n \
  run-shell -b "\"$WHISTLE_ROOT/bin/tmux-whistle\" menu" \
  '\;' display-message 'whistle 菜单' 2> /dev/null || true

# 可选：关键词兜底检测（默认关）
if [ "$(whistle_conf '@whistle_detect')" = on ]; then
  if [ -f "$WHISTLE_ROOT/lib/detect.sh" ]; then
    # shellcheck source=/dev/null
    . "$WHISTLE_ROOT/lib/detect.sh"
    whistle_detect_ensure_daemon
  fi
fi

exit 0