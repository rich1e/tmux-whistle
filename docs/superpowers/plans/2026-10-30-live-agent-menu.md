# 实时 Agent 菜单 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `prefix + n` 的静态 `display-menu` 改为可持续刷新、重排后高亮跟随 window id 的交互式 popup 菜单。

**Architecture:** `lib/core.sh` 的 `whistle_agent_windows` 仍是唯一菜单数据源。新增 `lib/menu.sh`，将纯菜单模型、选中/按键逻辑、ANSI 渲染与终端交互放在一起；`bin/tmux-whistle` 只负责启动 popup、降级与复用现有 `cmd_clear` 跳转路径。

**Tech Stack:** POSIX sh、tmux >= 3.2 `display-popup -E`、awk、bats；仅开发测试使用 expect 伪终端驱动。

**Spec:** `docs/superpowers/specs/2026-10-30-live-agent-menu-design.md`

## Global Constraints

- 运行时保持 POSIX sh 与零第三方依赖；不得使用 bash 数组、`[[ ]]`、`local -n`、`mapfile`、`$'...'`。
- 继续支持 tmux >= 3.2；不得使用 tmux 3.3 才有的 `display-popup -T`，标题由弹窗内容绘制。
- 菜单每 0.5 秒读取一次插件已有状态，只在弹窗存活期间运行；数据未变化时不重绘。
- 选中身份使用 window id；可见项最多 26 个，快捷键为 `1`～`9`、`a`～`q`；只有 Esc 退出，未分配的 q 不执行操作。
- 跳转只复用 `cmd_clear -t <window> --select <pane>`；已读只清通知通道，绝不动活动通道。
- 菜单 running 保持静态 `▶`，不引入 Braille 动画；鼠标不在本期范围。
- 注释与用户可见文案使用中文；新函数临时变量使用 `_mu` 前缀。
- 所有交互测试使用 `whistle-test-*` 隔离 socket；teardown 必须 kill-server 并删除 socket 文件。
- 未经用户明确要求不执行 git commit；以下提交步骤仅在获得授权后执行，否则跳过并明确报告。

## Review Focus

1. **消息含 `|`**：消息必须始终位于模型末列，不能串到 window/pane 字段；由 Task 1 的模型测试钉住。
2. **选中窗口被挤到第 26 项以后**：高亮夹到原索引附近的可见项，Enter 不得跳隐藏目标；由 Task 2 的选择测试与 Task 5 的交互测试钉住。
3. **单独 Esc 与方向键 Esc 序列**：`27` 是退出，`27 91 65/66` 是 Up/Down；由 Task 2 的解码测试与 Task 4 的终端测试钉住。
4. **SIGINT/SIGTERM/正常退出**：终端模式、光标与后续输入必须恢复；由 Task 4 的 Ctrl-C 伪终端测试钉住。
5. **tmux 3.2 与无 attached client**：启动参数不得含 `display-popup -T`，失败时保留纯文本降级；由 Task 4 的 argv/降级测试钉住。

---

### Task 1: 共享菜单模型

**Files:**
- Create: `lib/menu.sh`
- Create: `test/unit/menu.bats`
- Modify: `bin/tmux-whistle:44-51,445-529,620-656`

**Interfaces:**
- Consumes: `whistle_agent_windows` 的 9 列输出：`session|window_id|window_name|window_index|pane_id|eff|notice|activity|message`。
- Produces: `whistle_menu_model`，从 stdin 读取上述 9 列，stdout 最多 27 行；可选行是 `item|key|window_id|pane_id|session|window_name|eff|message`，溢出行是 `overflow|hidden_count`。message 永远在末列。
- Produces: 从 `bin/tmux-whistle` 移入 `lib/menu.sh` 的 `whistle_menu_key`、`whistle_menu_overflow`、`whistle_menu_state_icon`、`whistle_menu_state_color`、`whistle_menu_item_label`，签名保持不变。

- [ ] **Step 1: 写模型失败测试**

在 `test/unit/menu.bats` 加载 core 与 menu，覆盖：
- 输入中第二个窗口是 done、第一个是 idle，模型先把 done 输出为 key 1；消息 `完成|含竖线` 原样留在末列。
- 造 27 个可选窗口，输出 26 行 `item` 加一行 `overflow|1`，第 26 行 key 是 q。
- 空输入输出为空。

