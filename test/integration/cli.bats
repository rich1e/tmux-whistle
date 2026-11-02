#!/usr/bin/env bats
# shellcheck shell=bash
#
# CLI 层：菜单参数构造、跳转、列表、开关、doctor。
#
# 菜单没法在无头 server 里真弹出来（display-menu 需要 attached client），
# 所以这里测的是参数构造 —— 那部分错了才是真 bug。

load '../test_helper/whistle'

setup() {
  wt_start
  wt_load core
  unset TMUX_PANE TMUX TMUX_SOCKET
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
}

teardown() {
  wt_stop
}

pane_of() {
  wt display -p -t w1 '#{pane_id}'
}

# 给 whistle_finish 接一个 deliver spy：CLI 与其余核心逻辑都跑真的，
# 只在最终投递边界记录参数，避免把「窗口聚合赢家」误当来源 pane。
make_deliver_spy_cli() {
  local root="$BATS_TEST_TMPDIR/deliver-spy"
  mkdir -p "$root/bin" "$root/lib"
  cp "$CLI" "$root/bin/tmux-whistle"
  ln -s "$WHISTLE_ROOT/lib/core.sh" "$root/lib/core.sh"
  ln -s "$WHISTLE_ROOT/lib/status-line.sh" "$root/lib/status-line.sh"
  ln -s "$WHISTLE_ROOT/lib/menu.sh" "$root/lib/menu.sh"
  cat > "$root/lib/deliver.sh" <<'EOF'
whistle_deliver() {
  printf '%s|%s|%s|%s|%s\n' "$#" "$1" "$2" "$3" "${4:-}" >> "$DELIVER_LOG"
}
EOF
  SPY_CLI="$root/bin/tmux-whistle"
}

# 桌面通知点击不能靠测试附着真实 client。这个 tmux stub 只伪造
# list-clients 与三步切换，其余查询和状态写入仍委派给隔离 server。
make_desktop_tmux_stub() {
  DESKTOP_REAL_TMUX=$(command -v tmux)
  DESKTOP_TMUX_BIN="$BATS_TEST_TMPDIR/desktop-tmux-bin"
  DESKTOP_TMUX_LOG="$BATS_TEST_TMPDIR/desktop-tmux.log"
  mkdir -p "$DESKTOP_TMUX_BIN"
  cat > "$DESKTOP_TMUX_BIN/tmux" <<'EOF'
#!/bin/sh
_socket="$FAKE_TMUX_SOCKET"
if [ "${1:-}" = '-S' ]; then
  _socket="$2"
  shift 2
fi
{
  _sep=''
  for _arg do
    printf '%s%s' "$_sep" "$_arg"
    _sep=' '
  done
  printf '\n'
} >> "$FAKE_TMUX_LOG"
case "${1:-}" in
list-clients)
  case " $* " in
  *client_activity*) printf '%s\n' "${FAKE_TMUX_CLIENTS:-}" ;;
  esac
  exit 0
  ;;
switch-client | select-window | select-pane)
  if [ "${FAKE_TMUX_FAIL:-}" = "$1" ]; then
    printf 'stub: %s 失败\n' "$1" >&2
    exit 1
  fi
  exit 0
  ;;
esac
exec "$REAL_TMUX" -S "$_socket" "$@"
EOF
  chmod +x "$DESKTOP_TMUX_BIN/tmux"
}

run_desktop_jump() {
  run env PATH="$DESKTOP_TMUX_BIN:$PATH" \
    REAL_TMUX="$DESKTOP_REAL_TMUX" \
    FAKE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    FAKE_TMUX_LOG="$DESKTOP_TMUX_LOG" \
    FAKE_TMUX_CLIENTS="${FAKE_TMUX_CLIENTS:-}" \
    FAKE_TMUX_FAIL="${FAKE_TMUX_FAIL:-}" \
    "$CLI" --desktop-jump "$1"
}

# popup 启动测试用 tmux spy 记录 argv；其它命令仍委派给隔离 server。
make_menu_popup_spy() {
  MENU_POPUP_REAL_TMUX=$(command -v tmux)
  MENU_POPUP_TMUX_BIN="$BATS_TEST_TMPDIR/menu-popup-tmux-bin"
  MENU_POPUP_TMUX_LOG="$BATS_TEST_TMPDIR/menu-popup-tmux.log"
  mkdir -p "$MENU_POPUP_TMUX_BIN"
  cat > "$MENU_POPUP_TMUX_BIN/tmux" <<'EOF'
#!/bin/sh
_socket="$FAKE_TMUX_SOCKET"
if [ "${1:-}" = '-S' ]; then
  _socket="$2"
  shift 2
fi
if [ "${1:-}" = display-popup ]; then
  printf '%s\n' "$@" > "$FAKE_TMUX_LOG"
  exit "${FAKE_TMUX_POPUP_RC:-0}"
fi
exec "$REAL_TMUX" -S "$_socket" "$@"
EOF
  chmod +x "$MENU_POPUP_TMUX_BIN/tmux"
}

run_menu_popup_spy() {
  run env PATH="$MENU_POPUP_TMUX_BIN:$PATH" \
    REAL_TMUX="$MENU_POPUP_REAL_TMUX" \
    FAKE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    FAKE_TMUX_LOG="$MENU_POPUP_TMUX_LOG" \
    FAKE_TMUX_POPUP_RC="${FAKE_TMUX_POPUP_RC:-0}" \
    "$CLI" menu
}

# -- 菜单 ------------------------------------------------------------------

@test "menu popup: 用 display-popup -E 启动内部 UI，不使用 -T" {
  "$CLI" idle
  make_menu_popup_spy

  run_menu_popup_spy

  assert_eq "$status" 0
  assert_eq "$(sed -n 1p "$MENU_POPUP_TMUX_LOG")" 'display-popup'
  assert_contains "$(cat "$MENU_POPUP_TMUX_LOG")" '-E'
  assert_contains "$(cat "$MENU_POPUP_TMUX_LOG")" '--menu-ui'
  assert_not_contains "$(cat "$MENU_POPUP_TMUX_LOG")" '-T'
}

@test "menu popup: 高度按项数要，条目不会被顶出屏幕" {
  # 独立评审 finding #3：默认高度装不下 26 项 + 标题时，先画的行被顶出屏幕，
  # 高亮还会移到看不见的地方。这里 1 项 → 1 + 4（标题/溢出提示/上下边框）= 5。
  "$CLI" idle
  make_menu_popup_spy

  run_menu_popup_spy

  assert_eq "$status" 0
  assert_eq "$(sed -n 3p "$MENU_POPUP_TMUX_LOG")" '-h'
  assert_eq "$(sed -n 4p "$MENU_POPUP_TMUX_LOG")" '5'
}

@test "menu popup: CLI 路径按单引号字面量交给 popup 的 shell" {
  # 独立评审 finding #4：双引号挡不住二次求值，路径里的 $ / 反引号会被再展开。
  "$CLI" idle
  make_menu_popup_spy

  run_menu_popup_spy

  assert_eq "$status" 0
  assert_eq "$(sed -n 5p "$MENU_POPUP_TMUX_LOG")" "'$CLI' --menu-ui"
}

