#!/usr/bin/env bash
# tmux-whistle 的 tpm / tpack 入口。
#
# tpm（scripts/source_plugins.sh）把插件目录下的 *.tmux 文件当作**可执行文件**运行，
# 不 source、也不提供 #{plugin_root_path} —— 所以入口自己算出自己的位置，
# 再把真正的配置交给 tmux source-file。

set -eu

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$dir/.tmux-whistle.conf" ]; then
    printf '[tmux-whistle] 安装不完整：%s 下找不到 .tmux-whistle.conf\n' "$dir" >&2
    exit 1
fi

# tmux conf 里没有 __FILE__，只能先把插件根目录写进 option 再 source。
# .tmux-whistle.conf 与 scripts/setup.sh 都靠 @whistle_root 定位自己。
tmux set -g @whistle_root "$dir"
tmux source-file "$dir/.tmux-whistle.conf"