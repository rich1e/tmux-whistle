# Codex 读屏降级通道 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户直接跑 `codex`（不经 `tmux-whistle-codex`）时，状态栏也能准确显示 running / idle / wait。

**Architecture:** 复用 `lib/detect.sh` 的轮询骨架，把「Claude 关键词匹配」升级为按 agent 分派的区域化规则分类器（`lib/detect-rules.sh`）。屏幕只写新槽位 `@whistle_live`，推导层按 `@whistle > @whistle_live > 进程名` 合成——屏幕永远是补充，不是真源。

**Tech Stack:** POSIX sh（macOS `/bin/sh`）、tmux user option、bats（L1 纯函数 / L2 隔离 server / L3 e2e）、shellcheck + shfmt。

**Spec:** 本文件「Design Decisions」；背景见 `docs/codex-pane-attribution-design.md`、`docs/codex-launcher-rationale.md`。外部参考：herdr `src/detect/manifests/{codex,claude}.toml` 的区域化规则设计；clawd-on-desk「集成给身份、屏幕给状态」的仲裁模型。

## Global Constraints

- 全部代码是 POSIX sh，目标 `/bin/sh`；**没有 `local`**，函数内临时变量必须带命名空间前缀（`_dr_` / `_dv_` / `_lv_`）。
- 禁用 `[[ ]]`、数组、`$'...'`；`$var` 后紧跟中文必须写 `${var}`。
- `lib/core.sh` 的纯函数（`whistle_sanitize` / `whistle_rank` / `whistle_aggregate` / `whistle_count_states` / `whistle_resolve_idle_panes`）**不得调用 tmux**。
- `lib/detect-rules.sh` 同样不得调用 tmux；输入走 stdin/参数，输出走 stdout。
- tmux 取值一律 `show -pqv` / `show -gqv`。
- 用户可配开关与插件自写状态必须不同名；插件状态**不进** `WHISTLE_DEFAULTS`。
- `shfmt -ln=posix` 覆盖 `bin/ lib/ hooks/`；`.bats` 不格式化。
- 提交前 `make check` 全绿，且不留 `whistle-test-*` 残留 server。
- 屏幕检测结果**绝不能写进 `@whistle`**（真源只放 agent 上报值）。

## Review Focus

五类最容易被读屏坑到的输入，每条在归属任务里有测试：

1. **权限对话框滚出可视区** —— 不能因此判 idle（Task 2 反例）。
2. **普通 shell 输出含 `esc to cancel`** —— 不能触发分类（Task 6）。
3. **`codex exec` 非交互 pane** —— 不能产生幽灵 running（Task 3 的 `eligible` 单测 + Task 6 的过滤）。
4. **旧格式 6 列输入** —— 新增 live 列后既有推导层用例必须仍通过（Task 5）。
5. **agent 中途退出** —— `@whistle_live` 必须清掉，不能永久 `▶`（Task 6 + Task 10）。
6. **TUI 重绘造成的瞬时 running→idle** —— 不能补出假 `done` 通知（Task 8 的时长闸与未读闸）。

## Design Decisions

- **D1 双槽位**：屏幕写 `@whistle_live`（`running` / `idle` / 空），hook 继续写 `@whistle`，两者永不互相覆盖。
- **D2 推导优先级**：`@whistle` 有值 → 用它；否则 `@whistle_live` 有值 → 用它；否则前台是 agent → `idle`；否则空。
- **D3 仲裁**：`lib/detect.sh` 只跳过 `@whistle_src` 为 `hook` / `migration` 的 pane。
- **D4 规则由真机 fixtures 驱动**：每个 agent 一个纯函数，按
  `freeze → wait → running → idle` 首次命中即返回；规则必须通过
  `test/fixtures/codex-screen/manifest.tsv`，不能只通过手写屏幕样例。
- **D5 区域是有条件补充，不是硬依赖**：保留 `tail(n)` / `after_rule` /
  `prompt_box`，但真实 Codex 0.171.0 没有 `─{3,}` 分隔线，`after_rule`
  为空时必须从底部对话框/状态栏继续判断。当前真实 idle 提示为
  `› Ask Codex to do anything`，不是空 `›`。
