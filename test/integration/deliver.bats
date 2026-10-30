#!/usr/bin/env bats
# shellcheck shell=bash
#
# 四渠道投递。默认配置下 os 是 off、headless server 没有 client，
# 所以大部分用例验证的是"开关生效"与"不误伤用户配置"。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  wt_load status-line
  wt_load deliver
  unset TMUX_PANE TMUX TERM_PROGRAM __CFBundleIdentifier
}

teardown() {
  wt_stop
}

win_of() {
  wt display -p -t w1 '#{window_id}'
}

pane_of() {
  wt display -p -t w1 '#{pane_id}'
}

# 安装只记录 argv 的假后端，绝不把测试通知送到真实桌面。
fake_os_backend() {
  local name="$1" rc="${2:-0}"
  local dir="$BATS_TEST_TMPDIR/fake-os-bin"
  mkdir -p "$dir"
  FAKE_OS_LOG="$BATS_TEST_TMPDIR/fake-os.log"
  export FAKE_OS_LOG
  cat > "$dir/$name" <<EOF
#!/bin/sh
printf 'CALL $name\n' >> "\$FAKE_OS_LOG"
for arg do
  printf '%s\n' "\$arg" >> "\$FAKE_OS_LOG"
done
printf 'END\n' >> "\$FAKE_OS_LOG"
exit $rc
EOF
  chmod +x "$dir/$name"
  PATH="$dir:$PATH"
}

# 取 fake terminal-notifier 某个选项的值；参数在日志里各占一行。
fake_os_arg() {
  awk -v option="$1" '$0 == option { getline; print; exit }' "$FAKE_OS_LOG"
}

fake_os_calls() {
  awk '/^CALL / { print }' "$FAKE_OS_LOG"
}

# -- 编排 ------------------------------------------------------------------

@test "deliver: @whistle_enabled off 时什么都不做" {
  wt set -g @whistle_enabled off
  local w
  w=$(win_of)

  wt set -w -t "$w" pane-border-style 'fg=#123456'
  whistle_deliver "$w" "done" '做完了' "$(pane_of)"

  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#123456'
}

@test "deliver: 总开关开着时会走到边框通道" {
  local w
  w=$(win_of)
  whistle_deliver "$w" "done" '做完了' "$(pane_of)"
  assert_eq "$(wt show -wv -t "$w" @whistle_border_painted)" '1'
}

# -- 开关逐项生效 ----------------------------------------------------------

@test "开关: @whistle_border off 时边框不动" {
  wt set -g @whistle_border off
  local w
  w=$(win_of)
  whistle_deliver "$w" "done" 'x' "$(pane_of)"
  [ -z "$(wt show -wv -t "$w" @whistle_border_painted)" ]
}

@test "开关: @whistle_os off 时不调用任何通知命令" {
  fake_os_backend terminal-notifier
  fake_os_backend osascript
  fake_os_backend notify-send
  wt set -g @whistle_os off
  local w
  w=$(win_of)
  run whistle_os_notify "$w" "done" 'x' "$(pane_of)"
  assert_eq "$status" 0
  [ ! -e "$FAKE_OS_LOG" ]
}

@test "开关: @whistle_display off 时不写 message" {
  wt set -g @whistle_display off
  local w
  w=$(win_of)
  # 无 client 的 headless server 下 display-message 本就无目标，
  # 这里验证开关打开时也不崩
  run whistle_display_fanout "$w" "done" 'x'
  assert_eq "$status" 0
}

# -- 扇出目标：@whistle_self --------------------------------------------------
#
# 打桩 whistle_tmux 记录 display-message 的 -t 参数。headless server 没有
# attached client，list-clients 是空的，不打桩就只能断言 "不崩" —— 而这正是
# 本 bug 长期没被发现的原因（旧的 @whistle_self 用例只断言了 status==0）。

stub_display_targets() {
  local calls="$1"; shift
  : > "$calls"

  # _sd_calls / _sd_clients 必须用全局变量：whistle_tmux 是在这里定义的，
  # 但调用它的是测试体 —— 本函数早已返回，local 变量随之失效，
  # 打桩就会安静地返回空（正是这个坑让第一版用例假绿）。
  _sd_calls="$calls"
  _sd_clients=$(printf '%s\n' "$@")

  # 复制原函数留个后门：配置读取（show）必须仍走真实 tmux。
  # 否则 whistle_conf 拿到空值会回落到默认值表，开关设了也不生效。
  eval "_sd_real_tmux() $(declare -f whistle_tmux | tail -n +2)"

  # shellcheck disable=SC2329  # 由被 source 的 deliver 函数间接调用
  whistle_tmux() {
    case "${1:-}" in
    display-message)
      case "$*" in
      *"#{session_name}"*) printf 'origin-sess' ;;
      *) printf '%s\n' "$*" >> "$_sd_calls" ;;
      esac
      ;;
    list-clients) printf '%s' "$_sd_clients" ;;
    *) _sd_real_tmux "$@" ;;
    esac
    return 0
  }
}

