# 通知能力增强（第一批） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地设计方案评审的 A 档五条 —— 跳转精确到 pane、`jump` 认裸窗口名、菜单截断不再静默、`run --` 包装器、标题/正文分离。

**Architecture:** 不引入任何新依赖、不新增 UI 层、不改任何 tmux format。只在现有四层里做加法：`lib/core.sh` 的窗口级聚合多记一个 pane 身份，`bin/tmux-whistle` 多两个子命令 / 两个选项，状态多一个字段。五条全部**不改变任何现有行为**，可以逐条独立评审。

**Tech Stack:** POSIX sh + tmux ≥ 3.2；bats / shellcheck / shfmt（`make check`）

**Spec:** [../../notify-design-review.md](../../notify-design-review.md)（评审，§3 A 档 / §3 B 档）
**Todos:** [../../todo.md](../../todo.md)（TODO-12 / TODO-1 / TODO-2 / TODO-13 / TODO-14）

## Global Constraints

以下每条都是 `CLAUDE.md` 的既有红线，**每个 Task 都隐含包含**，违反不会报错、只会静默出错：

- **POSIX sh**：目标 shell 是 macOS 的 `/bin/sh`。没有局部变量 —— 函数里的临时变量一律带命名空间前缀（`_ws` / `_l*` / `_p*` / `_c*` / `_d*`）。禁用 `[[ ]]`、数组、`local -n`、`mapfile`、`$'...'`。
- `$var` 紧跟中文/全角字符必须写 `${var}`。
- **`tmux show` 必须带 `-v`**（global option 用 `-gqv`），否则读回的是 `名称 "值"` 整行。
- **pane 与 window 不能用同名 user option** —— 新增的 window 级字段必须叫 `@whistle_win_*`，不能叫 `@whistle_pane` 之类。
- **`run-shell` 绝不能排在 `\;` 链中间** —— 会阻塞 tmux 命令队列。
- **进入 tmux format 的文本必须过 `whistle_sanitize`**（剔 `# { } |` 与控制字符）。
- **不要删 `whistle_deliver` 开头的 `whistle_ensure_status_line`**。
- **`lib/core.sh` 里 `whistle_sanitize` / `whistle_rank` / `whistle_aggregate` / `whistle_count_states` 不得出现任何 tmux 调用** —— 这是 L1 单测能脱离 tmux 跑的前提。
- **`.bats` 不是合法 bash**，shfmt 解析不了 —— 格式化与格式检查都排除，靠 review 保证风格。
- **`.bats` 里 `done` / `wait` 作为裸词要加引号**（shellcheck SC1010 会拦）。
- 注释与用户可见文案一律中文；代码标识符英文。

**helper API 的三个坑**（`test/test_helper/whistle.bash`，写测试前先读一遍源文件确认）：

- **`wt_start` 不接受参数** —— 它固定起一个 session `main`、窗口 `w1`，唯一 pane 是 `%0`。
  要别的 session 用 `wt new-session -d -s other -n api`。
- **`optw` 读的是 global option，不是 window option** —— 它的实现是 `tmux show -gwv`。
  读 window 级 option（例如 `@whistle_win*`）必须走
  `wt show -wv -t "$w" <name>`，其中 `$w` 是 `wt display -p -t <target> '#{window_id}'` 的结果。
  **本批要断言的 `@whistle_win_pane` 正是 window 级。**
- **`optp` 要两个参数** —— `optp <option名> <pane_id>`。单参数调用会读空并静默返回空串。
- 被测 CLI 一律用 `"$CLI"` 调用，不要直接写 `tmux-whistle`（保证 PATH 与 socket 正确）。

**提交流程固定为**：`make fmt` → `make check` → 提交。`make check` 全绿是硬门槛。

## Review Focus

五条 Task 的测试都覆盖不到、但真实使用中最容易咬人的五种情形。按可能性排序：

1. **pane 在菜单弹出之后、命令执行之前被关掉** —— `select-pane` 报错，tmux 的 `;` 链遇错即停，后面的 `clear` 不执行，状态永远清不掉。Task 1 负责。
2. **多个 session 有同名窗口** —— `jump api` 现在静默取 `list-windows` 里的第一个，可能跳到你不认识的那个 session。撞名必须报错并列出候选，**不能静默取第一个**。Task 2 负责。
3. **`run` 包装的命令被 Ctrl-C 打断** —— 退出码 130，应该落 `error` 而不是保持 `running`（`running` 有 SessionEnd 兜底，但非 Claude Code 的进程没有）。Task 4 负责。
4. **`--body` 里的 `# { }` 与控制字符** —— pane option 本身不会被撑坏，但正文是给将来的事件历史/详情页用的，那边会进 tmux format。必须过消毒，且上限与 `@whistle_msg` 不同。Task 5 负责。
5. **菜单 hint 项与 `--menu-args` 视图分叉** —— `cmd_menu` 和 `cmd_menu_args` 是两份几乎相同的循环，只为让测试能在无 attached client 的情况下断言 argv。任何只改一边的修改都会让测试变假绿。Task 3 负责。

---

## File Structure

