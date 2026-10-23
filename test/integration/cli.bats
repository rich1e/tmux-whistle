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

# -- 菜单 ------------------------------------------------------------------

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
  assert_contains "$label" 'main:w1'
  assert_contains "$label" '做完了'
  assert_eq "$key" '1'
  assert_contains "$cmd" 'switch-client -t main'
  assert_contains "$cmd" 'select-window -t @'
  assert_contains "$cmd" 'clear -t @'
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

@test "menu-args: running 项也列出，以 - 开头灰显且没有快捷键" {
  # display-menu 里名称以 '-' 开头 = disabled：tmux 绘制时会剥掉这个 '-' 并置暗
  # （screen-write.c 的 screen_write_menu），选中路径与鼠标路径都跳过它。
  wt new-window -d -n w2
  local p1 p2
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" '做完了' -t "$p1"
  "$CLI" running -t "$p2"

  run "$CLI" --menu-args
  assert_eq "$status" 0
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '6'

  assert_contains "$(printf '%s\n' "$output" | sed -n 1p)" '完成'
  assert_eq "$(printf '%s\n' "$output" | sed -n 2p)" '1'

  local label key cmd
  label=$(printf '%s\n' "$output" | sed -n 4p)
  key=$(printf '%s\n' "$output" | sed -n 5p)
  cmd=$(printf '%s\n' "$output" | sed -n 6p)

  case "$label" in
  '- 运行中'*) ;;
  *)
    printf '期望以 "- 运行中" 开头，实际: [%s]\n' "$label" >&2
    return 1
    ;;
  esac
  assert_eq "$key" ''
  assert_contains "$cmd" 'display-message'
}

@test "menu-args: 待处理项的编号不因 running 项而错位" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p1 p2 p3
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')
  "$CLI" running -t "$p1"
  "$CLI" "done" 'a' -t "$p2"
  "$CLI" "wait" 'b' -t "$p3"

  run "$CLI" --menu-args
  # 顺序：先两个待处理（key 1、2），再 running（空 key）—— 共三组九行
  assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" '9'
  assert_eq "$(printf '%s\n' "$output" | sed -n '2p;5p')" "1
2"
  assert_eq "$(printf '%s\n' "$output" | sed -n 8p)" ''
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

@test "menu-args: running 那段超过 10 项时同样出提示，不静默截断" {
  seed_running_windows 13

  run "$CLI" --menu-args
  # 10 个 running 项 + 1 条提示
  assert_eq "$(menu_keys "$output" | wc -l | tr -d ' ')" 11
  assert_contains "$output" '- 还有 3 项未显示'
}

@test "menu-args: 待处理与 running 各自的提示分开计数" {
  seed_pending_windows 28
  seed_running_windows 13

  run "$CLI" --menu-args
  # 26 + 1（待处理提示）+ 10 + 1（running 提示）
  assert_eq "$(menu_keys "$output" | wc -l | tr -d ' ')" 38
  assert_eq "$(printf '%s\n' "$output" | grep -c '^- 还有 2 项未显示')" 1
  assert_eq "$(printf '%s\n' "$output" | grep -c '^- 还有 3 项未显示')" 1
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
  assert_eq "$(wt show -pqv -t "$p" @whistle)" ''
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
  assert_eq "$(wt show -pqv -t "$p" @whistle)" ''
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
  assert_contains "$(wt show -pqv -t "$p1" @whistle)" 'done'
  assert_contains "$(wt show -pqv -t "$p3" @whistle)" 'done'
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
  assert_contains "$(wt show -pqv -t "$p3" @whistle)" 'done'
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
}

@test "done 带 -t 指定目标 pane" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" '目标明确' -t "$p2"
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'done'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" ''
}

# -- 参数顺序（消息与选项谁在前都行）-----------------------------------------

@test "参数: -t 写在消息前面也能正确落到目标 pane" {
  # 回归：早先直接把 $2 当消息，于是 `done -t %3 "消息"` 会把 -t 吃进消息、
  # 目标退化成 $TMUX_PANE，最终写到**别的 pane**上去，且不报错。
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" -t "$p2" '目标明确'

  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'done'
  assert_eq "$(wt show -pqv -t "$p2" @whistle_msg)" '目标明确'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" ''
}