@test "display: @whistle_self off 时不提示发起方所在的 session" {
  wt set -g @whistle_display on
  wt set -g @whistle_self off
  local calls="$BATS_TEST_TMPDIR/self_off"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  whistle_display_fanout "$w" "done" 'x'

  # 断言 -t 目标而不是裸 session 名：消息体本身是 "[origin-sess] 完成: x"，
  # 里面就含 origin-sess 这个字符串。
  run cat "$calls"
  assert_contains "$output" '-t other-sess'
  assert_eq "$(count_occurrences "$output" '-t origin-sess')" 0
}

@test "display: @whistle_self on 时也提示发起方所在的 session" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/self_on"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  whistle_display_fanout "$w" "done" 'x'

  run cat "$calls"
  assert_contains "$output" '-t origin-sess'
  assert_contains "$output" '-t other-sess'
}

@test "display: 扇出按 session 去重，同一 session 的两个 client 只收一次" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/dedup"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess other-sess

  whistle_display_fanout "$w" "done" 'x'

  run cat "$calls"
  assert_eq "$(count_occurrences "$output" '-t other-sess')" 1
}

# -- running 不打扰 ---------------------------------------------------------
#
# 回归：whistle_deliver 曾经对所有状态无条件扇出。而 UserPromptSubmit 会把状态
# 置成 running —— 于是每敲一次 prompt，其它 session 就收到一条「运行中」。
# 徽章早就屏蔽了 running，另外两个渠道漏了。

@test "deliver: running 不发瞬时提示（每敲一次 prompt 不该刷屏）" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/run_no_display"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  whistle_deliver "$w" "running" '' "$(pane_of)"

  run cat "$calls"
  assert_eq "$output" ''
}

@test "deliver: running 不改边框（边框只为待处理状态着色）" {
  wt set -g @whistle_border on
  local w
  w=$(win_of)
  wt set -w -t "$w" pane-border-style 'fg=#123456'

  whistle_deliver "$w" "running" '' "$(pane_of)"

  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#123456'
}

@test "deliver: done 仍然扇出（防止把正常通知一并关掉）" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/done_still_display"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  whistle_deliver "$w" "done" 'x' "$(pane_of)"

  run cat "$calls"
  assert_contains "$output" '-t other-sess'
}

# -- 有效态语义（第二个参数现在是 @whistle_eff，不是原始状态） ----------------
#
# 有效态 = 活动通道与通知通道按 rank 取高者（error 5 > wait 4 > done 3 >
# running 2 > idle 1）。于是有一条等价关系：
#   「有事等你」⟺「有效态是通知态」
# 因为只要通知通道有值，它的 rank 就必然高过 running / idle —— 通知态一旦存在
# 就一定赢下有效态。deliver 因此不需要再读通知通道，只看这一个参数就够。

@test "deliver: 打扰用户 ⟺ 有效态是通知态（running / idle 不打扰）" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/eff_equiv"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess other-sess

  # 词表必须放进变量：`for st in ... done ...` 里的字面量 done 会被
  # shell / ShellCheck 当成循环终止符（SC1010）。项目红线不用数组，
  # 所以走「一个带前缀的变量 + 无引号展开」这条可移植写法。
  local st body sts='running idle done wait error'
  for st in $sts; do
    : > "$calls"
    whistle_deliver "$w" "$st" 'x' "$(pane_of)"
    body=$(cat "$calls")
    case "$st" in
    done | wait | error)
      assert_contains "$body" '-t other-sess'
      ;;
    *)
      assert_eq "$body" ''
      ;;
    esac
  done
}

@test "deliver: 有效态是 idle 时不染边框（边框只为待处理态着色）" {
  wt set -g @whistle_border on
  local w
  w=$(win_of)
  wt set -w -t "$w" pane-border-style 'fg=#123456'

  whistle_deliver "$w" "idle" '' "$(pane_of)"

  assert_eq "$(wt show -wv -t "$w" pane-border-style)" 'fg=#123456'
  [ -z "$(wt show -wv -t "$w" @whistle_border_painted)" ]
}