关键断言形如：

```bash
assert_eq "$(printf '%s\n' "$output" | sed -n '1p')" \
  'item|1|@2|%2|dayfold|claude.exe|done|完成|含竖线'
assert_eq "$(printf '%s\n' "$output" | grep -c '^item|')" '26'
assert_contains "$output" 'overflow|1'
```

- [ ] **Step 2: 运行测试并确认失败**

Run: `bats test/unit/menu.bats`
Expected: FAIL，原因是 `lib/menu.sh` 或 `whistle_menu_model` 尚不存在。

- [ ] **Step 3: 实现模型并迁移菜单辅助函数**

新增 `lib/menu.sh`，用待处理优先、其余其次的两遍扫描实现 `whistle_menu_model`；只给前 26 项分配键，最后汇总隐藏数。把既有菜单辅助函数原样迁入，并在 CLI 的模块加载列表末尾加入 `menu`。

- [ ] **Step 4: 让 `--menu-args` 消费共享模型**

`cmd_menu_args` 改为读取 `whistle_agent_windows | whistle_menu_model`，item 行仍输出原来的 label/key/command 三元组，overflow 行仍调用 `whistle_menu_overflow`；对外输出格式不变。此任务暂不改 `cmd_menu`。

- [ ] **Step 5: 运行模型与 CLI 回归**

Run: `bats test/unit/menu.bats && bats test/integration/cli.bats`
Expected: 全部 PASS，既有 menu-args 的 26 键、溢出、消息与跳转断言不变。

- [ ] **Step 6: 经授权后提交**

```bash
git add lib/menu.sh test/unit/menu.bats bin/tmux-whistle
git commit -m "refactor(menu): 抽取共享菜单模型"
```

### Task 2: 选中身份与按键解码

**Files:**
- Modify: `lib/menu.sh`
- Modify: `test/unit/menu.bats`

**Interfaces:**
- Consumes: Task 1 的 item/overflow 模型。
- Produces: `whistle_menu_reconcile_selection <selected_window_id> <previous_index>`，从 stdin 读模型，输出 `window_id|index`；无可选项时输出空。
- Produces: `whistle_menu_select_key <char>`，从 stdin 读模型，输出匹配 item 的 `window_id|pane_id|index`；未分配时输出空。
- Produces: `whistle_menu_decode_key <octet1> [octet2] [octet3]`，输出 `up`、`down`、`enter`、`exit`、`char:<char>` 或 `unknown`。

- [ ] **Step 1: 写选择与解码失败测试**

覆盖以下精确情况：
- selected `@2`、previous index 2，刷新后 `@2` 排到第一，输出 `@2|1`。
- selected 窗口被排到第 27 项、previous index 26，输出新的第 26 个可见窗口与 `26`，不是隐藏窗口。
- selected 窗口消失时按 previous index 夹取；模型无 item 时输出空。
- `27 91 65` → `up`，`27 91 66` → `down`，`27` → `exit`，`13` → `enter`，`113` → `char:q`。
- 第 26 项时 `whistle_menu_select_key q` 返回该项；不足 26 项时返回空。

- [ ] **Step 2: 运行测试并确认失败**

Run: `bats -f 'selection|decode|select-key' test/unit/menu.bats`
Expected: FAIL，三个函数尚未定义。

- [ ] **Step 3: 实现三个纯函数**

选择协调只匹配可见 item：先按 window id 找；找不到则把 previous index 夹到 `[1, item_count]`。按键选择不响应 overflow。解码器只识别规格中的 ASCII/转义序列，其他输入统一返回 `unknown`。

- [ ] **Step 4: 运行全部纯函数测试**

Run: `bats test/unit/menu.bats test/unit/core.bats`
Expected: 全部 PASS。

- [ ] **Step 5: 经授权后提交**

```bash
git add lib/menu.sh test/unit/menu.bats
git commit -m "feat(menu): 保持重排选中项并解析按键"
```

### Task 3: ANSI 菜单渲染器

**Files:**
- Modify: `lib/menu.sh`
- Modify: `test/unit/menu.bats`