- **D6 防抖**：`→ running` 立即生效；其余切换需连续 2 次相同分类。
- **D7 节奏**：存在 agent pane 时每 1 秒扫一次，否则回落到 `@whistle_detect_interval`（默认 15）。
- **D8 只扫 agent pane**：`pane_current_command` 去掉 `.exe` 后前缀匹配 `@whistle_agent_cmds`，且 argv 不含 `exec`。
- **D9 补 done 的三道闸**：`running → idle` 转变被防抖确认后，还需 ①`@whistle_detect_done=on` ②running 持续 ≥ `@whistle_detect_done_min` ③`@whistle_notice` 为空 —— 三条全过才写 `done`，且只写通知通道。

---

## Phase 0 · 真实屏幕基线（已完成）

### Task 0: 采集 Codex 屏幕 fixtures 并验证原规则

**Files:**
- Create: `test/fixtures/codex-screen/*.txt`
- Create: `test/fixtures/codex-screen/manifest.tsv`
- Create: `test/fixtures/codex-screen/README.md`

**已完成：**

- [x] 用临时 `CODEX_HOME`、临时工作目录和隔离 tmux server 采集 Codex CLI
  `0.171.0` 的 idle / running / idle-after-turn / permission-wait /
  trust-wait / scroll-freeze。
- [x] 同时保留 `120x40` 与 `80x24` 两个宽度样本。
- [x] 使用 `capture-pane -p -J` 保留折行；临时路径已归一化，快照不含 token。
- [x] 用计划中的原规则跑 8 个 fixture：只有 running 匹配，其余 7 个都不匹配。

**基线结论：**

- 当前 Codex TUI 没有 `─{3,}` 分隔线，不能把 `after_rule` 作为 wait 的必经区域。
- idle 必须识别 `› Ask Codex to do anything` 及后续版本可能使用的占位文案。
- permission wait 的稳定信号是底部
  `Press enter to confirm or esc to cancel` / `Would you like to run the following command?`。
- directory trust wait 的稳定信号是 `Trust this folder?` +
  `enter continue · esc back`。
- scroll freeze 的稳定信号是 `↓ Back to bottom · esc` /
  `enter/esc latest`，不是原计划的 `↑/↓ to scroll`。
- running 的 `• Working (... esc to interrupt)` 规则仍有效，但权限等待页面还可能显示
  `• Running <command>`，wait 必须保持高于 running。

**Gate：** Task 2 的规则表和测试必须先改为消费这些 fixtures；在 fixture 全绿前，
不得继续实现 Task 5 以后的状态槽位。

---

## Phase 1 · 纯函数分类器

### Task 1: 区域切分

**Files:**
- Create: `lib/detect-rules.sh`
- Create: `test/unit/detect.bats`

**Interfaces:**
- Consumes: 无
- Produces:
  - `whistle_screen_tail <n>` — stdin=整屏，stdout=最后 n 行**非空**行
  - `whistle_screen_after_rule` — stdin=整屏，stdout=最后一条 `^[-─]{3,}$` 之后的内容；无分隔线时空
  - `whistle_screen_prompt_box` — stdin=整屏，stdout=最后一条
    `^[[:space:]]*[❯›]` 起，到下一条分隔线或 EOF；无分隔线时包含底部状态栏

- [ ] **Step 1: 写失败测试**

`test/unit/detect.bats`，沿用仓库风格：

```bash
#!/usr/bin/env bats
# shellcheck shell=bash
load '../test_helper/whistle'

setup() {
  : "${WHISTLE_ROOT:?helper 未加载}"
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"
  # shellcheck source=lib/detect-rules.sh
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats test/unit/detect.bats`
Expected: 3 failed（`lib/detect-rules.sh` 不存在）。

- [ ] **Step 3: 实现三个区域函数**