@test "deliver: 边框色按有效态取（done / wait / error 各自一色）" {
  local w
  w=$(win_of)

  whistle_deliver "$w" "wait" '要授权' "$(pane_of)"
  assert_eq "$(wt show -wv -t "$w" pane-border-style)" "fg=$(whistle_conf '@whistle_color_wait')"

  whistle_deliver "$w" "error" '挂了' "$(pane_of)"
  assert_eq "$(wt show -wv -t "$w" pane-border-style)" "fg=$(whistle_conf '@whistle_color_error')"

  whistle_deliver "$w" "done" '做完了' "$(pane_of)"
  assert_eq "$(wt show -wv -t "$w" pane-border-style)" "fg=$(whistle_conf '@whistle_color_done')"
}

@test "deliver: 有效态是通知态时，消息体用通知消息与对应标签" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local calls="$BATS_TEST_TMPDIR/eff_msg"
  local w
  w=$(win_of)
  stub_display_targets "$calls" origin-sess

  whistle_deliver "$w" "done" '重构完成' "$(pane_of)"

  run cat "$calls"
  # 有效态 done → 走「完成」标签 + 与有效态对应的消息
  assert_contains "$output" '完成: 重构完成'
  assert_contains "$output" '[origin-sess]'
}

# -- 状态栏重画门控（KP-15） -----------------------------------------------

@test "KP-15: 只刷新受影响 session 的 client，且带 -S（只刷状态栏）" {
  # 打桩 tmux：把调用记录下来，避免依赖真实 attached client
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"

  # shellcheck disable=SC2329  # 由被 source 的 whistle_refresh_sessions 间接调用
  whistle_tmux() {
    case "${1:-}" in
    display-message) printf 'target-sess' ;;
    list-clients) printf 'c1 target-sess\nc2 other-sess\n' ;;
    refresh-client) printf '%s\n' "$*" >> "$calls" ;;
    esac
    return 0
  }

  whistle_refresh_sessions '@1'

  run cat "$calls"
  assert_contains "$output" '-t c1 -S'
  # 不在目标 session 的 client 不该被刷
  assert_not_contains "$output" 'c2'
}

@test "KP-15: 没有 client 时不发任何 refresh" {
  local calls="$BATS_TEST_TMPDIR/calls2"
  : > "$calls"

  # shellcheck disable=SC2329  # 由被 source 的 whistle_refresh_sessions 间接调用
  whistle_tmux() {
    case "${1:-}" in
    display-message) printf 'target-sess' ;;
    list-clients) printf '' ;;
    refresh-client) printf '%s\n' "$*" >> "$calls" ;;
    esac
    return 0
  }

  whistle_refresh_sessions '@1'
  run cat "$calls"
  assert_eq "$output" ''
}

@test "KP-15: 无 attached client 时真实 refresh 直接跳过，不报错" {
  local w
  w=$(win_of)
  run whistle_refresh_sessions "$w"
  assert_eq "$status" 0
  run whistle_refresh_all
  assert_eq "$status" 0
}

# -- 瞬时提示的消息文案 ----------------------------------------------------

@test "display: 消息体含 session、状态标签与消息文本" {
  wt set -g @whistle_display on
  wt set -g @whistle_self on
  local w
  w=$(win_of)
  run whistle_display_fanout "$w" "done" '重构完成'
  assert_eq "$status" 0
}

# -- 系统通知 --------------------------------------------------------------

@test "os: AppleScript 字符串转义（消息含引号与反斜杠时不会破命令）" {
  local esc
  esc=$(whistle_osa_escape 'he said "hi"\back')
  assert_contains "$esc" '\"hi\"'
  assert_contains "$esc" '\\back'
}

@test "os: group 由 socket 与精确 pane 组成，同 pane 稳定、不同 pane 独立" {
  local first second
  first=$(whistle_os_group '%12')
  second=$(whistle_os_group '%12')
  assert_eq "$first" "tmux-whistle:$WHISTLE_TMUX_SOCKET:%12"
  assert_eq "$second" "$first"
  [ "$(whistle_os_group '%13')" != "$first" ]
}