| 文件 | 本批的改动 |
|---|---|
| `lib/core.sh` | Task 1：聚合多输出 pane 列、窗口级多写 `@whistle_win_pane`、清除时一并清掉<br>Task 5：多写 `@whistle_body`、新增正文上限常量 |
| `bin/tmux-whistle` | Task 1：`cmd_menu` / `cmd_menu_args` 命令串加 `select-pane`<br>Task 2：`cmd_jump` 匹配裸窗口名 + 撞名报错<br>Task 3：菜单截断追加灰字提示项<br>Task 4：新增 `cmd_run` 与分派<br>Task 5：`cmd_set` 增加 `--title` / `--body` |
| `hooks/claude-code.sh` | Task 5：`Stop` / `StopFailure` 把完整回复作为 `--body` 传下去 |
| `test/unit/core.bats` | Task 1：13 处三列断言改四列 + 3 条新用例 |
| `test/integration/cli.bats` | Task 1/2/3/5 的 L2 用例 |
| `test/integration/run.bats` | Task 4：**新建**（独立文件，见下方「为什么串行」） |
| `test/e2e/claude_hook.bats` | Task 5：断言 hook 把完整回复写进 `@whistle_body` |
| `docs/todo.md` | 每个 Task 结束时把对应 TODO 挪进「已修复」 |

### 为什么串行、不并行

用户希望可并行的用 subagent 并行。逐对核对过文件重叠，结论是**只有 Task 4 真正文件不相交**：

| 组合 | 重叠文件 |
|---|---|
| Task 1 × Task 2 | `bin/tmux-whistle` 的 `cmd_jump` |
| Task 1 × Task 3 | `bin/tmux-whistle` 的 `cmd_menu` 与 `cmd_menu_args` |
| Task 1 × Task 5 | `lib/core.sh` 的 `whistle_state_clear` |
| Task 4 × 全部 | 无（新建 `cmd_run` + 独立测试文件） |

此外全部五条都要跑全量 `make check` —— 一个 Task 处于红状态时，其余 Task 的验证结论
全部失去意义。总量约 70 行实现 + 25 条用例，**串行的代价远小于协调成本**。
若确实要并发，只能是 `{Task 4}` ∥ `{Task 1 → 2 → 3}` 两路，且 Task 4 那一路
只跑自己的 `bats test/integration/run.bats`，不允许跑 `make check`。

---

### Task 1: 跳转精确到 pane

**Files:**
- Modify: `lib/core.sh`（`whistle_aggregate` / `whistle_recompute_window` / `whistle_state_clear`）
- Modify: `bin/tmux-whistle`（`cmd_menu` / `cmd_menu_args`）
- Test: `test/unit/core.bats`、`test/integration/cli.bats`

**Interfaces:**
- Consumes: 无（第一个 Task）
- Produces:
  - `whistle_aggregate` 的 stdout 从 3 列变 **4 列**，pane id 在**最末**列：
    `<state>|<msg>|<pending>|<pane_id>`。放末位是为了让 `whistle_recompute_global`
    现有的 `cut -d'|' -f3`（取待处理数）不用改。
  - 新 window 级 option `@whistle_win_pane`（pane 作用域，不存在时为空串）
  - `whistle_agent_windows` 的每行**从 6 列变 7 列**，pane id 插在**第 5 位**
    （`session|window_id|window_name|window_index|pane_id|state|msg`）

**背景（实现者必须知道，否则会踩）**：

`whistle_aggregate` 读进来的第一列就是 `#{pane_id}`（局部变量 `_pane_id`），
但目前只用于 `case` 过滤合法行、**读完就丢**。它必须同时决定「哪个状态胜出」
和「pane id 是谁」—— 若拆成两次扫描，两边可能选出不同的 pane，那就是 bug。
所以 pane 必须由同一个函数产出，这就是 `test/unit/core.bats` 里 13 处断言要改的原因。

`whistle_recompute_global` 喂的是 **2 列** format（`#{pane_id}|#{@whistle}`，无消息列），
`whistle_recompute_window` 喂的是 3 列。两种都能正常工作 —— aggregate 按位置读，不校验列数。

- [ ] **Step 1: 改 `test/unit/core.bats` 的 13 处三列断言为四列**

  `whistle_aggregate` 的输出末尾追加该胜出 pane 的 id。逐条把期望值改成：

  | 用例 | 输入 | 新期望 |
  |---|---|---|
  | `单个 pane 的状态原样透出` | `%1\|done\|重构完成` | `done\|重构完成\|1\|%1` |
  | `优先级 error > wait > done > running` | `%1\|running` / `%2\|done` / `%3\|wait` | `wait\|等你批\|2\|%3` |
  | `error 压过一切` | `%1\|done` / `%2\|wait` / `%3\|error` | `error\|炸了\|3\|%3` |
  | `全部 running 时输出 running，计数 0` | `%1\|running` / `%2\|running` | `running\|在跑\|0\|%1` |
  | `全部为空时输出空状态` | `%1\|\|` / `%2\|\|` | `\|\|0\|` |
  | `空输入` | `/dev/null` | `\|\|0\|` |
  | `@whistle 为空时消息不会被误读成状态` | `%1\|\|done` | `\|\|0\|` |
  | `消息含分隔符不会挤掉后续字段` | `%1\|done\|a\|b\|c` | `done\|a\|b\|c\|1\|%1` |
  | `跳过格式错误的行` | `garbage` + `%1\|done\|做完了` | `done\|做完了\|1\|%1` |
  | `跳过空行` | 空行 + `%1\|wait\|等你` + `%2\|done\|好了` | `wait\|等你\|2\|%1` |
  | `未知状态不计入 pending，也不顶优先级` | `%1\|banana\|脏数据` + `%2\|running` | `running\|在跑\|0\|%2` |
  | `最后一行没有换行符也要处理` | `printf '%%1\|done\|最后一行'` | `done\|最后一行\|1\|%1` |

  注意「全部为空」与「空输入」两例的第 4 列是**空串**（没有 pane 胜出），
  不是 `%1` —— `_best_rank` 为 0 时不会更新 pane。