文件头注明「纯函数、不得调用 tmux」。用 `awk` 单次遍历；变量前缀 `_dr_`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bats test/unit/detect.bats`
Expected: 3 passed。

- [ ] **Step 5: 提交**

```bash
git add lib/detect-rules.sh test/unit/detect.bats
git commit -m "feat(detect): 屏幕区域切分纯函数"
```

---

### Task 2: Codex 分类规则

**Files:**
- Modify: `lib/detect-rules.sh`
- Modify: `test/unit/detect.bats`

**Interfaces:**
- Consumes: Task 1 的区域函数
- Produces: `whistle_classify_codex` — stdin=整屏，stdout ∈ `running` / `wait` / `idle` / `freeze` / 空

规则（首次命中即返回）：

| 顺序 | 状态 | 判据 |
|---|---|---|
| 1 | `freeze` | 底部含 `↓ Back to bottom · esc` 或 `enter/esc latest`；兼容旧版 `↑/↓ to scroll` / `pgup/pgdn to` |
| 2 | `wait` | `tail 20` 含 `Press enter to confirm or esc to cancel` 或 `Would you like to run the following command?`；trust 页含 `Trust this folder?` + `enter continue · esc back`；兼容旧版 confirm/select 文案 |
| 3 | `running` | `tail 12` 匹配计时器或含 `esc to interrupt`，或底部状态为 `• Running <command>`；**且**不含 `Reconnect failed` |
| 4 | `idle` | `prompt_box` 中存在 `› Ask Codex to do anything` / `› Ask a follow-up question` / 空 `›`；兼容旧版空提示框 |

- [ ] **Step 1: 写失败测试**

```bash
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats -f 'codex:' test/unit/detect.bats`
Expected: 5 failed。

- [ ] **Step 3: 实现 `whistle_classify_codex`**

每个区域只算一次存进 `_dr_*` 变量；优先用一次 awk 完成分类，避免每秒每个
pane 多次 fork。规则必须同时通过 fixture 和手写的反例。

- [ ] **Step 4: 跑测试确认通过**

Run: `bats -f 'codex:' test/unit/detect.bats`
Expected: 5 passed。

- [ ] **Step 5: 提交**

```bash
git add lib/detect-rules.sh test/unit/detect.bats
git commit -m "feat(detect): Codex 屏幕分类规则"
```

---

### Task 3: Claude 规则 + 统一入口

**Files:**
- Modify: `lib/detect-rules.sh`
- Modify: `test/unit/detect.bats`

**Interfaces:**
- Consumes: Task 1 的区域函数、Task 2 的 codex 分类器
- Produces:
  - `whistle_classify_claude` — stdin=整屏，stdout 同 Task 2
  - `whistle_classify_screen <agent>` — stdin=整屏；`agent` ∈ `codex`/`claude`；未知 agent 输出空
  - `whistle_agent_kind <cmd>` — stdout ∈ `claude`/`codex`/`opencode`/空；去 `.exe` 后按前缀匹配，**归一化规则必须与 `whistle_agent_windows` 的 awk 一致**
  - `whistle_detect_eligible <cmd> <argv> <agent_cmds>` — exit 0 表示该 pane 可被读屏接管

Claude 规则：

| 顺序 | 状态 | 判据 |
|---|---|---|
| 1 | `freeze` | 整屏含 `showing detailed transcript` |
| 2 | `wait` | 含 `do you want to proceed?` 且有 `esc to cancel`；或 `esc to cancel` + `enter to confirm` |
| 3 | `running` | `tail 12` 含 `esc to interrupt`；或 `prompt_box` 匹配 `^[[:space:]]*❯[[:space:]]*[⠁⠂⠄⠈⠐⠠⡀⢀✢✳✷✸✻✽]` |
| 4 | `idle` | `prompt_box` 匹配 `^[[:space:]]*❯[[:space:]]*$` |

- [ ] **Step 1: 写失败测试**

```bash
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats -f 'claude:' test/unit/detect.bats; bats -f 'classify_screen' test/unit/detect.bats; bats -f 'agent_kind' test/unit/detect.bats; bats -f 'eligible' test/unit/detect.bats`
Expected: 8 failed。

- [ ] **Step 3: 实现**

`whistle_classify_screen` 用 `case` 分派；未知 agent 直接 `return 0` 且不输出。

- [ ] **Step 4: 跑测试确认通过**

Run: `bats test/unit/detect.bats`
Expected: 全部 passed。

- [ ] **Step 5: 提交**

```bash
git add lib/detect-rules.sh test/unit/detect.bats
git commit -m "feat(detect): Claude 分类规则与统一入口"
```

---

### Task 4: 真机探针脚本

**Files:**
- Create: `scripts/detect-probe.sh`

**Interfaces:**
- Consumes: `whistle_classify_screen`（Task 3）
- Produces: 手工诊断脚本，**只读，不写任何 tmux 状态**

输出格式，每个 agent pane 一行：

```
%11  claude  hook   → idle      (rows=8)
```

- [ ] **Step 1: 写脚本**

`list-panes -a -F '#{pane_id}|#{pane_current_command}|#{@whistle}|#{@whistle_src}'` → 对 agent pane 执行 `capture-pane -p -J` → `whistle_classify_screen`。不写状态。

- [ ] **Step 2: 真机运行**

Run: `sh scripts/detect-probe.sh`
Expected: 直接启动的 Codex pane 在 idle / running / permission-wait / scroll-freeze
四态分别与 `test/fixtures/codex-screen/` 的分类一致。若与状态栏不符，回到
Task 2/3 调整规则后再跑。

- [ ] **Step 3: 提交**

```bash
git add scripts/detect-probe.sh
git commit -m "feat(detect): 真机分类探针"
```

---

## Phase 2 · 状态槽位与列布局

### Task 5: `@whistle_live` 槽位 + 推导层优先级

**Files:**
- Modify: `lib/core.sh`（新增 `whistle_live_set`；`whistle_resolve_idle_panes` 读 live 列）
- Modify: `lib/core.sh:1379`、`lib/core.sh:1431`、`lib/core.sh:1528`（三处 format 串）
- Modify: `test/unit/core.bats:371` 起
- Modify: `test/integration/state.bats`

**Interfaces:**
- Consumes: 无
- Produces:
  - `whistle_live_set <state> [pane]` — `state` ∈ `running`/`idle`/空；空 = `-u @whistle_live`；stdout=pane id
  - 推导层新输入列 `@whistle_live` 插在**最后一个 `pane_current_command` 之前**，读作 `$(sc+5)`；输出列数不变

列契约（sc=2）：`pane|@whistle|notice|notice_msg|msg|@whistle_sub|@whistle_live|cmd`

- [ ] **Step 1: 写失败测试**

```bash
@test "resolve: live 在活动态为空时生效" {
  run whistle_resolve_idle_panes 'claude' 2 <<'EOF'
%1|||||1700000000|running|claude
EOF
  assert_eq "$output" '%1|running||running|'
}

