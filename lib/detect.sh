#!/bin/sh
# tmux-whistle 的读屏降级通道。
#
# 这是唯一「从屏幕文字里猜状态」的地方，也是**补充**而不是真源：
#   @whistle       agent 自己上报的活动态（hook）      ← 真源
#   @whistle_live  读屏分类出来的活动态（本文件）      ← 只在真源为空时生效
#   @whistle_notice 有没有事等你（wait 也走这里）
#
# 与 hooks 路径的关系：hook / migration 只要写下了 running / idle，就跳过该
# pane。bare src 与 gone 都是上一轮的残留，不能阻止同一 pane 的新 agent 回退
# 到读屏通道。
#
# 单实例：pidfile 守卫。进程由 tmux 的 run-shell -b 拉起，
# 常驻循环本身就是被 run-shell 托管的那条命令。

set -u

# 常驻轮询必须**关掉配置快照缓存**：它靠每轮重读 @whistle_detect 来感知用户关闭
# 检测（`while :; do [ "$(whistle_conf @whistle_detect)" = on ] || break`）。
WHISTLE_CONF_NO_CACHE=1
export WHISTLE_CONF_NO_CACHE

# 允许被 source（L1 单测直接加载这里的纯状态机）；直接执行时才自己推根目录。
if [ -z "${WHISTLE_ROOT:-}" ]; then
  WHISTLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fi
export WHISTLE_ROOT

# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/core.sh"
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/detect-rules.sh"
# 投递链要整套加载：whistle_finish → whistle_deliver → whistle_ensure_status_line，
# 后者用的是 status-line.sh 里的 format 拼装。少 source 一个文件不会报错，
# 只会在运行期变成 `command not found` 落在守护进程的 stderr 里，
# 而状态栏因此只能等 status-interval 那一跳。
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/status-line.sh"
# shellcheck source=/dev/null
. "$WHISTLE_ROOT/lib/deliver.sh"

# 状态目录按 **socket** 隔离。
#
# 早先只按 uid 命名（/tmp/tmux-whistle-<uid>）：同一个用户同时跑着真 server
# 与测试的隔离 server 时，两边共用同一个 pidfile —— 隔离 server 的守护先起来，
# 真 server 的就被 pidfile 挡在门外（或反过来），其中一边的状态永远不更新，
# 而界面上完全看不出原因。凡「按 server 隔离」的状态都不该落按用户命名的文件。
# 允许外部（单测）用 WHISTLE_DETECT_STATE_DIR 指定隔离目录。
if [ -z "${WHISTLE_DETECT_STATE_DIR:-}" ]; then
  _ds_sock="${WHISTLE_TMUX_SOCKET:-${TMUX:-}}"
  _ds_sock=${_ds_sock%%,*}
  _ds_tag=$(printf '%s' "$_ds_sock" | cksum | cut -d' ' -f1)
  WHISTLE_DETECT_STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-whistle-$(id -u)-${_ds_tag}"
fi
WHISTLE_DETECT_PIDFILE="$WHISTLE_DETECT_STATE_DIR/detect.pid"

# 一轮扫描的 ps 快照：每个 tty 一行 `tty|argv0|完整命令行`。
#
# 为什么要快照：逐 pane 跑一次 `ps` 的话，15 个 pane 的 server 就是 15 次
# `ps`/秒，而绝大多数 pane 只是普通 shell。这里一次 `ps` 拿全，再在内存里按
# tty 找 —— `pid == tpgid` 的行就是该 tty 的前台进程组组长（子进程的 pid
# 不等于 tpgid，所以一个 tty 只会命中一行）。
#
# `#{pane_current_command}` 只给得出进程名，而 `codex exec` 与交互 TUI 的
# 进程名是同一个 —— 「是不是一次性子命令」只能看 argv。
whistle_detect_fg_snapshot() {
  ps -ax -o tty=,pid=,tpgid=,command= 2> /dev/null \
    | awk '$2 == $3 { print $1 "|" $4 "|" substr($0, index($0, $4)) }'
}

