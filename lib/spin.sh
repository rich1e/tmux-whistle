#!/bin/sh
# running 状态的 Braille 帧推进器。
#
# 由 whistle_spin_ensure 用 `tmux run-shell -b` 拉起，**只在真有 running 时活着**：
# 计数归零、或 @whistle_spin 被关掉，下一轮循环就退出并清掉 pidfile。
#
# 它只做两件事，都很廉价：帧号加一、重画状态栏。
# 之所以需要它 —— status-right 里的徽章串是预先算好存在 global option 里的
# **纯 format**（零 fork 是硬红线）。format 是静态的，tmux 没有「每 N 帧换字符」
# 的原生能力，所以得有个东西去改 @whistle_spin，format 在下次重画时读出新值。
#
# 单实例：pidfile 守卫。进程由 tmux 的 run-shell -b 托管，
# 这个循环本身就是被 run-shell 托管的那条命令。

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export WHISTLE_ROOT

# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/core.sh"
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/deliver.sh"

PIDFILE=$(whistle_spin_pidfile)

if [ -f "$PIDFILE" ]; then
  _old=''
  read -r _old < "$PIDFILE" 2> /dev/null || true
  if [ -n "$_old" ] && kill -0 "$_old" 2> /dev/null; then
    exit 0 # 已有实例
  fi
fi

mkdir -p "$(dirname "$PIDFILE")" 2> /dev/null || exit 1
printf '%s' "$$" > "$PIDFILE"

# trap EXIT 在这里是对的（它不是 bats 的测试文件 —— helper 里装 trap EXIT
# 会吞掉 bats 自己的失败，见 test_helper/whistle.bash 的注释）。
trap 'rm -f "$PIDFILE" 2>/dev/null; exit 0' INT TERM EXIT

while :; do
  [ "$(whistle_conf '@whistle_spin')" = on ] || break

  _n=$(whistle_tmux show -gqv '@whistle_count_running' 2> /dev/null)
  case "$_n" in
  '' | *[!0-9]*) _n=0 ;;
  esac
  [ "$_n" -gt 0 ] || break

  _cur=$(whistle_tmux show -gqv '@whistle_spin_char' 2> /dev/null)
  whistle_tmux set -g @whistle_spin_char "$(whistle_spin_next_char "$_cur")" 2> /dev/null || break
  whistle_refresh_all

  sleep "$(whistle_conf '@whistle_spin_interval')" 2> /dev/null || sleep 1
done