@test "resolve: hook 活动态优先于 live" {
  run whistle_resolve_idle_panes 'claude' 2 <<'EOF'
%1|idle||||1700000000|running|claude
EOF
  assert_eq "$output" '%1|idle||idle|'
}

@test "resolve: 旧 6 列输入仍然有效" {
  run whistle_resolve_idle_panes 'claude' 2 <<'EOF'
%1|||活动消息|通知消息|claude
EOF
  assert_eq "$output" '%1|idle||idle|通知消息'
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats -f 'resolve:' test/unit/core.bats`
Expected: 前 2 个 failed；第 3 个应已 pass（回归基线）。

- [ ] **Step 3: 实现**

1. `whistle_live_set`：非空 `set -p @whistle_live <state>`，空用 `set -p -u @whistle_live`。
2. 推导层：`live = $(sc+5)`；`act` 为空时先取 `live`，再落到进程名推导。
3. 三处 format 串在最后的 `#{pane_current_command}` 前插入 `#{@whistle_live}`。

- [ ] **Step 4: 跑全部相关测试**

Run: `bats test/unit/core.bats && bats test/unit/menu.bats && bats test/integration/state.bats`
Expected: 全绿；菜单 10 列契约不变。

- [ ] **Step 5: 提交**

```bash
git add lib/core.sh test/unit/core.bats test/integration/state.bats
git commit -m "feat(core): 新增 @whistle_live 降级槽位并接入推导层"
```

---

## Phase 3 · 守护进程改造

### Task 6: detect 写活动态 + 仲裁

**Files:**
- Modify: `lib/detect.sh`（`whistle_detect_once` 主体）
- Create: `test/integration/detect.bats`

**Interfaces:**
- Consumes: `whistle_classify_screen` / `whistle_agent_kind` / `whistle_detect_eligible`（Task 3）、`whistle_live_set`（Task 5）
- Produces: `whistle_detect_once` 的新行为

行为：
1. 仲裁：`src` ∈ `hook`/`migration` 才跳过（原为「非空就跳过」）。
2. 只处理 `whistle_detect_eligible` 返回 0 的 pane（内部用 `whistle_agent_kind` + argv 排除）。
4. `running`/`idle` → `whistle_live_set`；`wait` 走现有通知通道；`freeze` 不动。
5. pane 不再是 agent → `whistle_live_set ''`。

- [ ] **Step 1: 写失败测试**

```bash
setup() {
  wt_start
  wt_load core
  unset TMUX_PANE TMUX
}
teardown() { wt_stop; }

pane_of() { wt display -p -t w1 '#{pane_id}'; }

# 让 pane 的前台命令变成 sleep（不在默认 agent_cmds 里），屏幕文本由 printf 留下
pane_with_text() {
  wt send-keys -t w1 "$1" Enter
  wt send-keys -t w1 'sleep 30' Enter
  wt_wait_until 2000 '[ "$(wt display -p -t w1 "#{pane_current_command}")" = sleep ]'
}

@test "detect: 无 hook 的 agent pane 写入 live" {
  wt set -g @whistle_agent_cmds sleep
  pane_with_text 'printf "› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = idle ]'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_live)" 'idle'
}

@test "detect: hook 接管的 pane 不写 live" {
  wt set -g @whistle_agent_cmds sleep
  wt set -p -t "$(pane_of)" @whistle_src hook
  pane_with_text 'printf "› \n"'
  sleep 2
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_live)" ''
}

@test "detect: 非 agent pane 不写 live" {
  wt set -g @whistle_agent_cmds claude
  pane_with_text 'printf "esc to cancel\n"'
  sleep 2
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_live)" ''
}

@test "detect: agent 退出后 live 被清空" {
  wt set -g @whistle_agent_cmds sleep
  pane_with_text 'printf "› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = idle ]'
  wt send-keys -t w1 C-c
  wt_wait_until 3000 '[ -z "$(wt show -pqv -t "$(pane_of)" @whistle_live)" ]'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_live)" ''
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats test/integration/detect.bats`
Expected: 至少前 2 个 failed。

- [ ] **Step 3: 实现**

- 一次 `list-panes -a -F '#{pane_id}|#{pane_current_command}|#{@whistle_src}|#{pane_pid}'` 取全，再逐个用 `whistle_detect_eligible` 过滤。
- argv 只在通过 `whistle_agent_kind` 的候选 pane 上读（`ps -o command= -p <pane_pid>`），避免多 fork。
- 变量前缀 `_dv_`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bats test/integration/detect.bats`
Expected: 4 passed。

- [ ] **Step 5: 提交**

```bash
git add lib/detect.sh test/integration/detect.bats
git commit -m "feat(detect): 屏幕分类写入活动降级槽位"
```

---

### Task 7: 防抖 + 自适应节奏

**Files:**
- Modify: `lib/detect.sh`
- Modify: `test/integration/detect.bats`

**Interfaces:**
- Consumes: Task 6
- Produces:
  - `whistle_detect_apply <pane> <state>` — 状态目录里维护 `<pane>.last`（已生效）与 `<pane>.pending` / `<pane>.count`；`→ running` 立即写，其余需连续 2 次
  - `whistle_detect_loop` 每轮后按「本轮是否有 agent pane」决定 `sleep 1` 还是 `sleep @whistle_detect_interval`

- [ ] **Step 1: 写失败测试**

```bash
@test "detect: running 立即生效、回落需两次" {
  wt set -g @whistle_agent_cmds sleep
  pane_with_text 'printf "• Working (3s • esc to interrupt)\n› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = running ]'
  # 清屏后只留空提示符：第一次扫描只记 pending，不该立刻回落
  wt send-keys -t w1 'clear' Enter
  wt send-keys -t w1 'printf "› \n"' Enter
  sleep 0.6
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_live)" 'running'
  wt_wait_until 4000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = idle ]'
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats -f 'running 立即生效' test/integration/detect.bats`
Expected: failed（回落立刻发生）。

- [ ] **Step 3: 实现**

`whistle_detect_apply` 按 D6 状态机实现；节奏按 D7。

- [ ] **Step 4: 跑测试确认通过**

Run: `bats test/integration/detect.bats`
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/detect.sh test/integration/detect.bats
git commit -m "feat(detect): 活动态防抖与自适应节奏"
```