@test "menu popup: popup 启动失败时保留原纯文本降级" {
  "$CLI" "done" '做完了'
  make_menu_popup_spy
  FAKE_TMUX_POPUP_RC=1

  run_menu_popup_spy

  assert_eq "$status" 0
  assert_eq "$(sed -n 1p "$MENU_POPUP_TMUX_LOG")" 'display-popup'
  assert_contains "$output" '做完了'
  assert_contains "$output" '[main]: w1'
}

@test "menu-args: 每项是 label / key / command 三元组" {
  "$CLI" "done" '做完了'
  run "$CLI" --menu-args
  assert_eq "$status" 0

  local n
  n=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  assert_eq "$n" 3

  local label key cmd
  label=$(printf '%s\n' "$output" | sed -n 1p)
  key=$(printf '%s\n' "$output" | sed -n 2p)
  cmd=$(printf '%s\n' "$output" | sed -n 3p)

  assert_contains "$label" '完成'
  assert_contains "$label" '[main]: w1'
  assert_contains "$label" '做完了'
  assert_eq "$key" '1'
  assert_contains "$cmd" 'switch-client -t main'
  assert_contains "$cmd" 'select-window -t @'
  assert_contains "$cmd" 'clear -t @'
}

@test "menu-args: session 名用 [] 裹住，与窗口名、消息分开" {
  # 菜单一行里挤着三样东西：session 名、窗口名、agent 的话。
  # 早先是 `完成 main:w1 做完了` —— session 名和内容糊在一起，
  # 看到 "main:w1" 只知道有个冒号，不知道哪一段才是 session。
  # 现在标题裹进 []：`完成 [main]: w1 做完了`。
  "$CLI" "done" '做完了'
  run "$CLI" --menu-args
  assert_eq "$status" 0

  local label
  label=$(printf '%s\n' "$output" | sed -n 1p)

  assert_contains "$label" '[main]: w1'
  # 只有 session 是「标题」：窗口名不裹，消息也不裹
  assert_contains "$label" 'w1 做完了'
  assert_not_contains "$label" '[w1]'
  assert_not_contains "$label" '[做完了]'
}

@test "menu-args: 多窗口时键位依次是 1 2 3" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p1 p2 p3
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  "$CLI" "done" 'a' -t "$p1"
  "$CLI" "wait" 'b' -t "$p2"
  "$CLI" "error" 'c' -t "$p3"

  run "$CLI" --menu-args
  local keys
  keys=$(printf '%s\n' "$output" | sed -n '2p;5p;8p')
  assert_eq "$keys" "1
2
3"
}

@test "menu-args: 一条 agent 都没有时输出为空" {
  run "$CLI" --menu-args
  assert_eq "$output" ''
}

# -- 菜单：running 也列出来（灰显、不可选） ---------------------------------

@test "menu-args: running 项也能跳（有快捷键、命令是真正的跳转）" {
  # 早期 running 项是 disabled（名称以 '-' 开头）—— 只能看不能点。
  # 但「跳到正在跑的窗口」是常见需求：想知道那个 agent 在干嘛、
  # 或者只是切过去看看。现在它与待处理项共用同一套键位。
  wt set -g @whistle_spin off
  wt new-window -d -n w2
  local p1 p2
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" '做完了' -t "$p1"
  "$CLI" running -t "$p2"

  run "$CLI" --menu-args
  assert_eq "$status" 0
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '6'

  # 第一组：待处理，键位 1
  assert_contains "$(printf '%s\n' "$output" | sed -n 1p)" '完成'
  assert_eq "$(printf '%s\n' "$output" | sed -n 2p)" '1'

  # 第二组：running，接着编号 2，且命令真的是跳转
  local label key cmd
  label=$(printf '%s\n' "$output" | sed -n 4p)
  key=$(printf '%s\n' "$output" | sed -n 5p)
  cmd=$(printf '%s\n' "$output" | sed -n 6p)

  assert_contains "$label" '运行中'
  # 前缀带颜色，取自 @whistle_color_running
  assert_contains "$label" '#[fg='
  # 菜单的 running 前缀是静态 ▶，与动画无关（帧画上去会冻住）
  assert_contains "$label" '▶'
  assert_eq "$key" '2'
  assert_contains "$cmd" 'select-window'
  assert_contains "$cmd" "$p2"
}

@test "menu-args: running 标记的颜色跟着 @whistle_color_running 走" {
  wt set -g @whistle_color_running '#00af00'
  wt set -g @whistle_spin off
  "$CLI" running

  run "$CLI" --menu-args
  assert_contains "$output" '#[fg=#00af00]▶'
}

@test "menu-args: 待处理项也带状态图标，与状态栏用同一套" {
  # 早先只有 running 项有前缀，done/wait/error 是裸的「 完成 sess:win」，
  # 两个界面看起来不是一回事。
  wt set -g @whistle_spin off
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p1 p2 p3
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  "$CLI" "done" 'a' -t "$p1"
  "$CLI" "wait" 'b' -t "$p2"
  "$CLI" error 'c' -t "$p3"

  run "$CLI" --menu-args
  assert_contains "$output" '#[fg=#af5fff]◆#[default] 完成'
  assert_contains "$output" '#[fg=#af8700]◔#[default] 等待'
  assert_contains "$output" '#[fg=#d70000]⚠#[default] 错误'
}

@test "menu-args: running 项的前缀是绿色 ▶（不是 Braille 帧）" {
  # 菜单是一次性绘制的静态快照，Braille 帧画上去就冻住了，看起来像渲染错乱
  # 而不是动画。
  #
  # ▶ = 在跑、◉ = 空闲，与状态栏语义一致。早先菜单借 ◉ 表示「在跑」，
  # 而状态栏里 ◉ 表示「空闲」—— 同一个字符含义正好相反。
  wt set -g @whistle_spin on
  wt set -g @whistle_spin_char '⠹'
  "$CLI" running

  run "$CLI" --menu-args
  assert_contains "$output" '#[fg=#00af00]▶#[default] 运行中'
  assert_not_contains "$output" '⠹'
}

@test "menu-args: @whistle_spin off 时 running 前缀仍是 ▶" {
  # 动画开关只影响状态栏，不该连带改菜单的图标
  wt set -g @whistle_spin off
  "$CLI" running

  run "$CLI" --menu-args
  assert_contains "$output" '#[fg=#00af00]▶#[default] 运行中'
}

@test "menu-args: 没上报过但前台跑着 agent 的窗口也列出来（◉ 空闲）" {
  # 这就是「恢复 tmux 后 3 个 agent 都在，但插件从没收到过它们的事件」的现场：
  # 靠 pane 的前台进程名把它们认成空闲。
  local cmd
  cmd=$(wt display -p -t w1 '#{pane_current_command}')
  wt set -g @whistle_agent_cmds "$cmd"

  run "$CLI" --menu-args
  assert_contains "$output" '#[fg=#8a8a8a]◉#[default] 空闲'
}