**Interfaces:**
- Consumes: Task 1 模型与既有 `whistle_menu_state_icon`、`whistle_menu_state_color`。
- Produces: `whistle_menu_ansi_fg <tmux_color>`，输出 ANSI 前景 SGR；`#RRGGBB` 必须映射为 `ESC[38;2;R;G;Bm`，无法映射时输出 `ESC[39m`。
- Produces: `whistle_menu_render <selected_window_id> <columns>`，从 stdin 读模型，输出含 `tmux-whistle` 标题、可选行、快捷键与溢出提示的完整 ANSI 帧；选中行使用反显。

- [ ] **Step 1: 写渲染失败测试**

在 `test/unit/menu.bats` 中把 `whistle_menu_state_icon` 与 `whistle_menu_state_color`
替换为固定 fake，保证渲染单测不访问 tmux。覆盖：
- `#00af00` 产生 `ESC[38;2;0;175;0m`，非法颜色安全回退。
- 帧内包含标题、图标、session/window、消息与 `(1)` 等键位，不包含字面 `#[`。
- selected window 对应行包含 `ESC[7m`，其他行不共用选中高亮。
- 长 ASCII 文本按 columns 截断且不破坏终止 SGR；中文与 emoji 消息保持原字符，不出现截断半字符。
- overflow 以不可选提示绘制，没有快捷键。

- [ ] **Step 2: 运行测试并确认失败**

Run: `bats -f 'ansi|render' test/unit/menu.bats`
Expected: FAIL，两个渲染函数尚未定义。

- [ ] **Step 3: 实现 ANSI 颜色与安全文本渲染**

先生成不带样式的文本与显示宽度，再加状态色/反显，避免把 SGR 字节计入截断长度。标题画在内容首行；任何输入文本不得被当成 ANSI 或 tmux format 执行。

- [ ] **Step 4: 运行渲染与既有回归**

Run: `bats test/unit && bats test/integration/cli.bats`
Expected: 全部 PASS。

- [ ] **Step 5: 经授权后提交**

```bash
git add lib/menu.sh test/unit/menu.bats
git commit -m "feat(menu): 添加 ANSI 弹窗渲染器"
```

### Task 4: Popup 启动、键盘交互与安全退出

**Files:**
- Modify: `lib/menu.sh`
- Modify: `bin/tmux-whistle:44-51,531-616,1091-1098`
- Modify: `test/integration/cli.bats`
- Create: `test/e2e/menu_popup.bats`
- Create: `test/test_helper/menu_popup.exp`
- Modify: `Makefile:24-39,90-94`

**Interfaces:**
- Consumes: Task 1～3 的模型、选择、解码与渲染接口。
- Produces: `whistle_menu_read_key`，以十进制 octet 输出一个按键（最多三个），0.1 秒无输入时输出空；单独 Esc 必须在短暂等待后续字节后返回 `27`。
- Produces: `whistle_menu_activate <window_id> <pane_id>`，恢复终端后调用 `cmd_clear -t "$1" --select "$2"`。
- Produces: `whistle_menu_ui`，在 attached popup 终端内运行并返回 0；内部 CLI 入口为 `tmux-whistle --menu-ui`。
- Produces: `cmd_menu` 使用 `display-popup -E` 启动上述入口；popup 失败时保留原有纯文本降级。

- [ ] **Step 1: 写启动参数与交互失败测试**

在 `test/integration/cli.bats` 增加 tmux spy：断言 popup argv 包含 `-E` 且不包含 `-T`，spy 失败时仍输出原纯文本列表。

在 `test/e2e/menu_popup.bats` 用 `test/test_helper/menu_popup.exp` 附着隔离 server，覆盖：
- 两个 idle 窗口中按 Down+Enter，跳到第二项；对 running+done 的目标，跳转后 notice 清空而 activity 仍是 running。
- 不足 26 项时按 q 不退出，再按 Down+Enter 仍能跳转。
- 单独 Esc 关闭弹窗后，在 pane 输入标记命令能看到输出；Up/Down 不会被当成 Esc。
- 弹窗内发送 Ctrl-C，随后 pane 输入与光标输出正常，证明终端恢复。

- [ ] **Step 2: 运行测试并确认失败**

Run: `bats test/integration/cli.bats test/e2e/menu_popup.bats`
Expected: 新用例 FAIL，当前仍调用 `display-menu`，且没有 `--menu-ui`。

- [ ] **Step 3: 实现终端输入、恢复与动作复用**