---

---

### Task 8: 由 running→idle 转变补一条 done 通知

**Files:**
- Modify: `lib/detect.sh`（新增转变检测；**删除**旧的静默判定分支）
- Modify: `lib/core.sh:240`（`WHISTLE_DEFAULTS` 增加两个开关）
- Modify: `test/integration/detect.bats`

**Interfaces:**
- Consumes: Task 7 的 `whistle_detect_apply` 与状态目录
- Produces:
  - `whistle_detect_done_fire <pane>` — 在 `@whistle_notice` **为空**时写 `done`，标题 `检测到回合结束`；写完重算 window + global
  - 状态目录新增 `<pane>.run_since`（该 pane 本轮进入 `running` 的时间戳）
  - 配置 `@whistle_detect_done`（默认 `on`）、`@whistle_detect_done_min`（默认 `5`）

**为什么要单独做**：读屏拿不到 `last_assistant_message`，但「在跑 → 停下来了」这个转变本身是可靠信号。补一条无正文的 `done`，用户就能收到提醒，而不是只看到 `▶` 悄悄变成 `◉`。

**三条硬约束**：
1. **绝不写 `@whistle`**——done 走通知通道，与 hook 的两条通道语义一致。
2. **`@whistle_notice` 非空时一个字都不写**——未读通知的 rank 更高，覆盖等于把用户没看过的信息抹掉。
3. **`running` 持续时长不足 `@whistle_detect_done_min` 时不发**——TUI 重绘、瞬时闪烁都会造成假转变。