# whistle_detect_fg <快照> <pane_tty>
# 结果放 _dfg_name（argv[0]）与 _dfg_cmd（完整命令行），**不 echo** ——
# 调用点每个 pane 都跑一次，命令替换就是一次 fork。
#
# `while read ... done <<EOF` 不分子 shell，所以整趟都在当前进程里。
whistle_detect_fg() {
  _dfg_map="$1"
  _dfg_tty="${2#/dev/}"
  _dfg_name=''
  _dfg_cmd=''
  while IFS='|' read -r _dfg_t _dfg_n _dfg_c; do
    [ "$_dfg_t" = "$_dfg_tty" ] || continue
    _dfg_name=$_dfg_n
    # 命令行里可能有 '|'，剩下的全部落在最后一个变量里
    _dfg_cmd=$_dfg_c
    break
  done << EOF
$_dfg_map
EOF
}

# @whistle_detect 关掉时把每个 pane 上的 @whistle_live 清干净。
#
# 为什么必须清：tmux option 是内存态，不会因为「谁不再写它」而消失。
# 留着就是一片永久残留的 ◉ / ▶，而用户已经以为这个功能关了。
# ⚠️ 这里刻意用 `list-panes -f` 过滤，不写 `$( ... | while ...; do case ...)`
# —— macOS 自带的 `/bin/sh` 是 bash 3.2，它的**解析器**不接受 `$(` 直接跟着
# `case`（连 `$(case a in a) : ;; esac)` 都报 `syntax error near unexpected
# token ';;'`）。症状是整份脚本 sh -n 都过不了，而报错指在 case 那一行。
whistle_detect_clear_all() {
  _dca_panes=$(whistle_tmux list-panes -a -F '#{pane_id}' \
    -f '#{@whistle_live}#{@whistle_notice_src}' 2> /dev/null)
  [ -n "$_dca_panes" ] || return 0

  for _dca_p in $_dca_panes; do
    _dca_win=$(whistle_pane_window "$_dca_p")
    # 只收自己写的那条 wait；hook 写的通知一个字都不碰
    _dca_nsrc=$(whistle_tmux show -pqv -t "$_dca_p" @whistle_notice_src 2> /dev/null) || _dca_nsrc=''
    if [ "$_dca_nsrc" = detect ]; then
      whistle_state_clear "$_dca_p" > /dev/null
    fi
    whistle_live_set '' "$_dca_p" > /dev/null
    whistle_detect_forget "$_dca_p"
    # @whistle_win / @whistle_win_notice 是 window 级派生值，不重算就会
    # 留一格永不消失的 ▶ / ◉ —— 而这条正是「关掉开关」的回退路径。
    [ -n "$_dca_win" ] && whistle_recompute_window "$_dca_win"
  done
  whistle_recompute_global
}

whistle_detect_pid_alive() {
  _pid="$1"
  [ -n "$_pid" ] || return 1
  kill -0 "$_pid" 2> /dev/null
}

# whistle_detect_forget <pane>
# 丢掉这个 pane 的防抖状态。agent 退出、状态槽被清空、tmux option 与状态文件
# 对不上时都要调 —— 留下的 .last 会让下一次分类被当成「没有变化」而不写。
whistle_detect_forget() {
  _daf_id="${1#%}"
  command rm -f "$WHISTLE_DETECT_STATE_DIR/$_daf_id.last" \
    "$WHISTLE_DETECT_STATE_DIR/$_daf_id.pending" \
    "$WHISTLE_DETECT_STATE_DIR/$_daf_id.count" \
    "$WHISTLE_DETECT_STATE_DIR/$_daf_id.run_since"
}