- [ ] **Step 2: 加三条四列专属用例到 `test/unit/core.bats`**

```bats
@test "aggregate: 第 4 列是胜出状态的 pane id" {
    run whistle_aggregate <<'EOF'
%7|running|在跑
%12|wait|等你批
%3|done|好了
EOF
    assert_eq "$output" 'wait|等你批|2|%12'
}

@test "aggregate: 等级相同则取先出现的那个 pane" {
    # 窗口里两个 pane 同时 done：聚合取第一个（list-panes 的顺序）。
    # 断言的是「有确定答案」，不是「答案一定是谁」—— 顺序是 tmux 定的。
    run whistle_aggregate <<'EOF'
%4|done|甲
%9|done|乙
EOF
    assert_eq "$output" 'done|甲|2|%4'
}

@test "aggregate: pending 计数与 pane 列互不影响" {
    # 防「修过头」：多输出一列不能改变待处理数的语义。
    run whistle_aggregate <<'EOF'
%1|done|好了
%2|running|在跑
%3|error|炸了
EOF
    assert_eq "${output##*|}" '%3'
    assert_eq "$(printf '%s' "$output" | cut -d'|' -f3)" 2
}
```

- [ ] **Step 3: 跑 L1 单测，确认它红**

```sh
bats test/unit/core.bats
```

预期：12 条 `aggregate:` 用例失败（期望值仍是三列，实际输出四列）。

- [ ] **Step 4: 改 `lib/core.sh` 的 `whistle_aggregate`**

  在 `_best_rank` 初始化处并列加 `_best_pane=''`；在 `_rank` 大于 `_best_rank`
  的那个分支里同时赋值 `_best_pane=$_pane_id`；末行 `printf` 的格式串
  从 `'%s|%s|%s\n'` 改为 `'%s|%s|%s|%s\n'` 并追加 `"$_best_pane"`。
  **不要动** `case "${_pane_id:-}"` 那个过滤分支 —— 它是脏数据防线。

- [ ] **Step 5: 跑 L1 单测，确认它绿**

```sh
bats test/unit/core.bats
```

预期：全绿。

- [ ] **Step 6: 改 `whistle_recompute_window`，多写 `@whistle_win_pane`**

  该函数现在这样拆聚合串：

```sh
  _state=${_agg%%|*}
  _rest=${_agg#*|}
  _msg=${_rest%%|*}
  _count=${_rest#*|}
```

  `_count=${_rest#*|}` 拿到的是「第 3 列之后的所有」，四列时会连带第 4 列。
  改成依次多拆一次：`_rest=${_rest#*|}` 之后 `_count=${_rest%%|*}`、
  `_pane=${_rest#*|}`。在末尾的 `setw` 链里追加
  `\; setw -t "$_win" @whistle_win_pane "$_pane"`。

  窗口内**没有 pane 时**（pane 全部退出）`list-panes` 无输出 → aggregate 四列全空 →
  `@whistle_win_pane` 被写成空串，**自愈，不需要额外兜底**。

- [ ] **Step 7: 改 `whistle_state_clear`，一并清 `@whistle_win_pane`**

  不清会留下一个已失效的 pane id，后续 `select-pane` 必然报错。
  但 `@whistle_win_pane` 是 **window 级** option，`whistle_state_clear` 只知道 pane，
  所以这里**不要**去清它 —— 正确做法是：清完 pane 状态后由调用方
  （`whistle_recompute_window`）重算覆盖。这一点在 Step 6 已经天然成立。

  **因此本步只需确认 `whistle_state_clear` 无需改动**，并把这个结论写进该函数注释。

- [ ] **Step 8: 加两条 L2 用例到 `test/integration/cli.bats`**

```bats
@test "窗口级聚合记住胜出状态的 pane id" {
  wt set -p -t %0 @whistle done
  wt set -p -t %0 @whistle_msg '重构完成'
  local w
  w=$(wt display -p -t main:w1 '#{window_id}')
  "$CLI" --recompute

  assert_eq "$(wt show -wv -t "$w" @whistle_win_pane)" '%0'
}

@test "pane 状态清掉后 @whistle_win_pane 回落为空" {
  local w p
  w=$(wt display -p -t main:w1 '#{window_id}')
  p=$(wt display -p -t main:w1 '#{pane_id}')
  "$CLI" done '做完了' -t "$p"

  assert_eq "$(wt show -wv -t "$w" @whistle_win_pane)" "$p"
  "$CLI" clear -t "$p"
  assert_eq "$(wt show -wv -t "$w" @whistle_win_pane)" ''
}
```

  第二条同时是 Step 7「`whistle_state_clear` 无需改动」的证明：
  pane 清掉后 pane id **确实**回落为空 —— 因为重算覆盖了它。

  `@whistle_win_pane` 是 window 级 option，读它要用 `wt show -wv -t "$w"`，
  **不是** `optw`（那是 `show -gwv`，读 global）。这两条用例的 `setup` 沿用
  `cli.bats` 既有写法（`wt_start` + 导出 `$CLI`），先读该文件开头确认。