@test "menu-args: idle 项是灰色 ◉、标签是「空闲」" {
  # idle 是「进程在、没在干活」。它会出现在菜单里，与 running 分得开。
  wt set -g @whistle_spin off
  "$CLI" idle

  run "$CLI" --menu-args
  assert_contains "$output" '#[fg=#8a8a8a]◉#[default] 空闲'
}

@test "menu-args: 待处理在前、running 在后，共用同一串键位且互不重叠" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p1 p2 p3
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  "$CLI" "done" 'a' -t "$p1"
  "$CLI" running -t "$p2"
  "$CLI" "wait" 'b' -t "$p3"

  run "$CLI" --menu-args
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '9'

  local keys
  keys=$(menu_keys "$output")
  # 三个键位都非空（空 = 无快捷键 = 点不了）
  assert_eq "$(printf '%s\n' "$keys" | grep -c '^$')" 0
  # 两两不同
  assert_eq "$(printf '%s\n' "$keys" | sort -u | wc -l | tr -d ' ')" 3
  # 待处理先占 1、2，running 接 3
  assert_eq "$keys" "1
2
3"
}

@test "menu-args: 只有 running 时也列出来，而不是当作『没东西』" {
  "$CLI" running

  run "$CLI" --menu-args
  assert_eq "$status" 0
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '3'
  assert_contains "$output" '运行中'
}

@test "menu: 没有任何 agent 时报『没有 agent 上报过状态』" {
  run "$CLI" menu
  assert_eq "$status" 0
  assert_contains "$output" '没有 agent 上报过状态'
}

@test "menu: 依赖 tmux 的双横线来放行以 - 开头的条目名" {
  # disabled 条目（running 项）的名称以 '-' 开头，而 tmux 的参数解析会把它
  # 当 flag：没有 `--` 时报 "invalid flag -"，整个菜单弹不出来。
  # 这条用例把 tmux 侧的这条行为钉住 —— 哪天它变了，cmd_menu 的写法要跟着改。
  run wt display-menu -T t -- '- 运行中 main:w2' '' "display-message ''"
  assert_not_contains "$output" 'invalid flag'

  run wt display-menu -T t '- 运行中 main:w2' '' "display-message ''"
  assert_contains "$output" 'invalid flag'
}

# -- 键位（回归：第 10 项起曾算成空） ---------------------------------------

# 造 n 个待处理窗口（含 wt_start 自带的 w1）
seed_pending_windows() {
  local n="$1" i p
  for ((i = 2; i <= n; i++)); do
    wt new-window -d -n "w$i"
  done
  for ((i = 1; i <= n; i++)); do
    p=$(wt display -p -t "w$i" '#{pane_id}')
    "$CLI" "done" "m$i" -t "$p"
  done
}

# 每项是 label / key / command 三行，取每组的第 2 行
menu_keys() {
  printf '%s\n' "$1" | awk 'NR % 3 == 2'
}

seed_running_windows() {
  local n="$1" i p
  # 注意：seed_pending_windows 能省掉 i=1 是因为 wt_start 已经建了 w1。
  # 这里用的是自己的 r* 命名，必须从 i=1 建起。
  for ((i = 1; i <= n; i++)); do
    wt new-window -d -n "r$i"
  done
  for ((i = 1; i <= n; i++)); do
    p=$(wt display -p -t "r$i" '#{pane_id}')
    "$CLI" "running" -t "$p"
  done
}

@test "menu-args: 第 9 项是数字 9，第 10 项起接字母" {
  # 1-9 用数字，之后接字母表：第 10 项应落在字母表第 1 位。
  # 曾同时踩两个坑：位置算成 $1 - 10（第 10 项得到 0），且算术展开后多写了一个
  # ')'（cut 收到 "0)" 而非 "0"）。两者都让 cut 报错、stderr 被吞、key 变空。
  # 空 key 在 display-menu 里合法（表示"无快捷键"），所以菜单照常弹出、
  # 只是那一项不能用键选中 —— 不报错，靠断言才抓得到。
  seed_pending_windows 11

  run "$CLI" --menu-args
  assert_eq "$status" 0

  local keys
  keys=$(menu_keys "$output")
  assert_eq "$(printf '%s\n' "$keys" | sed -n 9p)" '9'
  assert_eq "$(printf '%s\n' "$keys" | sed -n 10p)" 'a'
  assert_eq "$(printf '%s\n' "$keys" | sed -n 11p)" 'b'
}

@test "menu-args: 满 26 项时键位全部非空且互不相同" {
  # 上限是 26（9 个数字 + 17 个字母，a..q），第 26 项是 q
  seed_pending_windows 26

  run "$CLI" --menu-args
  assert_eq "$status" 0

  local keys total nonempty distinct
  keys=$(menu_keys "$output")
  total=$(printf '%s\n' "$keys" | wc -l | tr -d ' ')
  nonempty=$(printf '%s\n' "$keys" | grep -c .)
  distinct=$(printf '%s\n' "$keys" | sort -u | wc -l | tr -d ' ')

  assert_eq "$total" 26
  assert_eq "$nonempty" 26
  assert_eq "$distinct" 26
  assert_eq "$(printf '%s\n' "$keys" | sed -n 26p)" 'q'
}

@test "menu-args: 超过 26 项时第 27 组是灰字提示，不是静默丢弃" {
  seed_pending_windows 28

  run "$CLI" --menu-args
  assert_eq "$status" 0

  # 27 个三元组 = 26 个可选项 + 1 个提示项
  local total
  total=$(menu_keys "$output" | wc -l | tr -d ' ')
  assert_eq "$total" 27

  # 前 26 个仍然可跳转 —— 提示项不能占用一个名额
  assert_eq "$(printf '%s\n' "$output" | grep -c '^switch-client')" 26

  assert_contains "$output" '- 还有 2 项未显示'
  assert_contains "$output" 'tmux-whistle list'
}

@test "menu-args: 提示项的快捷键为空（否则能被选走，退化成静默失败）" {
  seed_pending_windows 28

  run "$CLI" --menu-args

  # 最后一个三元组：三行依次是 label / 快捷键 / 命令
  local last
  last=$(printf '%s\n' "$output" | tail -n 3)
  assert_contains "$last" '- 还有'
  assert_eq "$(printf '%s\n' "$last" | sed -n 2p)" ''      # key 必须是空行
  assert_contains "$last" "display-message ''"           # 命令是空转
}

@test "menu-args: 不超 26 项时不加提示项" {
  seed_pending_windows 5

  run "$CLI" --menu-args
  assert_eq "$(menu_keys "$output" | wc -l | tr -d ' ')" 5
  assert_not_contains "$output" '未显示'
}