# whistle_detect_apply <pane> <running|idle>
# exit 0 = 这一次应当真正写状态槽（状态变了）；exit 1 = 再等等。
#
# 防抖规则（D6）：
#   → running  **立即生效**。晚一拍才亮 ▶ 会让人以为 agent 没反应，
#              而且 running 本来就是「确认发生了」的那一侧。
#   其余切换   **连续两次**相同分类才生效。TUI 每帧重绘、光标闪烁都会让
#              屏幕瞬时看起来「空下来了」，一次就信会让 ▶ / ◉ 反复闪。
#
# 状态放文件而不是 tmux option：这是「连续次数」的进程内状态，
# 守护重启后从头计也无害（最坏多等一拍）。
whistle_detect_apply() {
  _dap_id="${1#%}"
  _dap_state="$2"

  _dap_last_file="$WHISTLE_DETECT_STATE_DIR/$_dap_id.last"
  _dap_pend_file="$WHISTLE_DETECT_STATE_DIR/$_dap_id.pending"
  _dap_cnt_file="$WHISTLE_DETECT_STATE_DIR/$_dap_id.count"

  _dap_last=''
  if [ -f "$_dap_last_file" ]; then
    _dap_last=$(cat "$_dap_last_file" 2> /dev/null)
  fi
  # 供调用方判断「刚刚发生了什么转变」（running → idle 要补一条 done）
  _dap_prev="$_dap_last"
  if [ "$_dap_state" = "$_dap_last" ]; then
    # 又看到了与已生效状态一致的分类 —— 中间那次「想切换」的观察作废。
    # 不清的话，running / idle 交替闪烁时 pending 计数会被攒起来，
    # 下一次 idle 直接命中阈值，防抖等于没做。
    command rm -f "$_dap_pend_file" "$_dap_cnt_file"
    return 1
  fi

  if [ "$_dap_state" = running ]; then
    # 记下这一轮从什么时候开始跑：补 done 的时长闸要用它。
    # 只在缺失时写，否则每次扫描都会把起点推后。
    if [ ! -f "$WHISTLE_DETECT_STATE_DIR/$_dap_id.run_since" ]; then
      whistle_now > "$WHISTLE_DETECT_STATE_DIR/$_dap_id.run_since"
    fi
    printf '%s' "$_dap_state" > "$_dap_last_file"
    command rm -f "$_dap_pend_file" "$_dap_cnt_file"
    return 0
  fi

  _dap_pend=''
  if [ -f "$_dap_pend_file" ]; then
    _dap_pend=$(cat "$_dap_pend_file" 2> /dev/null)
  fi
  _dap_cnt=0
  if [ -f "$_dap_cnt_file" ]; then
    _dap_cnt=$(cat "$_dap_cnt_file" 2> /dev/null)
  fi
  case "$_dap_cnt" in
  '' | *[!0-9]*) _dap_cnt=0 ;;
  esac

  if [ "$_dap_state" = "$_dap_pend" ]; then
    _dap_cnt=$((_dap_cnt + 1))
  else
    _dap_pend="$_dap_state"
    _dap_cnt=1
  fi
  printf '%s' "$_dap_pend" > "$_dap_pend_file"
  printf '%s' "$_dap_cnt" > "$_dap_cnt_file"

  [ "$_dap_cnt" -ge 2 ] || return 1

  printf '%s' "$_dap_state" > "$_dap_last_file"
  command rm -f "$_dap_pend_file" "$_dap_cnt_file"
  return 0
}

# whistle_detect_done_fire <pane>
# 从 running 回落到 idle 时补一条「回合结束」通知。
#
# 读屏拿不到 `last_assistant_message`，但「在跑 → 停下来了」这个**转变本身**
# 就是可靠信号：用户至少能收到提醒，而不是只看到 ▶ 悄悄变成 ◉。
#
# 三条硬约束，缺一不发：
#   ① `@whistle_detect_done` 必须是 on
#   ② running 持续 ≥ `@whistle_detect_done_min`（默认 5 秒）——
#      TUI 重绘、瞬时闪烁都会造成假转变
#   ③ `@whistle_notice` 为空 —— 未读通知的 rank 更高，
#      覆盖等于把用户没看过的信息抹掉
#
# ⚠️ 只写通知通道，绝不写 @whistle（真源只放 agent 上报值）。
whistle_detect_done_fire() {
  _ddf_pane=$(whistle_resolve_pane "${1:-}")
  [ -n "$_ddf_pane" ] || return 1

  # 时长证据先读走：无论这一次发不发，这一轮的计时都到此结束。
  # 不清的话，下一轮 running 会沿用上一次的起点，短回合也会被判成「够长」。
  _ddf_since_file="$WHISTLE_DETECT_STATE_DIR/${_ddf_pane#%}.run_since"
  _ddf_since=''
  if [ -f "$_ddf_since_file" ]; then
    _ddf_since=$(cat "$_ddf_since_file" 2> /dev/null)
    command rm -f "$_ddf_since_file"
  fi
  case "$_ddf_since" in
  '' | *[!0-9]*) return 1 ;;
  esac

  [ "$(whistle_conf '@whistle_detect_done')" = on ] || return 1

  _ddf_min=$(whistle_conf '@whistle_detect_done_min')
  case "$_ddf_min" in
  '' | *[!0-9]*) _ddf_min=5 ;;
  esac
  [ $(($(whistle_now) - _ddf_since)) -ge "$_ddf_min" ] || return 1

  _ddf_notice=$(whistle_tmux show -pqv -t "$_ddf_pane" @whistle_notice 2> /dev/null) || _ddf_notice=''
  [ -z "$_ddf_notice" ] || return 1

  whistle_notice_set 'done' '检测到回合结束' '' "$_ddf_pane" > /dev/null || return 1
  return 0
}