- [ ] **Step 9: 改 `bin/tmux-whistle` 的 `cmd_menu` 与 `cmd_menu_args`**

  `whistle_agent_windows` 的 `-F` 从 6 列变 7 列，pane 插在第 5 位：

```sh
-F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{pane_id}|#{@whistle}|#{@whistle_msg}'
```

  其 awk 里按位置取状态的 `$5` 要改成 `$6`（`$5 == "" { next }` 与那个三元 rank 表达式
  共两处）。`cmd_menu` 与 `cmd_menu_args` 两处 `read` 都要把 `_wi` 后面插入一个 `_pid`：

```sh
while IFS='|' read -r s wid wn _wi _pid st msg; do
```

  命令串里在 `select-window` 之后插 `select-pane -t $_pid`：

```
switch-client -t $s ; select-window -t $wid ; select-pane -t $_pid ; run-shell -b '...'
```

- [ ] **Step 10: 跑 L2 用例，确认它绿**

```sh
bats test/integration/cli.bats
```

  既有两条会直接为本 Task 提供验证，**不需要新写**：

  - `menu-args: 生成的命令是合法的 tmux 命令（不会 Unknown command）` ——
    会拿新的 `select-pane` 命令串真跑一遍 tmux，命令拼错就会红
  - `menu-args: 每项是 label / key / command 三元组` —— 会确认字段数没变

- [ ] **Step 11: `make fmt && make check`**

- [ ] **Step 12: 更新 `docs/todo.md`**

  把 **TODO-12** 从「待处理」挪到「已修复」，在其详情节补「已修」段落，
  写明：aggregate 输出加了第 4 列（放末位以免动 `cut -f3`）、13 处断言同步更新、
  `@whistle_win_pane` 由重算覆盖所以 `whistle_state_clear` 无需改动、
  以及那个「pane 已死会让 `;` 链中断」的风险尚未加兜底 —— 记进「已知限制」。

- [ ] **Step 13: 提交**

```sh
git add lib/core.sh bin/tmux-whistle test/unit/core.bats test/integration/cli.bats docs/todo.md
git commit -m "fix(jump): 窗口聚合记住 pane 身份，菜单跳转精确到 pane"
```

---

### Task 2: `jump` 接受裸窗口名 + 撞名不静默

**Files:**
- Modify: `bin/tmux-whistle`（`cmd_jump`）
- Test: `test/integration/cli.bats`

**Interfaces:**
- Consumes: Task 1 产出的 `@whistle_win_pane`（可选 —— 为空时跳过 `select-pane`）
- Produces: 无新符号

**背景**：`cmd_jump` 现在的匹配是三种：

```sh
awk -F'|' -v t="$_target" '$1 ":" $3 == t || $1 ":" $4 == t || $4 == t { print $2; exit }'
```

即 `session:窗口名`、`session:窗口序号`、裸窗口序号。**没有「裸窗口名」这一支**，
而 `whistle_list_lines` 输出的第二列恰恰是窗口名 —— 用户看到什么抄什么。

同一处还有第二个问题：裸序号 `1` 在多个 session 里都存在，`exit` 会静默取
`list-windows` 里的第一个。**跳错窗口比报错更糟**。

- [ ] **Step 1: 加五条 L2 用例到 `test/integration/cli.bats`**

  紧跟在既有的 `jump: 按 session:window 跳转并清除`（`cli.bats:239`）之后。
  既有用例的环境搭建写法是 `wt new-session -d -s other -n api` 再用
  `wt display -p -t other:api '#{pane_id}'` 取 pane id —— 下面几条沿用它：