@test "menu-args: 恰好 26 项时不加提示项（边界）" {
  seed_pending_windows 26

  run "$CLI" --menu-args
  assert_eq "$(menu_keys "$output" | wc -l | tr -d ' ')" 26
  assert_not_contains "$output" '未显示'
}

@test "menu-args: running 也能跳，13 个都在 26 个键位之内" {
  seed_running_windows 13

  run "$CLI" --menu-args
  # 13 组、每组三行，键位全部有效
  assert_eq "$(menu_keys "$output" | wc -l | tr -d ' ')" 13
  assert_eq "$(printf '%s\n' "$output" | grep -c '^switch-client')" 13
  assert_not_contains "$output" '未显示'
}

@test "menu-args: 待处理占满 26 个键位时，running 被折叠进提示而不是消失" {
  seed_pending_windows 28
  seed_running_windows 13

  run "$CLI" --menu-args
  # 28 待处理 + 13 running = 41 项，键位只有 26 个
  assert_eq "$(printf '%s\n' "$output" | grep -c '^switch-client')" 26
  assert_contains "$output" '- 还有 15 项未显示'
}

@test "menu-args: 提示项不会占用可跳转的名额" {
  seed_pending_windows 28

  run "$CLI" --menu-args
  # 28 个窗口全是 done，但只有 26 个能跳
  assert_eq "$(printf '%s\n' "$output" | grep -c '^switch-client')" 26
  assert_eq "$(printf '%s\n' "$output" | grep -c 'w27\|w28')" 0
}

@test "menu-args: 命令里用的是 CLI 绝对路径（不依赖 PATH）" {
  "$CLI" "done" 'x'
  run "$CLI" --menu-args
  local cmd
  cmd=$(printf '%s\n' "$output" | sed -n 3p)
  assert_contains "$cmd" "$CLI"
}

@test "menu: 无 attached client 时降级成文本列表而不是失败" {
  "$CLI" "done" '做完了'
  run "$CLI" menu
  assert_eq "$status" 0
  assert_contains "$output" '做完了'
}

# -- jump ------------------------------------------------------------------

@test "jump: 按 session:window 跳转并清除" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  run "$CLI" jump 'other:api'
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "jump: 找不到目标时报错退出" {
  run "$CLI" jump 'nope:nothing'
  assert_eq "$status" 1
  assert_contains "$output" '找不到'
}

@test "jump: 裸窗口名可以跳（list 显示什么就能跳什么）" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  run "$CLI" jump 'api'
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p" @whistle_notice)" ''
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "jump: 裸窗口名撞名时报错列候选，不静默取第一个" {
  wt new-session -d -s other -n api
  wt new-window -d -t main -n api
  local p1 p3
  p1=$(wt display -p -t other:api '#{pane_id}')
  p3=$(wt display -p -t main:api '#{pane_id}')
  "$CLI" "done" 'A session 的' -t "$p1"
  "$CLI" "done" 'B session 的' -t "$p3"

  run "$CLI" jump 'api'
  assert_eq "$status" 1
  assert_contains "$output" 'other:api'
  assert_contains "$output" 'main:api'
  # 撞名时**不该**动任何一边
  assert_contains "$(wt show -pqv -t "$p1" @whistle_notice)" 'done'
  assert_contains "$(wt show -pqv -t "$p3" @whistle_notice)" 'done'
}

@test "jump: 裸窗口序号撞名时同样报错" {
  # 窗口名显式给 —— tmux 给新 session 的首个窗口起的是**当前 shell 的名字**
  # （zsh / bash / 取决于环境），拿它当断言会随开发机变化。
  wt new-session -d -s other -n svc
  local p1 p2
  p1=$(wt display -p -t other:svc '#{pane_id}')
  p2=$(wt display -p -t main:w1 '#{pane_id}')
  "$CLI" "done" 'A 的 0 号窗' -t "$p1"
  "$CLI" "done" 'B 的 0 号窗' -t "$p2"

  run "$CLI" jump '0'
  assert_eq "$status" 1
  # 候选一律显示 session:窗口名 —— 用户能直接粘回来用
  assert_contains "$output" 'other:svc'
  assert_contains "$output" 'main:w1'
}

@test "jump: 裸窗口名找不到时报错退出" {
  run "$CLI" jump 'nosuch'
  assert_eq "$status" 1
  assert_contains "$output" '找不到'
}

@test "jump: session:窗口 的显式写法在撞名时不受影响" {
  wt new-session -d -s other -n api
  wt new-window -d -t main -n api
  local p w p3
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  p3=$(wt display -p -t main:api '#{pane_id}')
  "$CLI" "done" 'other 的' -t "$p"
  "$CLI" "done" 'main 的' -t "$p3"

  run "$CLI" jump 'other:api'
  assert_eq "$status" 0
  # 只有 other 那一侧被清掉，main 的原地不动
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_contains "$(wt show -pqv -t "$p3" @whistle_notice)" 'done'
}

@test "jump: @whistle_win_pane 指向已死的 pane 时仍然清掉窗口" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  # 把 @whistle_win_pane 指向一个不存在的 pane —— 模拟「菜单开着的时候
  # 那一格被关掉」。select-pane 对着死 pane 会报错，而 tmux 的 `;` 命令链
  # 遇错即停，所以必须先判存活再 select，否则 clear 不会执行、状态永远清不掉。
  wt setw -t "$w" @whistle_win_pane '%999'

  run "$CLI" jump 'other:api'
  assert_eq "$status" 0
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "jump: @whistle_win_pane 为空时跳过 select-pane" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  # 没有 agent 在跑时窗口本就没有 pane 身份；jump 仍要能正常清。
  wt setw -t "$w" @whistle_win_pane ''

  run "$CLI" jump 'other:api'
  assert_eq "$status" 0
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

# -- 桌面通知：来源 pane 与严格跳转 -----------------------------------------

@test "deliver-pane: 通知写入把来源 pane 作为第四参下传" {
  make_deliver_spy_cli
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')

  run env DELIVER_LOG="$BATS_TEST_TMPDIR/deliver.log" \
    "$SPY_CLI" "done" '完成' -t "$p"
  assert_eq "$status" 0
  assert_eq "$(cat "$BATS_TEST_TMPDIR/deliver.log")" "4|$w|done|完成|$p"
}

@test "deliver-pane: 有旧通知时的活动写入也把来源 pane 作为第四参下传" {
  make_deliver_spy_cli
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  export DELIVER_LOG="$BATS_TEST_TMPDIR/deliver.log"

  "$SPY_CLI" "done" '旧通知' -t "$p"
  : > "$DELIVER_LOG"
  run "$SPY_CLI" running '继续干活' -t "$p"

  assert_eq "$status" 0
  assert_eq "$(cat "$DELIVER_LOG")" "4|$w|running|继续干活|$p"
}