# 写完之后的重算与投递。
# 只有**真的变了**才走到这里：每秒每 pane 全量重算会把 tmux 命令队列压满。
#
# 直接调 whistle_finish（lib/deliver.sh）：与 CLI 的命令路径是同一份编排。
# 早先这里自己写了一套「重算 window + refresh_sessions + 重算 global」，
# 少了投递 —— 读屏补的那条 done 于是只有徽章变，边框 / 瞬时提示 / 桌面通知
# 全都不发；refresh_sessions 还因为 detect.sh 没 source deliver.sh 而
# `command not found`（状态栏只能等 status-interval 那一跳）。
whistle_detect_sync() {
  whistle_finish "$1" "${2:-}"
}

# 用户填的轮询间隔。非数字 / 0 / 负数一律回落默认值 —— `sleep 1s` 在 BSD
# 上会立刻失败，`sleep 0` 也是，循环就会变成忙等 + fork 风暴。
whistle_detect_interval_value() {
  _div_v="${1:-}"
  case "$_div_v" in
  '' | *[!0-9]*) _div_v='' ;;
  esac
  if [ -z "$_div_v" ] || [ "$_div_v" -lt 1 ]; then
    printf '15'
    return 0
  fi
  printf '%s' "$_div_v"
}

# 升级迁移：上一版的 pidfile 在按 uid 命名的老目录里（不含 socket 哈希）。
# 那个守护跑的是旧代码（会把每个安静下来的 pane 写成 wait），而新目录的
# pidfile 守卫看不见它 —— 于是两个守护会并存。启动前先把它收掉。
whistle_detect_kill_legacy() {
  _dkl_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-whistle-$(id -u)"
  [ "$_dkl_dir" = "$WHISTLE_DETECT_STATE_DIR" ] && return 0
  _dkl_pidfile="$_dkl_dir/detect.pid"
  [ -f "$_dkl_pidfile" ] || return 0
  _dkl_pid=$(cat "$_dkl_pidfile" 2> /dev/null)
  if whistle_detect_pid_alive "$_dkl_pid"; then
    kill "$_dkl_pid" 2> /dev/null
  fi
  command rm -f "$_dkl_pidfile"
}

