#!/usr/bin/env bats
# shellcheck shell=bash
#
# L1 纯函数：读屏分类器的区域切分与规则。
#
# 设计要点：屏幕分类器是「屏幕永远只是补充」那一层的全部实现 ——
# 它读的是 tmux capture-pane 的整屏文本，输出一个状态词，**不碰任何 tmux 状态**。
# 真源仍然是 hook 上报的值（见 lib/core.sh 推导层的 D1/D2）。
#
# 区域切分先做，规则再基于区域判断：`tail(n)` 看底部动态行，`after_rule` 看
# 最后一条分隔线之后，`prompt_box` 看最后那个输入框。真实 Codex 0.171.0
# **没有** `─{3,}` 分隔线，所以区域缺失时规则必须能从底部继续判断。

load '../test_helper/whistle'

setup() {
  : "${WHISTLE_ROOT:?helper 未加载}"
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"
  # shellcheck source=/dev/null
  source "$WHISTLE_ROOT/lib/detect-rules.sh"
}

@test "screen_tail: 只取最后 n 行非空" {
  run whistle_screen_tail 2 <<'EOF'
a

b
c
EOF
  assert_eq "$output" 'b
c'
}

@test "screen_after_rule: 取最后分隔线之后" {
  run whistle_screen_after_rule <<'EOF'
old
──────
new1
new2
EOF
  assert_eq "$output" 'new1
new2'
}

@test "screen_prompt_box: 取最后提示行" {
  run whistle_screen_prompt_box <<'EOF'
x
❯ hello
────────
status
EOF
  assert_eq "$output" '❯ hello'
}

@test "codex: 权限表单判 wait" {
  run whistle_classify_codex <<'EOF'
──────
Allow command?
❯ 1. Yes
  2. No
enter to confirm · esc to cancel
EOF
  assert_eq "$output" 'wait'
}

@test "codex: 计时器判 running" {
  run whistle_classify_codex <<'EOF'
• Working (12s • esc to interrupt)
› 
EOF
  assert_eq "$output" 'running'
}

@test "codex: 空提示符判 idle" {
  run whistle_classify_codex <<'EOF'
done
› 
EOF
  assert_eq "$output" 'idle'
}

@test "codex: 对话框滚出可视区不判 idle" {
  run whistle_classify_codex <<'EOF'
esc to cancel
enter to confirm
...
› still waiting
EOF
  [ "$output" != "idle" ]
}

@test "codex: 0.171.0 真机 fixtures" {
  for fixture in \
    codex-0.171.0-idle-120x40 \
    codex-0.171.0-idle-80x24 \
    codex-0.171.0-idle-after-turn-120x40 \
    codex-0.171.0-running-120x40 \
    codex-0.171.0-permission-wait-120x40 \
    codex-0.171.0-trust-wait-120x40 \
    codex-0.171.0-scroll-freeze-80x24 \
    codex-0.171.0-transcript-scroll-freeze-120x40; do
    expected=$(awk -F '\t' -v f="$fixture.txt" '$1 == f { print $2 }' \
      "$WHISTLE_ROOT/test/fixtures/codex-screen/manifest.tsv")
    run whistle_classify_codex < "$WHISTLE_ROOT/test/fixtures/codex-screen/$fixture.txt"
    assert_eq "$output" "$expected"
  done
}

@test "claude: 空提示框判 idle（下方还有状态行）" {
  run whistle_classify_claude <<'EOF'
✻ Worked for 16s
────────
❯ 
────────
  ⏵⏵ bypass permissions on
EOF
  assert_eq "$output" 'idle'
}

@test "claude: 提示框内转圈判 running" {
  run whistle_classify_claude <<'EOF'
❯ ✻ 思考中
EOF
  assert_eq "$output" 'running'
}

@test "claude: 权限对话框判 wait" {
  run whistle_classify_claude <<'EOF'
Do you want to proceed?
❯ 1. Yes
  2. No
esc to cancel
EOF
  assert_eq "$output" 'wait'
}

@test "classify_screen: 按 agent 分派" {
  run whistle_classify_screen codex <<'EOF'
› 
EOF
  assert_eq "$output" 'idle'
}

@test "classify_screen: 未知 agent 返回空" {
  run whistle_classify_screen vim <<'EOF'
› 
EOF
  assert_eq "$output" ''
}

@test "agent_kind: 去 .exe 后按前缀归一化" {
  assert_eq "$(whistle_agent_kind 'claude.exe')" 'claude'
  assert_eq "$(whistle_agent_kind 'codex')" 'codex'
  assert_eq "$(whistle_agent_kind 'zsh')" ''
}

@test "eligible: codex exec 非交互被排除" {
  run whistle_detect_eligible codex 'codex exec --json' 'codex claude'
  assert_eq "$status" 1
}

@test "eligible: 交互 TUI 被接受" {
  run whistle_detect_eligible codex 'codex --no-daemon' 'codex claude'
  assert_eq "$status" 0
}