@test "desktop-jump: 选择最近活动的 client，严格依次切换后才清通知" {
  make_desktop_tmux_stub
  wt set -g @whistle_spin off
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  "$CLI" running -t "$p"
  "$CLI" "done" '点击读我' -t "$p"
  FAKE_TMUX_CLIENTS=$'old|100\nnewest|300\nmiddle|200'

  run_desktop_jump "$p"

  assert_eq "$status" 0
  assert_eq "$(wt_tn_removed_groups)" "tmux-whistle:$WHISTLE_TMUX_SOCKET:$p"
  run awk '$0 == "ALL"' "$WHISTLE_TEST_TN_LOG"
  assert_eq "$output" ''
  local switches
  switches=$(grep -E '^(switch-client|select-window|select-pane)' "$DESKTOP_TMUX_LOG")
  assert_eq "$switches" "switch-client -c newest -t main
select-window -t $w
select-pane -t $p"
  assert_eq "$(optp @whistle_notice "$p")" ''
  # 已读只清通知通道，正在干活的活动态绝不能被顺带抹掉。
  assert_eq "$(optp @whistle "$p")" 'running'
}

@test "desktop-jump: 没有 attached client 时失败并保留通知" {
  make_desktop_tmux_stub
  local p
  p=$(pane_of)
  "$CLI" "done" '还不能读' -t "$p"
  FAKE_TMUX_CLIENTS=''

  run_desktop_jump "$p"

  assert_eq "$status" 1
  assert_contains "$output" '没有 attached client'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_contains "$(cat "$DESKTOP_TMUX_LOG")" 'list-clients'
}

@test "desktop-jump: 目标 pane 已死时失败且不清其它通知" {
  make_desktop_tmux_stub
  local p
  p=$(pane_of)
  "$CLI" "done" '不能误清' -t "$p"
  FAKE_TMUX_CLIENTS='client|100'

  run_desktop_jump '%999'

  assert_eq "$status" 1
  assert_contains "$output" '找不到目标 pane'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
}

@test "desktop-jump: switch-client 失败时保留通知且不继续切换" {
  make_desktop_tmux_stub
  local p
  p=$(pane_of)
  "$CLI" "done" '不能误清' -t "$p"
  FAKE_TMUX_CLIENTS='client|100'
  FAKE_TMUX_FAIL='switch-client'

  run_desktop_jump "$p"

  assert_eq "$status" 1
  assert_contains "$output" 'switch-client'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_not_contains "$(cat "$DESKTOP_TMUX_LOG")" 'select-window'
}

@test "desktop-jump: select-window 失败时保留通知且不选择 pane" {
  make_desktop_tmux_stub
  local p
  p=$(pane_of)
  "$CLI" "done" '不能误清' -t "$p"
  FAKE_TMUX_CLIENTS='client|100'
  FAKE_TMUX_FAIL='select-window'

  run_desktop_jump "$p"

  assert_eq "$status" 1
  assert_contains "$output" 'select-window'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_not_contains "$(cat "$DESKTOP_TMUX_LOG")" 'select-pane'
}

@test "desktop-jump: select-pane 失败时保留通知" {
  make_desktop_tmux_stub
  local p
  p=$(pane_of)
  "$CLI" "done" '不能误清' -t "$p"
  FAKE_TMUX_CLIENTS='client|100'
  FAKE_TMUX_FAIL='select-pane'

  run_desktop_jump "$p"

  assert_eq "$status" 1
  assert_contains "$output" 'select-pane'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
}

@test "state_clear: core 独立加载且没有 os_forget 时仍能清通知" {
  local p
  p=$(pane_of)
  "$CLI" running -t "$p"
  "$CLI" "done" '读我' -t "$p"
  unset -f whistle_os_forget 2> /dev/null || true

  run whistle_state_clear "$p"

  assert_eq "$status" 0
  assert_eq "$output" "$p"
  assert_eq "$(optp @whistle_notice "$p")" ''
  assert_eq "$(optp @whistle "$p")" 'running'
}

@test "state_clear: 有 os_forget 时按 pane 撤回，失败也不回滚已读" {
  local p
  p=$(pane_of)
  "$CLI" running -t "$p"
  "$CLI" "done" '读我' -t "$p"
  DESKTOP_FORGET_LOG="$BATS_TEST_TMPDIR/forget.log"
  whistle_os_forget() {
    printf '%s\n' "$1" >> "$DESKTOP_FORGET_LOG"
    return 1
  }

  run whistle_state_clear "$p"

  assert_eq "$status" 0
  assert_eq "$output" "$p"
  assert_eq "$(cat "$DESKTOP_FORGET_LOG")" "$p"
  assert_eq "$(optp @whistle_notice "$p")" ''
  assert_eq "$(optp @whistle "$p")" 'running'
}

# -- 列表 / 清除 / 开关 -----------------------------------------------------

@test "list: 无待处理时给出友好提示" {
  run "$CLI" list
  assert_eq "$status" 0
  assert_contains "$output" '没有待处理'
}

@test "list: 有项时输出表头与计数" {
  "$CLI" "done" '做完了'
  run "$CLI" list
  assert_contains "$output" 'SESSION'
  assert_contains "$output" '做完了'
  assert_contains "$output" '共 1 项'
}

@test "clear -a: 清空全局" {
  wt new-session -d -s other
  local pa pb
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other '#{pane_id}')
  "$CLI" "done" 'a' -t "$pa"
  "$CLI" "wait" 'b' -t "$pb"

  run "$CLI" clear -a
  assert_eq "$status" 0
  assert_eq "$(opt '@whistle_pending')" '0'
}

@test "公共撤回: window clear 在同窗口多 pane 上逐 group 撤回，off 仍生效且活动不变" {
  wt split-window -t w1
  wt set -g @whistle_os off
  local p1 p2 w expected
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  w=$(wt display -p -t w1 '#{window_id}')
  "$CLI" running -t "$p1"
  "$CLI" idle -t "$p2"
  "$CLI" "done" 'a' -t "$p1"
  "$CLI" wait 'b' -t "$p2"
  : > "$WHISTLE_TEST_TN_LOG"

  run "$CLI" clear -t "$w"

  assert_eq "$status" 0
  expected=$(printf 'tmux-whistle:%s:%s\ntmux-whistle:%s:%s\n' \
    "$WHISTLE_TMUX_SOCKET" "$p1" "$WHISTLE_TMUX_SOCKET" "$p2" | sort)
  assert_eq "$(wt_tn_removed_groups | sort)" "$expected"
  run awk '$0 == "ALL"' "$WHISTLE_TEST_TN_LOG"
  assert_eq "$output" ''
  assert_eq "$(optp @whistle "$p1")" 'running'
  assert_eq "$(optp @whistle "$p2")" 'idle'
  assert_eq "$(optp @whistle_notice "$p1")" ''
  assert_eq "$(optp @whistle_notice "$p2")" ''
}