- [ ] **Step 1: 写失败测试**

```bash
@test "detect: running→idle 补一条 done 通知" {
  wt set -g @whistle_agent_cmds sleep
  wt set -g @whistle_detect_done_min 0
  pane_with_text 'printf "• Working (3s • esc to interrupt)\n› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = running ]'
  wt send-keys -t w1 'clear' Enter
  wt send-keys -t w1 'printf "› \n"' Enter
  wt_wait_until 5000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" = done ]'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" 'done'
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice_msg)" '检测到回合结束'
  # 活动通道不受影响
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle)" ''
}

@test "detect: running 时长不足不补 done" {
  wt set -g @whistle_agent_cmds sleep
  wt set -g @whistle_detect_done_min 30
  pane_with_text 'printf "• Working (3s • esc to interrupt)\n› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = running ]'
  wt send-keys -t w1 'clear' Enter
  wt send-keys -t w1 'printf "› \n"' Enter
  sleep 3
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" ''
}

@test "detect: 已有未读通知不被覆盖" {
  wt set -g @whistle_agent_cmds sleep
  wt set -g @whistle_detect_done_min 0
  wt set -p -t "$(pane_of)" @whistle_notice wait
  pane_with_text 'printf "• Working (3s • esc to interrupt)\n› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = running ]'
  wt send-keys -t w1 'clear' Enter
  wt send-keys -t w1 'printf "› \n"' Enter
  sleep 3
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" 'wait'
}

@test "detect: 开关关闭时不补 done" {
  wt set -g @whistle_agent_cmds sleep
  wt set -g @whistle_detect_done off
  pane_with_text 'printf "• Working (3s • esc to interrupt)\n› \n"'
  wt_wait_until 3000 '[ "$(wt show -pqv -t "$(pane_of)" @whistle_live)" = running ]'
  wt send-keys -t w1 'clear' Enter
  wt send-keys -t w1 'printf "› \n"' Enter
  sleep 3
  assert_eq "$(wt show -pqv -t "$(pane_of)" @whistle_notice)" ''
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bats -f '补一条 done' test/integration/detect.bats; bats -f '时长不足' test/integration/detect.bats`
Expected: 前两个 failed（`@whistle_notice` 为空）。

- [ ] **Step 3: 实现**

1. `whistle_detect_apply` 在写入 `running` 时，若 `<pane>.run_since` 不存在则记录 `$(whistle_now)`。
2. `running → idle` 转变被确认（连续 2 次分类为 idle）后：
   - 读 `@whistle_detect_done`，非 `on` 直接跳过；
   - 读 `<pane>.run_since`，`now - run_since < @whistle_detect_done_min` 跳过；
   - 读 `@whistle_notice`，非空跳过；
   - 否则 `whistle_notice_set done '检测到回合结束' '' "$pane"`，然后 `whistle_recompute_window` + `whistle_recompute_global`；
   - 删除 `<pane>.run_since`。