```bats
@test "jump: 裸窗口名可以跳（list 显示什么就能跳什么）" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  "$CLI" "done" '做完了' -t "$p"

  run "$CLI" jump 'api'
  assert_eq "$status" 0
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
}

@test "jump: 裸窗口名撞名时报错并列出候选，不静默取第一个" {
  wt new-session -d -s other -n api
  local p1 p2
  p1=$(wt display -p -t other:api '#{pane_id}')
  p2=$(wt display -p -t main:w1 '#{pane_id}')
  wt new-window -t main -n api
  local p3
  p3=$(wt display -p -t main:api '#{pane_id}')
  "$CLI" "done" 'A session 的' -t "$p1"
  "$CLI" "done" 'B session 的' -t "$p3"

  run "$CLI" jump 'api'
  assert_eq "$status" 1
  assert_contains "$output" 'other:api'
  assert_contains "$output" 'main:api'
}

@test "jump: 裸窗口序号撞名时同样报错" {
  wt new-session -d -s other
  local p1 p2
  p1=$(wt display -p -t other:0 '#{pane_id}')
  p2=$(wt display -p -t main:0 '#{pane_id}')
  "$CLI" "done" 'A 的 0 号窗' -t "$p1"
  "$CLI" "done" 'B 的 0 号窗' -t "$p2"

  run "$CLI" jump '0'
  assert_eq "$status" 1
  assert_contains "$output" 'other'
  assert_contains "$output" 'main'
}

@test "jump: 找不到目标时报错退出" {
  run "$CLI" jump 'nosuch'
  assert_eq "$status" 1
  assert_contains "$output" '找不到'
}

@test "jump: session:窗口 的显式写法在撞名时不受影响" {
  wt new-session -d -s other -n api
  local p w
  p=$(wt display -p -t other:api '#{pane_id}')
  w=$(wt display -p -t other:api '#{window_id}')
  wt new-window -t main -n api
  "$CLI" "done" 'other 的' -t "$p"
  local p3
  p3=$(wt display -p -t main:api '#{pane_id}')
  "$CLI" "done" 'main 的' -t "$p3"

  run "$CLI" jump 'other:api'
  assert_eq "$status" 0
  # 只有 other 那个被清除，main 的原地不动
  assert_eq "$(wt show -wv -t "$w" @whistle_win)" ''
  assert_contains "$(wt show -pqv -t "$p3" @whistle)" 'done'
}
```

  第一条与既有的 `session:窗口` 用例形成对照：环境完全一样，
  唯一区别是目标写成裸 `api`，现在会红、改完会绿。
  第四条与既有用例 `jump: 找不到目标时报错退出` 重复度较高，
  保留是为了确认新增的 `$3 == t` 分支没有削弱原有的报错路径。

- [ ] **Step 2: 跑这几条，确认它们红**

```sh
bats -f 'jump' test/integration/cli.bats
```

  预期：第一条红（裸窗口名找不到），第二、三条红（现在静默取第一个，rc=0）。

- [ ] **Step 3: 改 `cmd_jump`**

  把 `exit` 换成收集全部匹配：awk 输出 `<window_id>|<session>:<window_name>`
  而不是裸 `$2`，然后在 shell 里数命中数 —— 0 个报错、1 个动手、多个报错列候选。

  匹配式加一支裸窗口名 `$3 == t`。**顺序不变式**：`$1 ":" $3 == t` 必须排在
  `$3 == t` 之前判断吗 —— 不需要，两者用 `==` 不存在前缀问题；但
  `$4 == t`（裸序号）与 `$1 ":" $4 == t` 都要保留。

  候选清单按 `<session>:<window_name>` 排序后逐行打印，一行一个。

- [ ] **Step 4: 让 `jump` 也选 pane**

  跳到窗口后，若该窗口的 `@whistle_win_pane` 非空且对应 pane 仍存在，
  追加一条 `select-pane -t $_pane`；为空则跳过。

  判存在用 `whistle_tmux display-message -p -t "$_pane" '#{pane_id}'`，
  取到才发 `select-pane`。这是 Task 1 那条「pane 已死会让 `;` 链中断」风险的兜底
  —— **不要省这一步**。

- [ ] **Step 5: 跑 `bats -f 'jump' test/integration/cli.bats`，确认绿**

- [ ] **Step 6: `make fmt && make check`**

- [ ] **Step 7: 更新 `docs/todo.md`**

  **TODO-1** 挪进「已修复」，补「已修」段落：加 `$3 == t` 那一支；
  **并明确写出这是一处行为变更** —— 裸序号撞名从「静默取第一个」变成「报错列候选」，
  跳错窗口比报错更糟。同步改 `README.md` 命令速查里 `jump` 那一行的说明。

- [ ] **Step 8: 提交**

```sh
git add bin/tmux-whistle test/integration/cli.bats docs/todo.md README.md
git commit -m "fix(jump): 认裸窗口名，撞名时列候选而不是静默取第一个"
```

---

### Task 3: 菜单截断不再静默

**Files:**
- Modify: `bin/tmux-whistle`（`cmd_menu` / `cmd_menu_args`）
- Test: `test/integration/cli.bats`

**Interfaces:**
- Consumes: Task 1 产出的 7 列 `whistle_agent_windows` 输出
- Produces: 无新符号

**背景**：26 是 `display-menu` 单键快捷键的**硬上限**（9 数字 + `a`–`q` 17 字母），
截断本身合理，问题是**静默**。当前硬编码 `[ "$_i" -gt 26 ] && break`。

现有用例 `menu-args: 超过 26 项时截断到 26`（`cli.bats:211`）断言的正是静默行为，
**本 Task 会推翻它** —— 这不是测试坏了，是需求变了。

- [ ] **Step 1: 改写既有用例 `menu-args: 超过 26 项时截断到 26`**

  `cli.bats` 里已有两个本地 helper 可直接复用：
  `seed_pending_windows <n>` 造 n 个待处理窗口，`menu_keys <输出>` 取每个
  三元组的第二行（快捷键行）。既有用例在 `cli.bats:211`。

  ⚠️ `menu_keys` 数的是**三元组总数**，加了提示项之后会多一个 ——
  这正是既有用例要改的原因，不是它坏了：