@test "参数: -t 与消息两种顺序结果一致" {
  wt new-window -d -n w2
  wt new-window -d -n w3
  local p2 p3
  p2=$(wt display -p -t w2 '#{pane_id}')
  p3=$(wt display -p -t w3 '#{pane_id}')

  "$CLI" "done" '同样的消息' -t "$p2"
  "$CLI" "done" -t "$p3" '同样的消息'

  assert_eq "$(wt show -pqv -t "$p2" @whistle_msg)" "$(wt show -pqv -t "$p3" @whistle_msg)"
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
  assert_eq "$(wt show -pqv -t "$p2" @whistle_msg)" '重构 完成'
}

@test "参数: -- 之后的内容一律当消息，以 - 开头也不当选项" {
  wt new-window -d -n w2
  local p2
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" "done" -t "$p2" -- '-开头也是消息'
  assert_eq "$(wt show -pqv -t "$p2" @whistle_msg)" '-开头也是消息'
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
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" ''
}

@test "--dry-run: 只打印不执行" {
  run "$CLI" "done" 'x' --dry-run
  assert_eq "$status" 0
  assert_contains "$output" '将置'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" ''
}

# -- 标题 / 正文分离 ---------------------------------------------------------

@test "--title 与 --body 分开存：标题进 msg，正文不被 80 字截断" {
  local p long
  p=$(pane_of)
  long=$(printf '正文%.0s' $(seq 1 200))     # 400 个字符
  "$CLI" "done" --title '重构完成' --body "$long"

  assert_eq "$(optp @whistle_msg "$p")" '重构完成'
  assert_eq "$(optp @whistle_body "$p")" "$long"
}

@test "只给 --body 时 msg 取正文前 80 字（与改动前逐字一致）" {
  local p long
  p=$(pane_of)
  long=$(printf '文%.0s' $(seq 1 200))
  "$CLI" "done" --body "$long"

  assert_eq "$(optp @whistle_msg "$p")" "$(printf '%s' "$long" | cut -c 1-80)"
}

@test "两个都不给时行为与改动前完全一致" {
  local p
  p=$(pane_of)
  "$CLI" "done" '普通消息'

  assert_eq "$(optp @whistle_msg "$p")" '普通消息'
  assert_eq "$(optp @whistle_body "$p")" ''
}

@test "正文超过 400 字时按正文上限截断" {
  local p huge n
  p=$(pane_of)
  huge=$(printf '字%.0s' $(seq 1 600))
  "$CLI" "done" --body "$huge"

  n=$(printf '%s' "$(optp @whistle_body "$p")" | wc -m | tr -d ' ')
  assert_eq "$n" 400
}

@test "正文里的 format 注入串被消毒" {
  local p
  p=$(pane_of)
  "$CLI" "done" --title '短' --body 'a#{b}c{d}e|f'

  assert_not_contains "$(optp @whistle_body "$p")" '#'
  assert_not_contains "$(optp @whistle_body "$p")" '{'
  assert_not_contains "$(optp @whistle_body "$p")" '|'
}

@test "清除状态时正文一并清掉，不留残值" {
  local p
  p=$(pane_of)
  "$CLI" "done" --title '短' --body '很长的正文内容'
  "$CLI" clear -t "$p"

  assert_eq "$(optp @whistle_body "$p")" ''
}

@test "--body 里的换行被折叠成空格（正文是单行存储的）" {
  local p
  p=$(pane_of)
  "$CLI" "done" --body $'第一行\n第二行'

  assert_contains "$(optp @whistle_body "$p")" '第一行 第二行'
}

# -- 内部：--clear-pane（SessionEnd 用） -------------------------------------

@test "--clear-pane: 只清 running，待处理状态原样保留" {
  wt new-window -d -n w2
  local p1 p2
  p1=$(wt display -p -t w1 '#{pane_id}')
  p2=$(wt display -p -t w2 '#{pane_id}')
  "$CLI" running -t "$p1"
  "$CLI" "done" 'x' -t "$p2"

  run "$CLI" --clear-pane "$p1"
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p1" @whistle)" ''

  # done 是待处理通知：agent 退出不代表用户已经看过
  run "$CLI" --clear-pane "$p2"
  assert_eq "$status" 0
  assert_eq "$(wt show -pqv -t "$p2" @whistle)" 'done'
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

# -- doctor ----------------------------------------------------------------

@test "doctor: 能跑完并报告 tmux 版本" {
  run "$CLI" doctor
  assert_contains "$output" 'tmux'
  assert_contains "$output" '投递渠道'
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