3. **删除**旧分支（`_quiet >= _idle && ... _done_re`）：转变检测取代静默检测。删除后若无其它引用，一并移除 `@whistle_detect_idle` 默认值与 `@whistle_detect_done-re` 的读取，并在 `docs/todo.md` 把 TODO-8 中与 `done-re` 相关的条目标记作废（`wait-re` 仍在用，保留）。
4. `WHISTLE_DEFAULTS` 追加：
   ```
   @whistle_detect_done on
   @whistle_detect_done_min 5
   ```

- [ ] **Step 4: 跑测试确认通过**

Run: `bats test/integration/detect.bats`
Expected: 全绿（含 Task 6/7 的 5 个用例）。

- [ ] **Step 5: 提交**

```bash
git add lib/detect.sh lib/core.sh test/integration/detect.bats
git commit -m "feat(detect): running→idle 转变补 done 通知"
```

---

## Phase 4 · 默认值与可观测性

### Task 9: 配置默认值、doctor 与文档

**Files:**
- Modify: `lib/core.sh:240`（`@whistle_detect` 默认 `on`）
- Modify: `bin/tmux-whistle`（doctor）
- Modify: `CLAUDE.md`、`AGENTS.md`、`docs/todo.md`
- Modify: `test/integration/doctor.bats`

**Interfaces:**
- Consumes: Task 6/7
- Produces: `doctor` 输出包含 `detect=on live=N`

- [ ] **Step 1: 写失败测试**

doctor 用例断言输出匹配 `detect=on`；默认值用例断言 `whistle_conf @whistle_detect` 为 `on`。

- [ ] **Step 2: 跑测试确认失败**

Run: `bats -f 'detect' test/integration/doctor.bats`
Expected: failed。

- [ ] **Step 3: 实现**

改默认值；`@whistle_detect` 变为 `off` 时清掉所有 pane 上的 `@whistle_live`（否则关掉开关后旧状态永久残留）；doctor 统计带 `@whistle_live` 的 pane 数；CLAUDE.md 增加「读屏降级通道」小节，写清 D1–D3。

- [ ] **Step 4: 跑测试确认通过**

Run: `bats -f 'detect' test/integration/doctor.bats`
Expected: passed。

- [ ] **Step 5: 提交**

```bash
git add lib/core.sh bin/tmux-whistle CLAUDE.md AGENTS.md docs/todo.md test/integration/doctor.bats
git commit -m "feat(detect): 默认开启读屏降级并加入 doctor"
```

---

## Phase 5 · 验收

### Task 10: e2e 与真机验收

**Files:**
- Create: `test/e2e/detect.bats`

**Interfaces:**
- Consumes: 全部
- Produces: 可重复的三态用例 + 手工验收清单

- [ ] **Step 1: 写 e2e 用例**

隔离 server + 伪造 agent pane（`@whistle_agent_cmds` 含 `sh`），依次打印 idle / working / wait 三态，断言 `@whistle_live` 与最终徽章。

- [ ] **Step 2: 跑测试确认通过**

Run: `bats test/e2e/detect.bats`
Expected: 3 passed。

- [ ] **Step 3: 全量检查**

Run: `make check`
Expected: 全绿，末尾无 `whistle-test-*` 残留。

- [ ] **Step 4: 真机验收（手工）**

1. 直接跑 `codex`，发一个 prompt：`▶` 出现，结束后 `◉` 且弹出 `◆`（标题「检测到回合结束」）。
2. 触发权限确认：`◔` 出现，批准后回落。
3. 多开两个 Codex TUI：两个 pane 的 `@whistle_live` 相互独立。
4. 退出 Codex：`@whistle_live` 清空，徽章不残留。

- [ ] **Step 5: 提交**

```bash
git add test/e2e/detect.bats
git commit -m "test(detect): 读屏降级通道 e2e"
```

---

## 回滚

任一步引入误报：`set -g @whistle_detect off` 立即回到旧行为。屏幕检测只写 `@whistle_live`，不影响 hook 真源；推导层在没有 live 时行为与今天完全一致。