@test "os: terminal-notifier 收到 subtitle、逐 pane group 与原消息" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os on
  local w p
  w=$(win_of)
  p=$(pane_of)

  whistle_os_notify "$w" "done" '重构完成' "$p"

  assert_eq "$(fake_os_arg -title)" 'tmux · main'
  assert_eq "$(fake_os_arg -subtitle)" 'w1'
  assert_eq "$(fake_os_arg -message)" '完成: 重构完成'
  assert_eq "$(fake_os_arg -group)" "$(whistle_os_group "$p")"
  assert_eq "$(fake_os_calls)" 'CALL terminal-notifier'
}

@test "os: execute 固定 socket、绝对 CLI、精确 pane 与可用 PATH" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os on
  local w p tmux_dir expected
  w=$(win_of)
  p=$(pane_of)
  tmux_dir=$(dirname "$(command -v tmux)")
  # shellcheck disable=SC2030,SC2031  # WHISTLE_SELF 只供本 @test 的通知构造函数读取
  export WHISTLE_SELF="/opt/tmux whistle/it's/tmux-whistle"

  whistle_os_notify "$w" wait '要授权' "$p"

  expected="PATH='$tmux_dir:/usr/bin:/bin:/usr/sbin:/sbin' WHISTLE_TMUX_SOCKET='$WHISTLE_TMUX_SOCKET' '/opt/tmux whistle/it'\"'\"'s/tmux-whistle' --desktop-jump '$p'"
  assert_eq "$(fake_os_arg -execute)" "$expected"
}

@test "os: execute 经 /bin/sh -c 后保留特殊 CLI 与 socket 的 argv 和环境" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os on
  local w p fake_cli special_socket execute expected_path expected
  w=$(win_of)
  p=$(pane_of)
  fake_cli="$BATS_TEST_TMPDIR/cli dir/it's/tmux-whistle"
  special_socket="$BATS_TEST_TMPDIR/socket dir/it's/default"
  mkdir -p "$(dirname "$fake_cli")"
  export M4_EXECUTE_LOG="$BATS_TEST_TMPDIR/execute-env.log"
  cat > "$fake_cli" <<'EOF'
#!/bin/sh
printf 'argc=%s\n' "$#" > "$M4_EXECUTE_LOG"
for _arg do
  printf 'arg=%s\n' "$_arg" >> "$M4_EXECUTE_LOG"
done
printf 'socket=%s\n' "$WHISTLE_TMUX_SOCKET" >> "$M4_EXECUTE_LOG"
printf 'path=%s\n' "$PATH" >> "$M4_EXECUTE_LOG"
printf 'self=%s\n' "$0" >> "$M4_EXECUTE_LOG"
EOF
  chmod +x "$fake_cli"
  # shellcheck disable=SC2030,SC2031  # WHISTLE_SELF 只供本 @test 的通知构造函数读取
  export WHISTLE_SELF="$fake_cli"

  # 只伪造 socket 查询；session/window 查询仍走隔离 server。
  # 特殊 socket 不需要存在：稍后的 fake CLI 只记录环境，绝不连接 tmux。
  _m4_socket="$special_socket"
  eval "_m4_real_tmux() $(declare -f whistle_tmux | tail -n +2)"
  whistle_tmux() {
    case "$*" in
    *'#{socket_path}'*) printf '%s' "$_m4_socket" ;;
    *) _m4_real_tmux "$@" ;;
    esac
  }

  whistle_os_notify "$w" wait '要授权' "$p"
  execute=$(fake_os_arg -execute)
  run /bin/sh -c "$execute"

  assert_eq "$status" 0
  expected_path="$(dirname "$(command -v tmux)"):/usr/bin:/bin:/usr/sbin:/sbin"
  expected="argc=2
arg=--desktop-jump
arg=$p
socket=$special_socket
path=$expected_path
self=$fake_cli"
  assert_eq "$(cat "$M4_EXECUTE_LOG")" "$expected"
}

@test "os: activate 优先显式配置，可识别环境才自动映射" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os on
  wt set -g @whistle_os_app 'com.example.Terminal'
  export TERM_PROGRAM='unknown-terminal'

  whistle_os_notify "$(win_of)" "done" 'x' "$(pane_of)"
  assert_eq "$(fake_os_arg -activate)" 'com.example.Terminal'

  : > "$FAKE_OS_LOG"
  wt set -g -u @whistle_os_app
  export TERM_PROGRAM='iTerm.app'
  whistle_os_notify "$(win_of)" "done" 'x' "$(pane_of)"
  assert_eq "$(fake_os_arg -activate)" 'com.googlecode.iterm2'

  : > "$FAKE_OS_LOG"
  export TERM_PROGRAM='unknown-terminal'
  whistle_os_notify "$(win_of)" "done" 'x' "$(pane_of)"
  run cat "$FAKE_OS_LOG"
  assert_not_contains "$output" '-activate'
}

