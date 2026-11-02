#!/bin/sh
# running 状态的 Braille 帧推进器。
#
# 由 whistle_spin_ensure 用 `tmux run-shell -b` 拉起，**只在真有 running 时活着**：
# 计数归零、或 @whistle_spin 被关掉，下一轮循环就退出并清掉自己那份 PID 记录。
#
# 它只做两件事，都很廉价：帧号加一、重画状态栏。
# 之所以需要它 —— status-right 里的徽章串是预先算好存在 global option 里的
# **纯 format**（零 fork 是硬红线）。format 是静态的，tmux 没有「每 N 帧换字符」
# 的原生能力，所以得有个东西去改 @whistle_spin，format 在下次重画时读出新值。
#
# 单实例：server 自己的 option 里记着 PID。进程由 tmux 的 run-shell -b 托管，
# 这个循环本身就是被 run-shell 托管的那条命令。

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export WHISTLE_ROOT

# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/core.sh"
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/deliver.sh"

# 单实例守卫：PID 记在**这个 server 自己的 option** 里，不是磁盘 pidfile ——
# pidfile 按用户命名、不含 socket，两个 server 会共用一份，隔离 server 的
# whistle_spin_stop 会把用户真 server 的推进器 kill 掉（详见 lib/core.sh）。
_spin_old=$(whistle_spin_pid)
if [ -n "$_spin_old" ] && kill -0 "$_spin_old" 2> /dev/null; then
  exit 0 # 已有实例
fi
whistle_spin_pid_set "$$"

# 退出时只清「还属于自己」的那份：别人已经换过 PID 就别动它。
#
# trap EXIT 在这里是对的（它不是 bats 的测试文件 —— helper 里装 trap EXIT
# 会吞掉 bats 自己的失败，见 test_helper/whistle.bash 的注释）。
_spin_cleanup() {
  _spin_cur=$(whistle_spin_pid)
  [ "$_spin_cur" = "$$" ] && whistle_spin_pid_set ''
  exit 0
}
trap '_spin_cleanup' INT TERM EXIT

# -- 自愈节拍：每 N 帧触发一次全局重算 ---------------------------------------
#
# 为什么需要它：@whistle_sub 存的是**过期时间戳**，而过期判定只在**重算时**
# 才被求值。Claude Code 若在某些路径不发 SubagentStop / agent_completed，
# 标记会泄漏 —— 状态栏永久亮 ▶，正是本项目最恨的那类缺陷。
# 周期重算让过期真正落地，把「永久误报」压回「漏报」（后者只是回到旧行为）。
#
# 挂在推进器上不是偶然：它**只在 @whistle_count_running > 0 时活着** ——
# 恰好就是标记泄漏的场景；而计数归零时它自己退出，不需要额外的常驻进程。
#
# N 用户可配：@whistle_recompute_every，默认 60 帧（配 0.5 秒间隔 ≈ 30 秒）。
# 只读一次并定格，不放进循环 —— 每次 whistle_conf 都要 fork 一个 tmux 进程，
# 而这是 0.5 秒一次的高频路径。
#
# ⚠️ @whistle_recompute_every 是**用户可配**的，按项目规矩应当进
# lib/core.sh 的 WHISTLE_DEFAULTS（那是用户可配项的表）。本次改动的范围
# 不含 core.sh，所以读不到时用 60 兜底；等它补进默认表后，whistle_conf
# 会直接返回表里的值，这段兜底自然让位（非纯数字 / <= 0 时仍回落到 60，
# 免得配置写错把推进器变成每帧一次重算）。
_rce_every=$(whistle_conf '@whistle_recompute_every')
case "$_rce_every" in
'' | *[!0-9]*) _rce_every=60 ;;
esac
[ "$_rce_every" -gt 0 ] || _rce_every=60
_rce_i=0

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

  # 自愈节拍：每 N 帧重算一次全局，让过期的 @whistle_sub 真正回落。
  #
  # ⚠️ 这条路径**可能把本进程自己杀掉**，而这是预期行为：
  #   标记过期 → 重算把 @whistle_count_running 降到 0 →
  #   whistle_recompute_global 末尾的 whistle_spin_sync 发现没有 running →
  #   调 whistle_spin_stop，而 server option 里存的就是本进程的 $$。
  # 收到 SIGTERM 后走上面的 trap（清掉自己那份 PID 记录 + exit 0），与「循环顶部
  # 读到计数为 0 而 break」等价 —— 自愈之后推进器本就该退出。
  # 不会死循环（kill 之后的本轮循环立刻结束，不存在再重算的下一轮），
  # 也不会留残骸（whistle_spin_stop 先 rm 一次、trap 再 rm 一次，幂等）。
  # 状态不会写坏半截：计数与 @whistle_eff 都在 spin_sync **之前**写完
  # （core.sh 里的顺序），被信号打断时落盘的已经是完整的新值。
  _rce_i=$((_rce_i + 1))
  if [ "$_rce_i" -ge "$_rce_every" ]; then
    _rce_i=0
    whistle_recompute_global || true
  fi

  sleep "$(whistle_conf '@whistle_spin_interval')" 2> /dev/null || sleep 1
done
