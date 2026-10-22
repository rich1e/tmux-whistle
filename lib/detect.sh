#!/bin/sh
# tmux-whistle 的关键词兜底检测（默认关闭）。
#
# 这是唯一"猜"的地方：靠 capture-pane 的末几行匹配正则。
# 只在用户显式 set -g @whistle_detect on 时启用，README 里写清楚它会误报。
#
# 与 hooks 路径的关系：hook 永远优先。
# 只处理 @whistle_src 为空的 pane —— 一旦某个 pane 被 hook 接管过，
# 这里的轮询就再也不碰它，不会覆盖更准确的语义。
#
# 单实例：pidfile 守卫。进程由 tmux 的 run-shell -b 拉起，
# 常驻循环本身就是被 run-shell 托管的那条命令。

set -u

WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export WHISTLE_ROOT

# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/core.sh"

WHISTLE_DETECT_STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-whistle-$(id -u)"
WHISTLE_DETECT_PIDFILE="$WHISTLE_DETECT_STATE_DIR/detect.pid"

whistle_detect_default_wait_re() {
  whistle_conf '@whistle_detect_wait-re' 2> /dev/null \
    || printf 'esc to interrupt|Do you want to|❯ 1\\. Yes|waiting for your input'
}

whistle_detect_default_done_re() {
  whistle_conf '@whistle_detect_done-re' 2> /dev/null \
    || printf '⏵⏵|Bypass Permissions on'
}

whistle_detect_pid_alive() {
  _pid="$1"
  [ -n "$_pid" ] || return 1
  kill -0 "$_pid" 2> /dev/null
}

# 一次扫描。返回 0 表示做了至少一次状态变更。
whistle_detect_once() {
  _interval=$(whistle_conf '@whistle_detect_interval')
  _idle=$(whistle_conf '@whistle_detect_idle')
  _wait_re=$(whistle_conf '@whistle_detect_wait-re')
  _done_re=$(whistle_conf '@whistle_detect_done-re')
  [ -n "$_wait_re" ] || _wait_re=$(whistle_detect_default_wait_re)
  [ -n "$_done_re" ] || _done_re=$(whistle_detect_default_done_re)

  mkdir -p "$WHISTLE_DETECT_STATE_DIR" 2> /dev/null || return 0

  _panes=$(whistle_tmux list-panes -a \
    -F '#{pane_id}|#{@whistle_src}|#{@whistle}|#{pane_current_command}' 2> /dev/null)

  printf '%s\n' "$_panes" | while IFS='|' read -r _dpid _dsrc _dstate _dcmd; do
    case "${_dpid:-}" in
    '%'*) ;;
    *) continue ;;
    esac

    # hook 接管过的 pane 一律跳过（hook 永远优先）
    [ -n "${_dsrc:-}" ] && continue
    # 已经在告警态的不重复处理，等用户清掉
    whistle_is_notified "$_dstate" && continue

    _tail=$(whistle_tmux capture-pane -p -t "$_dpid" 2> /dev/null | tail -n 20)
    [ -n "$_tail" ] || continue

    _hash=$(printf '%s' "$_tail" | cksum | cut -d' ' -f1)
    _stamp_file="$WHISTLE_DETECT_STATE_DIR/${_dpid#%}.stamp"
    _hash_file="$WHISTLE_DETECT_STATE_DIR/${_dpid#%}.hash"

    _prev_hash=''
    [ -f "$_hash_file" ] && _prev_hash=$(cat "$_hash_file" 2> /dev/null)

    if [ "$_hash" != "$_prev_hash" ]; then
      printf '%s' "$_hash" > "$_hash_file"
      whistle_now > "$_stamp_file"
      continue
    fi

    _changed_at=0
    [ -f "$_stamp_file" ] && _changed_at=$(cat "$_stamp_file" 2> /dev/null)
    _quiet=$(($(whistle_now) - ${_changed_at:-0}))

    if printf '%s' "$_tail" | grep -qE "$_wait_re"; then
      WHISTLE_SRC=detect whistle_state_set "wait" '检测到等待输入' "$_dpid" > /dev/null \
        && whistle_recompute_window "$(whistle_pane_window "$_dpid")" \
        && whistle_recompute_global \
        && whistle_refresh_sessions "$(whistle_pane_window "$_dpid")"
      continue
    fi

    if [ "$_quiet" -ge "$_idle" ] && printf '%s' "$_tail" | grep -qE "$_done_re"; then
      WHISTLE_SRC=detect whistle_state_set "done" '输出已静默' "$_dpid" > /dev/null \
        && whistle_recompute_window "$(whistle_pane_window "$_dpid")" \
        && whistle_recompute_global \
        && whistle_refresh_sessions "$(whistle_pane_window "$_dpid")"
    fi
  done

  # 清掉已消失 pane 的临时文件
  for _f in "$WHISTLE_DETECT_STATE_DIR"/*.hash; do
    [ -f "$_f" ] || continue
    _id=$(basename "$_f" .hash)
    whistle_tmux display-message -p -t "%$_id" '#{pane_id}' > /dev/null 2>&1 \
      || command rm -f "$_f" "$WHISTLE_DETECT_STATE_DIR/$_id.stamp"
  done
}

whistle_detect_loop() {
  mkdir -p "$WHISTLE_DETECT_STATE_DIR" 2> /dev/null || exit 1

  if [ -f "$WHISTLE_DETECT_PIDFILE" ]; then
    _old=$(cat "$WHISTLE_DETECT_PIDFILE" 2> /dev/null)
    if whistle_detect_pid_alive "$_old"; then
      exit 0 # 已有实例
    fi
  fi
  printf '%s' "$$" > "$WHISTLE_DETECT_PIDFILE"

  trap 'command rm -f "$WHISTLE_DETECT_PIDFILE" 2>/dev/null; exit 0' INT TERM EXIT

  while :; do
    [ "$(whistle_conf '@whistle_detect')" = on ] || break
    whistle_detect_once
    _interval=$(whistle_conf '@whistle_detect_interval')
    sleep "${_interval:-15}"
  done
}

# 由 setup.sh 调用：确保守护在跑，但不阻塞
whistle_detect_ensure_daemon() {
  [ "$(whistle_conf '@whistle_detect')" = on ] || return 0

  if [ -f "$WHISTLE_DETECT_PIDFILE" ]; then
    whistle_detect_pid_alive "$(cat "$WHISTLE_DETECT_PIDFILE" 2> /dev/null)" && return 0
  fi

  whistle_tmux run-shell -b "'$WHISTLE_ROOT/lib/detect.sh' loop"
}

# 直接执行时（例如 tmux run-shell 拉起的常驻进程）跑循环
case "${1:-}" in
loop) whistle_detect_loop ;;
once) whistle_detect_once ;;
*) whistle_detect_loop ;;
esac