# 一次扫描。返回 0 表示做了至少一次状态变更。
whistle_detect_once() {
  _dv_cmds=$(whistle_conf '@whistle_agent_cmds')
  # 用户自定义的 wait 判据：**只在非空时**作为额外一条规则叠加。
  # 早先的实现里它是空的，而 `grep -qE ""` 匹配一切 —— 每个安静下来的
  # pane 都会被写成 wait，且没有任何报错。
  _dv_wait_re=$(whistle_conf '@whistle_detect_wait-re')

  mkdir -p "$WHISTLE_DETECT_STATE_DIR" 2> /dev/null || return 0
  command rm -f "$WHISTLE_DETECT_STATE_DIR/agent_seen"

  _dv_panes=$(whistle_tmux list-panes -a \
    -F '#{pane_id}|#{pane_current_command}|#{@whistle}|#{@whistle_src}|#{@whistle_live}|#{@whistle_notice}|#{@whistle_notice_src}|#{pane_tty}' 2> /dev/null)

  # 一轮一次 ps（见 whistle_detect_fg_snapshot）
  _dv_fg=$(whistle_detect_fg_snapshot)

  printf '%s\n' "$_dv_panes" | while IFS='|' read -r _dv_pane _dv_cmd _dv_act _dv_src _dv_live _dv_notice _dv_nsrc _dv_tty; do
    case "${_dv_pane:-}" in
    '%'*) ;;
    *) continue ;;
    esac

    # 仲裁：只有 hook / migration 写下了 running / idle 才算接管。
    # gone 是上一轮退出的墓碑；残留的 src 本身也不能让同一 pane 的新 agent
    # 永久失去读屏回退。
    case "${_dv_src:-}" in
    hook | migration)
      case "${_dv_act:-}" in
      running | idle) continue ;;
      esac
      ;;
    esac

    whistle_detect_fg "$_dv_fg" "$_dv_tty"
    _dv_argv=$_dfg_cmd
    _dv_name=$(whistle_detect_name "$_dv_cmd" "$_dv_argv")
    _dv_kind=$(whistle_agent_kind "$_dv_name")

    # 不是认识的 agent、没有规则表、或不是交互式进程 → 清掉可能残留的
    # live 就收工。读屏对它没有任何可信结论，留着旧值就是一盏永不熄灭的 ▶。
    # 「没有规则表」（opencode）也必须在这里挡掉：否则每轮 capture-pane + ps
    # 永远得不出结论，还把节奏钉在 1 秒。
    if [ -z "$_dv_kind" ] || ! whistle_classify_supported "$_dv_kind" \
      || ! whistle_detect_eligible "$_dv_cmd" "$_dv_argv" "$_dv_cmds"; then
      _dv_dirty=0
      if [ -n "${_dv_live:-}" ]; then
        whistle_live_set '' "$_dv_pane" > /dev/null
        whistle_detect_forget "$_dv_pane"
        _dv_dirty=1
      fi
      # 这条 wait 是本通道写的、agent 已经不在了 —— 一并收掉，
      # 否则一个没有进程的 pane 会挂着「等你批准」。
      if [ "${_dv_notice:-}" = wait ] && [ "${_dv_nsrc:-}" = detect ]; then
        whistle_state_clear "$_dv_pane" > /dev/null
        _dv_dirty=1
      fi
      [ "$_dv_dirty" = 1 ] && whistle_detect_sync "$_dv_pane" ''
      continue
    fi

    # 有 agent 在跑 → 告诉循环这一轮该按 1 秒的节奏接着扫
    : > "$WHISTLE_DETECT_STATE_DIR/agent_seen"

    # tmux option 是内存态（server 重启就没了），状态文件却留在 /tmp 里。
    # 两者对不上时以 tmux 为准 —— 留着 .last 会让下一次分类被当成
    # 「没有变化」，于是一个刚重启的 server 永远等不到 live 写入。
    if [ -z "${_dv_live:-}" ] && [ -f "$WHISTLE_DETECT_STATE_DIR/${_dv_pane#%}.last" ]; then
      whistle_detect_forget "$_dv_pane"
    fi

    _dv_screen=$(whistle_tmux capture-pane -p -J -t "$_dv_pane" 2> /dev/null)
    _dv_state=$(printf '%s\n' "$_dv_screen" | whistle_classify_screen "$_dv_kind")
    if [ -n "$_dv_wait_re" ] && printf '%s\n' "$_dv_screen" | grep -qE "$_dv_wait_re"; then
      _dv_state='wait'
    fi

    case "$_dv_state" in
    running | idle)
      # 防抖：running 立即生效，其余要连续两次（见 whistle_detect_apply）
      whistle_detect_apply "$_dv_pane" "$_dv_state" || continue
      whistle_live_set "$_dv_state" "$_dv_pane" > /dev/null || continue
      _dv_sync_state=$_dv_state
      # 收掉本通道自己写的那条 wait：批准之后屏幕已经回到「在跑 / 空闲」，
      # 而焦点自始至终没动过 —— 没有任何 after-select-* 会触发已读路径。
      # 只认 wait：done 是「这一轮做完了」的历史提醒，不该被下一轮抹掉。
      # hook / 用户写的通知（src != detect）一律不碰。
      if [ "${_dv_notice:-}" = wait ] && [ "${_dv_nsrc:-}" = detect ]; then
        whistle_state_clear "$_dv_pane" > /dev/null
      fi
      # 刚才还在跑、现在停了 → 补一条回合结束通知（只走通知通道）
      if [ "$_dv_state" = idle ] && [ "${_dap_prev:-}" = running ]; then
        # done 是本轮刚写入的通知通道，必须把“这次写的是通知”告诉
        # whistle_finish；仍传 idle 会被“活动写入不重放旧通知”的保护拦掉。
        whistle_detect_done_fire "$_dv_pane" && _dv_sync_state='done'
      fi
      ;;
    wait)
      # 已有通知时不覆盖 —— 但 wait 的 rank 是 4，比重算后可能还留着的
      # done(3) / running(2) / idle(1) 都高，写它是**升级**不是覆盖。
      # 只挡同级的 wait 与更高的 error。
      _dv_rank=$(whistle_rank "${_dv_notice:-}")
      if [ "$_dv_rank" -ge 4 ]; then
        continue
      fi
      WHISTLE_SRC=detect whistle_state_set "wait" '检测到等待输入' "$_dv_pane" > /dev/null || continue
      _dv_sync_state='wait'
      ;;
    *)
      # freeze 与「认不出来」都不动状态：滚动冻结只是视线离开底部，
      # 不代表 agent 停了；认不出来时宁可保持上一次的结论。
      continue
      ;;
    esac

    whistle_detect_sync "$_dv_pane" "$_dv_sync_state"
  done

  # 已经消失的 pane 没人再 forget 它，状态文件会一直堆在 /tmp 里。
  # 用本轮的 pane 列表做对照，纯 shell 遍历，不多 fork。
  for _dv_f in "$WHISTLE_DETECT_STATE_DIR"/*.last; do
    [ -f "$_dv_f" ] || continue
    _dv_fid=${_dv_f##*/}
    _dv_fid=${_dv_fid%.last}
    case "$_dv_panes" in
    *"$_dv_fid|"*) continue ;;
    esac
    whistle_detect_forget "%$_dv_fid"
  done

  return 0
}