```bats
@test "menu-args: 超过 26 项时第 27 组是灰字提示，不是静默丢弃" {
  seed_pending_windows 28

  run "$CLI" --menu-args
  assert_eq "$status" 0

  # 27 个三元组 = 26 个可选项 + 1 个提示项
  assert_eq "$(menu_keys "$output" | wc -l | tr -d ' ')" 27

  # 前 26 个仍然可跳转 —— 提示项不能占用一个名额
  assert_eq "$(printf '%s\n' "$output" | grep -c '^switch-client')" 26

  # 第 27 组：以 - 开头（display-menu 的 disabled 语义）、无快捷键、命令是空转
  assert_contains "$output" '- 还有 2 项未显示'
  assert_contains "$output" 'tmux-whistle list'
}
```

- [ ] **Step 2: 加一条用例锁住提示项的空快捷键**

```bats
@test "menu-args: 提示项的快捷键为空（否则会被选走）" {
  seed_pending_windows 28

  run "$CLI" --menu-args
  # 最后一个三元组的三行：名字以 - 开头 / 快捷键空 / 命令空转
  local last
  last=$(printf '%s\n' "$output" | tail -n 3)
  assert_contains "$last" '- 还有'
  assert_eq "$(printf '%s\n' "$last" | sed -n 2p)" ''    # key 必须是空行
  assert_contains "$last" "display-message ''"
}
```

  这条是防「提示项能被按键选走」的护栏 —— 一旦 key 非空，用户按那个键
  会选中一条不可跳转的项，行为就退化成静默失败。

- [ ] **Step 3: 跑这两条，确认红**

```sh
bats -f 'menu-args' test/integration/cli.bats
```

- [ ] **Step 4: 改 `cmd_menu` 与 `cmd_menu_args`**

  两个循环都从「到 26 就 `break`」改成「**一直计数**，但只在 `_i <= 26` 时 `set --` 累积」。
  循环结束后若 `_total > 26`，追加一个 disabled 项：

```
- 还有 <_total-26> 项未显示，用 tmux-whistle list 查看
''
"display-message ''"
```

  `-` 前缀是 tmux 的 disabled 语义（绘制时剥掉那个 `-` 并置暗，选中与鼠标路径都会跳过），
  空 key 表示无快捷键，命令用空转。

  **两个函数必须改得一模一样** —— 它们是两份几乎相同的循环，只为了让测试能在
  无 attached client 的情况下断言 argv。只改一边 = 测试变假绿。

- [ ] **Step 5: 跑 `bats -f 'menu' test/integration/cli.bats`，确认绿**

  既有 `menu: 依赖 tmux 的双横线来放行以 - 开头的条目名` 会顺带验证
  新的 `-` 开头项能被 `display-menu` 接受（`--` 那个坑）。

- [ ] **Step 6: `make fmt && make check`**

- [ ] **Step 7: 更新 `docs/todo.md`**

  **TODO-2** 挪进「已修复」。补「已修」段落，并写明取舍：**没有做分页** ——
  `list` 本身无限项，提示项把用户指过去就够了，分页会让 `display-menu`
  的单键直达优势（一次按键直达）消失。

- [ ] **Step 8: 提交**

```sh
git add bin/tmux-whistle test/integration/cli.bats docs/todo.md
git commit -m "fix(menu): 超过 26 项时追加灰字提示，不再静默丢弃"
```

---

### Task 4: `run --` 命令包装器

**Files:**
- Modify: `bin/tmux-whistle`（新增 `cmd_run` + 分派处）
- Test: `test/integration/run.bats`（**新建**）
- Modify: `README.md`

**Interfaces:**
- Consumes: `whistle_state_set` / `whistle_pane_window` / `whistle_recompute_window` /
  `whistle_recompute_global` / `whistle_deliver`（全部现成）
- Produces: 新子命令 `tmux-whistle run [-- 标签] -- 命令 [参数...]`

**为什么测试放新文件**：Task 4 与 1/2/3 文件不相交，单独建 `run.bats`
让这一路可以独立跑（见上方「为什么串行」）。

**背景**：README「场景二」现在教用户手写 `cmd && done "…" || error "…"`，
漏写或写反都不报错、只是徽章不对。

⚠️ **不要用 `exec`** —— 那会替换掉当前 shell 进程，拿不到退出码。
直接跑 `"$@"` 再读 `$?` 即可，不需要 trap。

- [ ] **Step 1: 写新文件 `test/integration/run.bats` 的五条用例**

```bats
#!/usr/bin/env bats
# shellcheck shell=bash
#
# L2：run -- 命令包装器。退出码决定终态，退出码本身透传给调用方。

load '../test_helper/whistle'

setup() {
  wt_start                       # 起 session main / 窗口 w1 / pane %0
  local p
  p=$(wt display -p -t main:w1 '#{pane_id}')
  PANE="$p"
}

@test "run: 退出码 0 → done，消息带命令名" {
  run "$CLI" run -- sh -c 'exit 0'
  assert_eq "$status" 0
  assert_eq "$(optp @whistle "$PANE")" 'done'
}

@test "run: 退出码非 0 → error，消息里带退出码" {
  run "$CLI" run -- sh -c 'exit 7'
  assert_eq "$status" 7           # 包装器必须透传子命令退出码
  assert_eq "$(optp @whistle "$PANE")" 'error'
  assert_contains "$(optp @whistle_msg "$PANE")" '7'
}

@test "run: 命令结束后 running 被换成终态" {
  run "$CLI" run -- sh -c 'exit 0'
  assert_ne "$(optp @whistle "$PANE")" 'running'
  assert_eq "$(optp @whistle "$PANE")" 'done'
}

@test "run: 自定义标签覆盖命令名" {
  run "$CLI" run 'pnpm test' -- sh -c 'exit 0'
  assert_contains "$(optp @whistle_msg "$PANE")" 'pnpm test'
}

@test "run: 缺 -- 或缺命令时报错，不执行任何东西" {
  run "$CLI" run
  assert_ne "$status" 0
  run "$CLI" run --label
  assert_ne "$status" 0
}
```

  `setup` 里把 pane id 存进 `PANE` 是因为 `optp` 需要两个参数；
  沿用 `cli.bats` 开头导出 `$CLI` 的写法（先读该文件前 25 行确认）。
  第二条断言 `status` 为 7 是本 Task 的关键设计决定：**包装器必须透传退出码**，
  否则 `make && tmux-whistle run -- …` 这类链式写法会在失败时返回 0。