@test "公共撤回: clear all 只撤回有通知的 pane，不误清活动通道" {
  wt new-session -d -s other -n w2
  local pa pb pc expected
  pa=$(wt display -p -t main:w1 '#{pane_id}')
  pb=$(wt display -p -t other:w2 '#{pane_id}')
  pc=$(wt split-window -d -t other:w2 -P -F '#{pane_id}')
  "$CLI" running -t "$pa"
  "$CLI" idle -t "$pc"
  "$CLI" "done" 'a' -t "$pa"
  "$CLI" wait 'b' -t "$pb"
  : > "$WHISTLE_TEST_TN_LOG"

  run "$CLI" clear -a

  assert_eq "$status" 0
  expected=$(printf 'tmux-whistle:%s:%s\ntmux-whistle:%s:%s\n' \
    "$WHISTLE_TMUX_SOCKET" "$pa" "$WHISTLE_TMUX_SOCKET" "$pb" | sort)
  assert_eq "$(wt_tn_removed_groups | sort)" "$expected"
  run awk '$0 == "ALL"' "$WHISTLE_TEST_TN_LOG"
  assert_eq "$output" ''
  assert_eq "$(optp @whistle "$pa")" 'running'
  assert_eq "$(optp @whistle "$pc")" 'idle'
  assert_eq "$(optp @whistle_notice "$pc")" ''
}

@test "开关: on 与 off 写全局标志" {
  run "$CLI" off
  assert_eq "$(opt '@whistle_enabled')" 'off'
  run "$CLI" on
  assert_eq "$(opt '@whistle_enabled')" 'on'
}

# -- 参数与用法 -------------------------------------------------------------

@test "未知子命令：打印用法并非零退出" {
  run "$CLI" frobnicate
  assert_eq "$status" 1
  assert_contains "$output" '用法'
}

@test "--help: 列出主要子命令" {
  run "$CLI" --help
  assert_eq "$status" 0
  for c in "done" "wait" "error" "running" clear list menu jump doctor; do
    assert_contains "$output" "$c"
  done
  # run 单独断言 —— 光靠 "run" 会被 "running" 满足，等于没断言
  assert_contains "$output" 'run [--'
}

@test "--help: 说明 terminal-notifier 要激活的应用 bundle ID 配置" {
  run "$CLI" --help
  assert_eq "$status" 0
  assert_contains "$output" '@whistle_os_app'
  assert_contains "$output" 'bundle ID'
}

@test "done 带 -t 指定目标 pane" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" '目标明确' -t "$p2"
  # done 走通知通道（@whistle_notice），活动通道不动
  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice)" 'done'
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" ''
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" ''
}

# -- 参数顺序（消息与选项谁在前都行）-----------------------------------------

@test "参数: -t 写在消息前面也能正确落到目标 pane" {
  # 回归：早先直接把 $2 当消息，于是 `done -t %3 "消息"` 会把 -t 吃进消息、
  # 目标退化成 $TMUX_PANE，最终写到**别的 pane**上去，且不报错。
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" -t "$p2" '目标明确'

  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice)" 'done'
  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice_msg)" '目标明确'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" ''
}

@test "参数: -t 与消息两种顺序结果一致" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p2 p3
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')

  "$CLI" "done" '同样的消息' -t "$p2"
  "$CLI" "done" -t "$p3" '同样的消息'

  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice_msg)" "$(wt show -pqv -t "$p3" @whistle_notice_msg)"
}

@test "参数: 无消息也能带 -t（running 最常用）" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  run "$CLI" "running" -t "$p2"
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'running'
  assert_eq "$(wt show -pqv -t "$p2" @whistle_msg)" ''
}

@test "参数: 不带引号的多词消息仍然拼成一句" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" 重构 完成 -t "$p2"
  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice_msg)" '重构 完成'
}

@test "参数: -- 之后的内容一律当消息，以 - 开头也不当选项" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" -t "$p2" -- '-开头也是消息'
  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice_msg)" '-开头也是消息'
}

@test "参数: 未知选项报错而不是被当成消息" {
  run "$CLI" "done" -x 'foo'
  assert_eq "$status" 1
  assert_contains "$output" '未知选项'
}

@test "参数: --dry-run 顺序无关，且报出解析后的目标与消息" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')

  run "$CLI" "done" --dry-run -t "$p2" '预览'
  assert_eq "$status" 0
  assert_contains "$output" '预览'
  assert_contains "$output" "$p2"
  # 只打印，不落盘
  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice)" ''
}

@test "--dry-run: 只打印不执行" {
  run "$CLI" "done" 'x' --dry-run
  assert_eq "$status" 0
  assert_contains "$output" '将置'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" ''
}

# -- 标题 / 正文分离 ---------------------------------------------------------

@test "--title 与 --body 分开存：标题进 msg，正文不被 80 字截断" {
  local p long
  p=$(pane_of)
  long=$(printf '正文%.0s' $(seq 1 200))     # 400 个字符
  "$CLI" "done" --title '重构完成' --body "$long"

  assert_eq "$(optp @whistle_notice_msg "$p")" '重构完成'
  assert_eq "$(optp @whistle_notice_body "$p")" "$long"
}

@test "只给 --body 时 msg 取正文前 80 字（与改动前逐字一致）" {
  local p long
  p=$(pane_of)
  long=$(printf '文%.0s' $(seq 1 200))
  "$CLI" "done" --body "$long"

  assert_eq "$(optp @whistle_notice_msg "$p")" "$(printf '%s' "$long" | cut -c 1-80)"
}

@test "两个都不给时行为与改动前完全一致" {
  local p
  p=$(pane_of)
  "$CLI" "done" '普通消息'

  assert_eq "$(optp @whistle_notice_msg "$p")" '普通消息'
  assert_eq "$(optp @whistle_notice_body "$p")" ''
}

@test "正文超过 400 字时按正文上限截断" {
  local p huge n
  p=$(pane_of)
  huge=$(printf '字%.0s' $(seq 1 600))
  "$CLI" "done" --body "$huge"

  n=$(printf '%s' "$(optp @whistle_notice_body "$p")" | wc -m | tr -d ' ')
  assert_eq "$n" 400
}

@test "正文里的 format 注入串被消毒" {
  local p
  p=$(pane_of)
  "$CLI" "done" --title '短' --body 'a#{b}c{d}e|f'

  assert_not_contains "$(optp @whistle_notice_body "$p")" '#'
  assert_not_contains "$(optp @whistle_notice_body "$p")" '{'
  assert_not_contains "$(optp @whistle_notice_body "$p")" '|'
}

@test "清除状态时正文一并清掉，不留残值" {
  local p
  p=$(pane_of)
  "$CLI" "done" --title '短' --body '很长的正文内容'
  "$CLI" clear -t "$p"

  assert_eq "$(optp @whistle_notice_body "$p")" ''
}

@test "--body 里的换行被折叠成空格（正文是单行存储的）" {
  local p
  p=$(pane_of)
  "$CLI" "done" --body $'第一行\n第二行'

  assert_contains "$(optp @whistle_notice_body "$p")" '第一行 第二行'
}

