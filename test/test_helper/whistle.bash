#!/usr/bin/env bash
# shellcheck shell=bash
#
# tmux-whistle Bats 公共 helper。
#
# 隔离约定：
#   - 每个测试文件一个独立 socket（$$ = 进程号），并行跑不打架
#   - 用 `-f /dev/null` 起 server，绝不读用户真实的 tmux.conf
#     （那份会 source 插件、装 oh-my-tmux 主题，拖慢每个测试）
#   - teardown 必须 kill-server 并删 socket 文件，否则会泄漏（bats 失败时也会调 teardown）

setup_file() {
  # 用 helper 自身位置推仓库根，而不是 BATS_TEST_DIRNAME ——
  # 后者指向测试文件目录（test/unit/...），会多退一级。
  WHISTLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  WHISTLE_TEST_SOCK="whistle-test-$$"
  export WHISTLE_ROOT WHISTLE_TEST_SOCK
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"
}

wt() {
  tmux -L "$WHISTLE_TEST_SOCK" "$@"
}

# 起一个独立 server，并用 -f /dev/null 阻断用户真实配置的加载。
# 同时把 socket 路径导出，供被测 CLI 通过 WHISTLE_TMUX_SOCKET 定位。
wt_start() {
  tmux -L "$WHISTLE_TEST_SOCK" -f /dev/null new-session -d -s main -n w1
  WHISTLE_TMUX_SOCKET="$(wt display -p '#{socket_path}')"
  export WHISTLE_TMUX_SOCKET
}

wt_stop() {
  local sock="${WHISTLE_TMUX_SOCKET:-}"
  tmux -L "$WHISTLE_TEST_SOCK" kill-server 2> /dev/null || true
  # kill-server 不总会 unlink socket 文件；反复跑测试会攒出几百个残留。
  [ -n "$sock" ] && [ -S "$sock" ] && command rm -f "$sock" 2> /dev/null || true
  WHISTLE_TMUX_SOCKET=''
  export WHISTLE_TMUX_SOCKET
}

# 注意：不要在这里装 trap '...' EXIT。
# bats 靠自己的 EXIT trap 汇报测试结果；覆盖它会静默吞掉失败 ——
# 表现是 "Executed 0 instead of expected N tests"，而不是 not ok。
# 清理交给 teardown()（bats 在失败与中断时都会调用）。

wt_fake_omt_format() {
  # 模拟 oh-my-tmux 的 window-status-format：
  #   <左分隔符><颜色><属性><内容>#[none]<spacer><颜色>#[<右分隔符>]
  # 末位字符是右分隔符 —— format_patch 必须把徽章插在它之前（KP-5）。
  #
  # 内容里带 #{window_name}，这样 W: 循环的输出能分辨哪个窗口是哪段；
  # 但不要在窗口名两侧加装饰字符，否则会隔断 "w1✓" 这类连续子串。
  wt set -g window-status-format \
    '#{window_name}#[none]#[none]▌'
  wt set -g window-status-current-format \
    '#{window_name}#[none]#[none]▌'
}

wt_load() {
  # shellcheck disable=SC1090  # 动态路径
  source "$WHISTLE_ROOT/lib/$1.sh"
}

wt_publish_and_patch() {
  wt_load core
  wt_load status-line
  whistle_mark_publish
  whistle_format_patch window-status-format
  whistle_format_patch window-status-current-format
}

# 渲染整个 session 的窗口列表，每个窗口一段
#
# display -pF 不会解析 #[...] 样式指令（只有真状态栏渲染器才处理），
# 所以样式会以字面文本形式混在输出里，"w1" 和 "✓" 之间夹着 #[fg=...]，
# 无法直接做子串匹配。这里把 #[...] 和 SGR 序列都剥掉再交给断言。
wt_render_windows() {
  local esc
  esc=$(printf '\033')
  wt display -pF '#{W:#{E:window-status-format}}' \
    | sed -e "s/${esc}\\[[0-9;]*m//g" -e 's/#\[[^]]*\]//g'
}

# -- 断言 ------------------------------------------------------------------

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf '期望: [%s]\n实际: [%s]\n' "$2" "$1" >&2
    return 1
  fi
}

assert_contains() {
  case "$1" in
  *"$2"*) ;;
  *)
    printf '期望包含: [%s]\n实际:     [%s]\n' "$2" "$1" >&2
    return 1
    ;;
  esac
}

assert_not_contains() {
  case "$1" in
  *"$2"*)
    printf '期望不包含: [%s]\n实际:       [%s]\n' "$2" "$1" >&2
    return 1
    ;;
  *) ;;
  esac
}

# 轮询等待条件成立。hook 走的是 run-shell -b（异步），
# 触发后必须等它跑完才能断言，不能 sleep 一下就假定好了。
wt_wait_until() {
  local timeout_ms="${1:-3000}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_ms" ]; do
    if eval "$2" > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
    elapsed=$((elapsed + 50))
  done
  printf '等待超时 (%sms): %s\n' "$timeout_ms" "$2" >&2
  return 1
}

# 统计子串出现次数
count_occurrences() {
  printf '%s' "$1" | grep -o -- "$2" 2> /dev/null | wc -l | tr -d ' '
}

# 取 tmux option 值（安静模式，未设置返回空）
# window-status-format 是 global option（set -g 设的），必须用 -g 查；
# -w 需要一个 target window，在无 client 的测试 server 上会失败。
opt() {
  wt show -gqv "$1" 2> /dev/null || printf ''
}
optw() {
  wt show -gwv "$1" 2> /dev/null || printf ''
}
optp() {
  wt show -pqv -t "$2" "$1" 2> /dev/null || printf ''
}