- [ ] **Step 2: 跑它，确认红**

```sh
bats test/integration/run.bats
```

  预期：全部失败 —— `run` 子命令还不存在，分派会落到 `*)` 分支打印 usage。

- [ ] **Step 3: 实现 `cmd_run` 并挂进分派**

  参数解析：`run` 之后、`--` 之前的词拼成标签；`--` 之后的**原样保留**给 `"$@"`
  （不 eval、不 word-split —— 用户引号怎么写就怎么传）。

  执行序列：置 `running`（消息 = 标签或命令行首词）→ 记录开始时间 →
  `"$@"` → `_rc=$?` → 按 `_rc` 置 `done` / `error`（消息含标签与耗时）→
  `recompute_window` + `recompute_global` + `deliver` → `exit $_rc`。

  状态转换那段**复用 `cmd_set`** 的编排，不要复制一份 —— 两处复制必然分叉。

- [ ] **Step 4: 跑它，确认绿**

```sh
bats test/integration/run.bats
```

- [ ] **Step 5: `make fmt && make check`**

- [ ] **Step 6: 更新 `docs/todo.md` 与 `README.md`**

  **TODO-13** 挪进「已修复」。README「场景二」把手写的 `&&` / `||` 换成
  `tmux-whistle run --` 的写法，并说明「包装器只认退出码，不解析输出」
  与「退出码透传」这两条语义。命令速查表加一行。

- [ ] **Step 7: 提交**

```sh
git add bin/tmux-whistle test/integration/run.bats docs/todo.md README.md
git commit -m "feat(run): 新增 run -- 命令包装器，按退出码落 done/error 并记耗时"
```

---

### Task 5: 标题 / 正文分离

**Files:**
- Modify: `lib/core.sh`（`WHISTLE_MSG_MAX` 附近新增常量、`whistle_state_set`）
- Modify: `bin/tmux-whistle`（`cmd_set` 增加 `--title` / `--body`）
- Modify: `hooks/claude-code.sh`（`Stop` / `StopFailure` 传完整回复）
- Test: `test/integration/cli.bats`、`test/e2e/claude_hook.bats`

**Interfaces:**
- Consumes: 无
- Produces:
  - 新常量 `WHISTLE_BODY_MAX=400`（与 `WHISTLE_MSG_MAX=80` 分开）
  - 新 pane option `@whistle_body`
  - `whistle_state_set` 的**第 4 个位置参数**（可选，追加在 `[pane]` 之后）：
    `whistle_state_set <state> <msg> [pane] [body]`
  - `cmd_set` 的 `--title` / `--body` 两个选项

**背景**：`@whistle_msg` 同时承担「徽章显示什么」和「全部内容」两个职责，
而 `whistle_sanitize` 单字段截到 80 字 —— 砍掉的部分没有任何地方能再找到。

**明确不做**：不让徽章优先渲染 `@whistle_title`。那要在已经是四层的
`whistle_mark_build` 条件式里再套一层 `#{?#{@whistle_title},...}`，
而嵌套 `#{?...}` 的大括号配平是本项目最贵的坑（配错一格 tmux **静默渲染成空串**）。
收益不值这个风险。

- [ ] **Step 1: 加四条 L2 用例到 `test/integration/cli.bats`**

```bats
@test "--title 与 --body 分开存：标题进 msg，正文不被 80 字截断" {
  local long p
  p=$(wt display -p -t main:w1 '#{pane_id}')
  long=$(printf '正文%.0s' $(seq 1 200))     # 400 个字符
  "$CLI" "done" --title '重构完成' --body "$long"

  assert_eq "$(optp @whistle_msg "$p")" '重构完成'
  assert_eq "$(optp @whistle_body "$p")" "$long"
}

@test "只给 --body 时 msg 取正文前 80 字（与现状完全一致）" {
  local long p
  p=$(wt display -p -t main:w1 '#{pane_id}')
  long=$(printf '文%.0s' $(seq 1 200))
  "$CLI" "done" --body "$long"

  assert_eq "$(optp @whistle_msg "$p")" "$(printf '%s' "$long" | cut -c 1-80)"
}

@test "两个都不给时行为与改动前完全一致" {
  local p
  p=$(wt display -p -t main:w1 '#{pane_id}')
  "$CLI" "done" '普通消息'

  assert_eq "$(optp @whistle_msg "$p")" '普通消息'
  assert_eq "$(optp @whistle_body "$p")" ''
}

@test "正文超过 400 字时按正文上限截断" {
  local huge p n
  p=$(wt display -p -t main:w1 '#{pane_id}')
  huge=$(printf '字%.0s' $(seq 1 600))
  "$CLI" "done" --body "$huge"

  n=$(printf '%s' "$(optp @whistle_body "$p")" | wc -m | tr -d ' ')
  assert_eq "$n" 400
}
```

  第一、二条一起锁住「不传 `--title` 时行为与改动前逐字一致」——
  这是「零行为变更」这个承诺的证据。第四条用 `wc -m` 数长度，
  与 `test/unit/core.bats` 的 `sanitize: 截断到 80 字符` 同一套做法
  （`printf '文%.0s' $(seq ...)`，在 UTF-8 locale 下 `wc -m` 按字符计）。