@test "menu-args: 菜单项把 pane 交给 clear 去做 select（不在命令链里裸 select-pane）" {
  wt split-window -t w1
  local p1 p2
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  p2=$(wt list-panes -t w1 -F '#{pane_id}' | tail -1)
  "$CLI" "done" '做完了' -t "$p2"

  run "$CLI" --menu-args
  assert_contains "$output" '--select'
  assert_contains "$output" "$p2"
  # 命令链里**不能**出现裸的 select-pane：pane 在菜单弹出后可能被关掉，
  # select-pane 报错会让 tmux 的 `;` 链遇错即停，后面的 clear 就不执行，
  # 状态永远清不掉。select 必须挪进异步的 clear 里，由它先判存活。
  assert_not_contains "$output" 'select-pane'
}

@test "clear --select: pane 已死时仍然清掉窗口（不中断在 select 上）" {
  local p w
  p=$(pane_of)
  w=$(wt display -p -t main:w1 '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  # %999 不存在 —— 模拟「菜单开着的时候那一格被关掉」
  run "$CLI" clear -t "$w" --select '%999'
  assert_eq "$status" 0
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "clear --select: pane 存活时它成为该窗口的活动 pane" {
  wt split-window -t w1
  local p1 w
  p1=$(wt list-panes -t w1 -F '#{pane_id}' | head -1)
  w=$(wt display -p -t main:w1 '#{window_id}')
  "$CLI" "done" '做完了' -t "$p1"

  run "$CLI" clear -t "$w" --select "$p1"
  assert_eq "$status" 0
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  # pane_active 是窗口级属性，无 attached client 也能读 —— 这是「确实选中了」
  # 唯一的可观测证据。
  assert_eq "$(wt display -p -t "$p1" '#{pane_active}')" '1'
}

# -- 内部：--clear-pane（SessionEnd 用） -------------------------------------

@test "--clear-pane: running 收成 gone，待处理状态原样保留" {
  # w2 跑一个与 w1 不同的前台进程：否则两格的 pane_current_command 相同，
  # w2（活动通道为空、只有通知）也会被「按进程发现空闲」算成 idle，
  # count_idle 就分不清到底是哪一格。
  wt new-window -d -n w2 'sleep 30'
  local p1 p2
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" running -t "$p1"
  "$CLI" "done" 'x' -t "$p2"

  # 清空的话，紧接着的重算会按「前台还跑着 agent」把它又认成空闲 ——
  # 那盏 ◉ 永远灭不掉。所以写成 gone：状态列非空，「发现」不会认它。
  # 这里把 pane 的前台进程写进清单，正是要验证 gone 挡住了重新发现。
  local cmd
  cmd=$(wt display -p -t w1 '#{pane_current_command}')
  wt set -g @whistle_agent_cmds "$cmd"

  run "$CLI" --clear-pane "$p1"
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p1" @whistle)" 'gone'
  assert_eq "$(opt '@whistle_count_idle')" '0'

  # done 是待处理通知：agent 退出不代表用户已经看过。
  # 活动通道照例收成 gone，通知通道原样留着。
  run "$CLI" --clear-pane "$p2"
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'gone'
  assert_eq "$(wt show -pqv -t "$p2" @whistle_notice)" 'done'
}

@test "--clear-pane: 清掉后窗口聚合与全局计数一起回落" {
  "$CLI" running
  assert_eq "$(opt '@whistle_pending')" '0'

  run "$CLI" --clear-pane "$(pane_of)"
  assert_eq "$status" 0
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

# -- 双通道分流 -------------------------------------------------------------
#
# 每个 pane 有两条正交通道：
#   活动通道 @whistle          running / idle / gone
#   通知通道 @whistle_notice   done / wait / error
# 用户语法按状态分流；两通道互不覆盖，@whistle_eff 取 rank 高者。

@test "done / wait / error 只写通知通道，活动通道原样保留" {
  local p
  p=$(pane_of)
  "$CLI" running -t "$p"

  "$CLI" "done" '做完了' -t "$p"
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_eq "$(optp @whistle_notice_msg "$p")" '做完了'
  # 有效态按 rank：done(3) > running(2)
  assert_eq "$(optp @whistle_eff "$p")" 'done'

  "$CLI" wait '等你授权' -t "$p"
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_notice "$p")" 'wait'

  "$CLI" error '炸了' -t "$p"
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_notice "$p")" 'error'
  # 活动消息没被通知消息顶掉
  assert_eq "$(optp @whistle_msg "$p")" ''
}

@test "running / idle 只写活动通道，通知通道原样保留" {
  local p
  p=$(pane_of)
  "$CLI" "done" '还没读' -t "$p"

  "$CLI" running '干活中' -t "$p"
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_msg "$p")" '干活中'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_eq "$(optp @whistle_notice_msg "$p")" '还没读'

  "$CLI" idle -t "$p"
  assert_eq "$(optp @whistle "$p")" 'idle'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
}

@test "run: 开始写活动 running，结束熄成 idle、通知通道落 done" {
  run "$CLI" run -- true
  assert_eq "$status" 0

  local p
  p=$(pane_of)
  # 命令跑完了，这个 pane 上没有东西在干活 —— 活动通道不能留在 running
  # （否则状态栏永久转 ▶），终态归通知通道。
  assert_eq "$(optp @whistle "$p")" 'idle'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_contains "$(optp @whistle_notice_msg "$p")" '完成'
  assert_eq "$(optp @whistle_eff "$p")" 'done'
}

@test "run: 命令失败时落 error 通知，活动通道同样熄成 idle" {
  run "$CLI" run -- false
  assert_eq "$status" 1

  local p
  p=$(pane_of)
  assert_eq "$(optp @whistle "$p")" 'idle'
  assert_eq "$(optp @whistle_notice "$p")" 'error'
  assert_contains "$(optp @whistle_notice_msg "$p")" '失败'
}

@test "clear: 只清通知通道，活动态保留" {
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  "$CLI" running -t "$p"
  "$CLI" "done" '读我' -t "$p"

  run "$CLI" clear -t "$p"
  assert_eq "$status" 0
  assert_eq "$(optp @whistle_notice "$p")" ''
  assert_eq "$(optp @whistle "$p")" 'running'
  # 窗口有效态回落到活动态，而不是空
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'running'
}

@test "clear -a: 只清通知通道，活动态保留" {
  local p
  p=$(pane_of)
  "$CLI" running -t "$p"
  "$CLI" "done" 'x' -t "$p"

  run "$CLI" clear -a
  assert_eq "$status" 0
  assert_eq "$(optp @whistle_notice "$p")" ''
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(opt @whistle_pending)" '0'
  assert_eq "$(opt @whistle_count_running)" '1'
}