`lib/menu.sh` 用 POSIX 终端工具读取 octet；保存原始终端状态，并对 EXIT/HUP/INT/TERM 安装恢复逻辑。普通键通过 Task 2 的 `whistle_menu_select_key` 立即执行，方向键只移动可见 item，Enter 执行当前项，Esc 返回。

- [ ] **Step 4: 替换 `cmd_menu` 并接内部入口**

保留空列表提前提示；有数据时通过 `display-popup -E` 启动 `"$WHISTLE_SELF" --menu-ui`，不使用 `-T`。在 CLI dispatch 增加内部 `--menu-ui`。`Makefile` 的 deps 增加 expect 检查，test-integration 已包含 `test/e2e`，不新增第二套清理路径。

- [ ] **Step 5: 运行交互与既有回归**

Run: `bats test/integration/cli.bats test/e2e/menu_popup.bats && make check-no-stray-servers`
Expected: 全部 PASS；无残留 `whistle-test-*` server 或 socket。

- [ ] **Step 6: 经授权后提交**

```bash
git add lib/menu.sh bin/tmux-whistle test/integration/cli.bats test/e2e/menu_popup.bats test/test_helper/menu_popup.exp Makefile
git commit -m "feat(menu): 使用交互式 popup 替代静态菜单"
```

### Task 5: 实时刷新、文档与全量验收

**Files:**
- Modify: `lib/menu.sh`
- Modify: `test/e2e/menu_popup.bats`
- Modify: `test/test_helper/menu_popup.exp`
- Modify: `README.md:302,370`
- Modify: `CLAUDE.md:255-256`
- Modify: `bin/tmux-whistle:481-488`

**Interfaces:**
- Consumes: Task 4 的 `whistle_menu_ui` 与 Task 2 的 `whistle_menu_reconcile_selection`。
- Produces: 0.5 秒周期的模型刷新；模型字符串变化才调用 `whistle_menu_render`，每次变化都先恢复选中 window id。

- [ ] **Step 1: 写实时刷新失败测试**

在 expect 场景中：
- 菜单打开后，从外部把 dayfold 改为 running 并带唯一消息 `fresh-running-marker`；2 秒内不重开菜单即可在弹出输出中读到该标记。
- 初始选中第二个 dayfold，外部把它改为 done 使其移到待处理区第一位；重绘后按 Enter 仍进入 dayfold，而不是新列表第二项。
- 无状态变化的 1 秒间隔内，渲染日志中的标题帧数不增加。
- 选中项被挤到 26 项以外时，Enter 选择协调后的可见项，绝不选择隐藏 window id。

- [ ] **Step 2: 运行测试并确认失败**

Run: `bats test/e2e/menu_popup.bats`
Expected: 实时标记与重排跟随用例 FAIL，当前弹窗只读初始模型。

- [ ] **Step 3: 实现 0.5 秒模型刷新**

每轮输入超时累计到 0.5 秒时重新执行 `whistle_agent_windows | whistle_menu_model`；与上一模型相同则继续等待，不同则先调用选择协调再渲染。按键与刷新保持串行，激活时使用最近一次已绘制模型的 window/pane id。

- [ ] **Step 4: 更新用户与开发文档**

README 说明菜单会自动刷新、重排后高亮跟随、Esc 退出及 26 键规则；删除「菜单是一次性快照」。CLAUDE.md 改为 popup 实时菜单并保留静态 running 图标的理由；同步修正 `bin/tmux-whistle` 的旧注释。全量测试后把 CLAUDE.md 的「当前 401 项测试」更新为实际总数。

- [ ] **Step 5: 运行完整验证**

Run:

```bash
make fmt
make check
make check-no-stray-servers
```

Expected: lint、fmt-check、全部 L1/L2/L3 测试 PASS；没有残留隔离 server。随后按规格执行六项人工验收，尤其确认 Esc 后无残留 `--menu-ui` 进程。

- [ ] **Step 6: 经授权后提交**

```bash
git add lib/menu.sh test/e2e/menu_popup.bats test/test_helper/menu_popup.exp README.md CLAUDE.md bin/tmux-whistle docs/superpowers/specs/2026-10-30-live-agent-menu-design.md docs/superpowers/plans/2026-10-30-live-agent-menu.md
git commit -m "feat(menu): 自动刷新状态并跟随选中窗口"
```