- [ ] **Step 2: 加一条 e2e 用例到 `test/e2e/claude_hook.bats`**

```bats
@test "e2e: Stop 的完整回复进 @whistle_body，首行进 @whistle_msg" {
    # 构造一个 last_assistant_message 多行的 hook JSON
    # 断言 @whistle_msg 是首行，@whistle_body 是全文
}
```

  沿用该文件里 `e2e: Stop → done，消息取自 last_assistant_message 首行`
  的 fixture 写法，把消息改成多行。

- [ ] **Step 3: 跑这两处，确认红**

```sh
bats -f 'title' test/integration/cli.bats
bats -f 'whistle_body' test/e2e/claude_hook.bats
```

- [ ] **Step 4: 改 `lib/core.sh`**

  - 在 `WHISTLE_MSG_MAX=80` 旁边加 `WHISTLE_BODY_MAX=400`
  - `whistle_sanitize` 改成接受第二个参数作为上限，默认 `WHISTLE_MSG_MAX`：
    `whistle_sanitize <文本> [上限]`。**现有所有调用点不传第二参，行为不变**。
  - `whistle_state_set` 增加第 4 个位置参数 `_body`，用上限 `WHISTLE_BODY_MAX` 消毒后
    多写一条 `set -p -t "$_pane" @whistle_body "$_body"`。
    **写在同一条 `\;` 链里** —— 它不会增加 fork（链是一进程），
    且空串也要写（否则会留上一次的残值）。
  - `whistle_state_clear` 的 unset 链加 `@whistle_body`
  - `whistle_clear_pane_state` 走的是 `whistle_state_clear`，自动继承

  ⚠️ `whistle_sanitize` 是 L1 纯函数，改签名后 `test/unit/core.bats` 的 13 条
  sanitize 用例必须仍然全绿（它们都不传第二参）—— 这是「没改坏」的证明。

- [ ] **Step 5: 改 `bin/tmux-whistle` 的 `cmd_set`**

  参数循环里加 `--title` / `--body` 两支（与现有 `-t` / `--dry-run` 同样的 `shift 2` 写法）。
  调用 `whistle_state_set "$_state" "$_msg" "$_target" "$_body"`。

  **title 与 body 的优先级**：给了 `--title` 就用它当 `$_msg`；没给而给了 `--body`，
  则 `$_msg` 取 body 前 80 字（交给 `whistle_sanitize` 的默认上限）。

- [ ] **Step 6: 改 `hooks/claude-code.sh`**

  `Stop` 与 `StopFailure` 两个分支现在取完消息后统一走
  `_msg=$(printf '%s' "$_msg" | head -n 1)` —— 改成**先存全文**再取首行：

```sh
_body="$_msg"
_msg=$(printf '%s' "$_msg" | head -n 1)
```

  最后一行调用改成带上 `--body "$_body"`。其余分支（`Notification` 等）
  消息本来就短，不传 `--body`。

- [ ] **Step 7: 跑 `make fmt && make check`**

  重点确认 `test/unit/core.bats` 的 13 条 sanitize 用例仍然全绿。

- [ ] **Step 8: 更新 `docs/todo.md`**

  **TODO-14** 挪进「已修复」，并在「已知限制」里补一条诚实的说明：
  **`@whistle_body` 目前存了但没有界面能看** —— 要等事件历史
  （`notify-design-review.md` 的 B-1 / 阶段 3）落地才有 UI。
  同时写明「没有改徽章 format」这个取舍及其原因（大括号配平风险）。

- [ ] **Step 9: 提交**

```sh
git add lib/core.sh bin/tmux-whistle hooks/claude-code.sh \
        test/integration/cli.bats test/e2e/claude_hook.bats docs/todo.md
git commit -m "feat(msg): 标题与正文分开存，完整回复不再被 80 字截断后丢失"
```

---

## 收尾

- [ ] **全量验收**：`make check` 从头绿一遍
- [ ] **活环境手工验证**（需要先造状态，验完清理）：

```sh
tmux-whistle done '验收测试'
tmux-whistle --menu-args | grep select-pane        # 期望：有输出
tmux-whistle clear -a
```

- [ ] **`docs/todo.md` 的「开发计划」表**：五行的状态全部从 `⬜ 未开始` 改为 `✅ 已完成`
- [ ] **`docs/development.md`**：目录结构里补上 `test/integration/run.bats`，
  以及 `docs/superpowers/plans/` 目录