@test "--read-pane: 活动 running + 通知 done 时只清通知" {
  # 这是本次要修的 bug 的第三个入口：守卫读的是 @whistle（活动态），
  # 永远判不成待处理 → 通知清不掉。
  local p w
  p=$(pane_of)
  w=$(wt display -p -t w1 '#{window_id}')
  "$CLI" running -t "$p"
  "$CLI" "done" 'x' -t "$p"

  run "$CLI" --read-pane "$p"
  assert_eq "$status" 0
  assert_eq "$(wt_tn_removed_groups)" "tmux-whistle:$WHISTLE_TMUX_SOCKET:$p"
  run awk '$0 == "ALL"' "$WHISTLE_TEST_TN_LOG"
  assert_eq "$output" ''
  assert_eq "$(optp @whistle_notice "$p")" ''
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_eff "$p")" 'running'
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" 'running'
  assert_eq "$(opt @whistle_pending)" '0'
  assert_eq "$(opt @whistle_count_running)" '1'
}

@test "menu-args: 消息为空时 9 列仍能正确分行" {
  local p
  p=$(pane_of)
  "$CLI" "done" -t "$p"

  run "$CLI" --menu-args
  assert_eq "$status" 0
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '3'
  assert_contains "$(printf '%s\n' "$output" | sed -n 1p)" '完成 [main]: w1'
  assert_contains "$(printf '%s\n' "$output" | sed -n 3p)" "$p"
}

@test "menu-args: 消息里带 | 时列不错位（仍跳到正确的 pane）" {
  # 消息列在**末位**，read 会把余下的（含分隔符）全塞给它 ——
  # 中间列数一旦算错，pane id 就会混进消息、命令跳到别的格子。
  local p
  p=$(pane_of)
  # 直接写 option：CLI 的 whistle_sanitize 会把 | 剔掉
  wt set -p -t "$p" @whistle_notice 'done'
  wt set -p -t "$p" @whistle_notice_msg 'a|b'

  run "$CLI" --menu-args
  assert_eq "$status" 0
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '3'

  local label cmd
  label=$(printf '%s\n' "$output" | sed -n 1p)
  cmd=$(printf '%s\n' "$output" | sed -n 3p)
  assert_contains "$label" '完成 [main]: w1'
  # pane id 不能泄漏进消息列
  assert_not_contains "$label" '%'
  assert_contains "$cmd" "select-window"
  assert_contains "$cmd" "$p"
}

# -- 内部子命令（hook 用，不进用户语法）--------------------------------------

@test "--activity: 写活动通道，最后一个位置参数是 pane" {
  local p
  p=$(pane_of)
  "$CLI" "done" '读我' -t "$p"

  run "$CLI" --activity running "$p"
  assert_eq "$status" 0
  assert_eq "$(optp @whistle "$p")" 'running'
  assert_eq "$(optp @whistle_notice "$p")" 'done'
}

@test "--activity gone: 只有 hook 能写，用户语法里到不了" {
  local p
  p=$(pane_of)
  run "$CLI" --activity gone "$p"
  assert_eq "$status" 0
  assert_eq "$(optp @whistle "$p")" 'gone'
  assert_eq "$(optp @whistle_eff "$p")" ''

  # 用户语法不认 gone
  run "$CLI" gone
  assert_eq "$status" 1
}

@test "--activity: 非法状态直接报错" {
  run "$CLI" --activity "done"
  assert_eq "$status" 1
  assert_contains "$output" '--activity'
}

@test "--notice: 写通知通道，消息与正文分开" {
  local p
  p=$(pane_of)
  "$CLI" running -t "$p"

  run "$CLI" --notice "done" '做完了' --body '完整正文' "$p"
  assert_eq "$status" 0
  assert_eq "$(optp @whistle_notice "$p")" 'done'
  assert_eq "$(optp @whistle_notice_msg "$p")" '做完了'
  assert_eq "$(optp @whistle_notice_body "$p")" '完整正文'
  # 活动通道不动
  assert_eq "$(optp @whistle "$p")" 'running'
}

@test "--notice: 非法通知态直接报错" {
  run "$CLI" --notice running
  assert_eq "$status" 1
  assert_contains "$output" '--notice'
}

@test "--sub-agent-start / --sub-agent-stop: 只写子 agent 标记，活动态由推导层合成" {
  local p
  p=$(pane_of)

  run "$CLI" --sub-agent-start "$p"
  assert_eq "$status" 0
  # 不写 @whistle —— 否则分不清「主回合在跑」和「只是子 agent 在跑」
  assert_eq "$(optp @whistle "$p")" ''
  # 存的是过期时间戳
  assert_eq "$(optp @whistle_sub "$p" | wc -c | tr -d ' ')" '11'
  # 推导层把它合成 running
  assert_eq "$(optp @whistle_eff "$p")" 'running'

  run "$CLI" --sub-agent-stop "$p"
  assert_eq "$status" 0
  assert_eq "$(optp @whistle_sub "$p")" ''
  assert_eq "$(optp @whistle_eff "$p")" ''
}

@test "内部子命令不出现在用户用法里" {
  run "$CLI" --help
  assert_eq "$status" 0
  assert_not_contains "$output" '--activity'
  assert_not_contains "$output" '--notice'
  assert_not_contains "$output" '--sub-agent'
}

# -- doctor ----------------------------------------------------------------

@test "doctor: 能跑完并报告 tmux 版本" {
  local expected_version
  expected_version=$("$CLI" --version)
  run "$CLI" doctor
  assert_contains "$output" "$expected_version doctor"
  assert_contains "$output" 'tmux'
  assert_contains "$output" '投递渠道'
  # 多 server 检查：段头必须出现。**不断言结论** —— 判据基于 `ps -u <uid>`，
  # 在开发机上会把用户真实跑着的 tmux 也算进去，结论随环境变化；这里只锁
  # 「这一项存在且被检查过」，否则哪天整段被删了没人发现（那是 TODO-20 的坑）。
  assert_contains "$output" '多个 tmux server'
  # 未安装状态下的"未注入"只是提醒，不该让 doctor 整体失败
  [[ "$output" == *'未注入'* ]] || [[ "$output" == *'已注入'* ]]
}
@test "menu-args: 生成的命令是合法的 tmux 命令（不会 Unknown command）" {
  "$CLI" "done" '做完了'
  run "$CLI" --menu-args
  local cmd
  cmd=$(printf '%s\n' "$output" | sed -n 3p)

  # 用 source-file 让 tmux 用**它自己的命令解析器**吃这条命令 ——
  # display-menu 的第三参就是这样被解析的。之前这里把 CLI 路径裸放在
  # 命令位置，tmux 会报 "Unknown command: .../tmux-whistle"。
  printf '%s\n' "$cmd" > "$BATS_TEST_TMPDIR/cmd.tmux"
  run wt source-file "$BATS_TEST_TMPDIR/cmd.tmux"

  assert_not_contains "$output" 'Unknown command'
  assert_not_contains "$output" 'unknown command'
  assert_not_contains "$output" 'parse error'
}

@test "menu-args: CLI 调用被包在 run-shell 里" {
  "$CLI" "done" 'x'
  run "$CLI" --menu-args
  local cmd
  cmd=$(printf '%s\n' "$output" | sed -n 3p)
  assert_contains "$cmd" "run-shell"
  assert_contains "$cmd" "$CLI"
}