whistle_detect_loop() {
  mkdir -p "$WHISTLE_DETECT_STATE_DIR" 2> /dev/null || exit 1
  whistle_detect_kill_legacy

  if [ -f "$WHISTLE_DETECT_PIDFILE" ]; then
    _old=$(cat "$WHISTLE_DETECT_PIDFILE" 2> /dev/null)
    if whistle_detect_pid_alive "$_old"; then
      exit 0 # 已有实例
    fi
  fi
  printf '%s' "$$" > "$WHISTLE_DETECT_PIDFILE"

  trap 'command rm -f "$WHISTLE_DETECT_PIDFILE" 2>/dev/null; exit 0' INT TERM EXIT

  while :; do
    if [ "$(whistle_conf '@whistle_detect')" = on ]; then
      :
    else
      # 用户把开关关了 —— 退出前把残留的 live 清掉，
      # 否则那一列会永远停在被关掉那一刻的样子。
      whistle_detect_clear_all
      break
    fi
    whistle_detect_once
    # 有 agent 在跑时按 1 秒扫（用户正盯着状态栏等这一轮结束）；
    # 没有 agent 就回到用户配的间隔 —— 别为一个纯 shell 的 server 每秒 fork。
    if [ -f "$WHISTLE_DETECT_STATE_DIR/agent_seen" ]; then
      sleep 1
    else
      sleep "$(whistle_detect_interval_value "$(whistle_conf '@whistle_detect_interval')")"
    fi
  done
}

# 由 setup.sh 调用：确保守护在跑，但不阻塞
whistle_detect_ensure_daemon() {
  [ "$(whistle_conf '@whistle_detect')" = on ] || return 0
  whistle_detect_kill_legacy

  if [ -f "$WHISTLE_DETECT_PIDFILE" ]; then
    whistle_detect_pid_alive "$(cat "$WHISTLE_DETECT_PIDFILE" 2> /dev/null)" && return 0
  fi

  whistle_tmux run-shell -b "'$WHISTLE_ROOT/lib/detect.sh' loop"
}

# 直接执行时（例如 tmux run-shell 拉起的常驻进程）跑循环
# ⚠️ 只有**直接执行**时才起循环。被 source（L1 单测加载纯状态机）时，
# `$1` 是测试框架自己的参数，照原样分派会误起守护 —— 而守护在开头就装了
# EXIT trap（清 pidfile），那个 trap 会打断 bats 的结果统计，
# 症状是「Executed N instead of expected M」，且失败的用例连一行都不打印。
if [ "${0##*/}" = detect.sh ]; then
  case "${1:-}" in
  loop) whistle_detect_loop ;;
  once) whistle_detect_once ;;
  *) whistle_detect_loop ;;
  esac
fi