@test "os: NSUserDefaults 特殊首字符按上游规则加前导反斜杠" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os on
  wt rename-window -t "$(win_of)" '[ops]'
  local value
  for value in '[x]' '(x)' '{x}' '"x' "'x"; do
    assert_eq "$(whistle_tn_value "$value")" "\\$value"
  done
  assert_eq "$(whistle_tn_value 'plain')" 'plain'

  whistle_os_notify "$(win_of)" "done" 'x' "$(pane_of)"
  assert_eq "$(fake_os_arg -subtitle)" '\[ops]'
}

@test "os: 后端按执行结果依次降级，最终失败也不影响调用方" {
  fake_os_backend terminal-notifier 3
  fake_os_backend osascript 1
  fake_os_backend notify-send 1
  wt set -g @whistle_os on
  local p
  p=$(pane_of)
  wt set -p -t "$p" @whistle running
  wt set -p -t "$p" @whistle_notice "done"

  whistle_os_notify "$(win_of)" "done" 'x' "$p"
  assert_eq "$?" 0
  assert_eq "$(fake_os_calls)" 'CALL terminal-notifier
CALL osascript
CALL notify-send'
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
}

@test "os: terminal-notifier 失败而 osascript 成功时绝不调用 notify-send" {
  fake_os_backend terminal-notifier 3
  fake_os_backend osascript
  fake_os_backend notify-send
  wt set -g @whistle_os on

  run whistle_os_notify "$(win_of)" "done" 'x' "$(pane_of)"

  assert_eq "$status" 0
  assert_eq "$(fake_os_calls)" 'CALL terminal-notifier
CALL osascript'
}

@test "os: running 与 idle 即使打开桌面开关也不发送" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os on
  local w p
  w=$(win_of)
  p=$(pane_of)

  whistle_deliver "$w" running '' "$p"
  whistle_deliver "$w" idle '' "$p"

  [ ! -e "$FAKE_OS_LOG" ]
}

@test "os: forget 在开关 off 时仍精确撤回，且不改活动通道" {
  fake_os_backend terminal-notifier
  wt set -g @whistle_os off
  local p
  p=$(pane_of)
  wt set -p -t "$p" @whistle running

  whistle_os_forget "$p"
  assert_eq "$?" 0
  assert_eq "$(fake_os_arg -remove)" "$(whistle_os_group "$p")"
  run awk '$0 == "ALL"' "$FAKE_OS_LOG"
  assert_eq "$output" ''
  assert_eq "$(optp @whistle "$p")" 'running'
}

@test "os: 没有任何通知命令时不报错，只记日志" {
  # PATH 只保留隔离 server 所需的 tmux，确保不会触达真实桌面后端。
  local oldpath="$PATH" bin="$BATS_TEST_TMPDIR/no-os-backend"
  mkdir -p "$bin"
  ln -s "$(command -v tmux)" "$bin/tmux"
  wt set -g @whistle_os on
  PATH="$bin"
  run whistle_os_notify "$(win_of)" "done" 'x' "$(pane_of)"
  PATH="$oldpath"
  assert_eq "$status" 0
}
# -- 自愈：主题重载覆盖补丁后，投递时能补回来 --------------------------------

@test "自愈: status-right 被主题覆盖后，deliver 会重新打上补丁" {
  whistle_mark_publish
  whistle_status_right_publish

  # 模拟 oh-my-mux 重算主题：把两处格式整个换掉
  wt set -g window-status-format 'THEME-REWRITTEN'
  wt set -g status-right 'THEME-RIGHT'

  local w
  w=$(win_of)
  whistle_deliver "$w" "done" 'x' "$(pane_of)"

  run opt 'window-status-format'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_mark}')" "1"

  run opt 'status-right'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_status_right}')" "1"
}

@test "自愈: 连续 deliver 三次仍只有一处哨兵" {
  local w
  w=$(win_of)
  whistle_deliver "$w" "done" 'a' "$(pane_of)"
  whistle_deliver "$w" "wait" 'b' "$(pane_of)"
  whistle_deliver "$w" "error" 'c' "$(pane_of)"

  run opt 'window-status-format'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_mark}')" "1"
  run opt 'status-right'
  assert_eq "$(count_occurrences "$output" '#{E:@whistle_status_right}')" "1"
}
