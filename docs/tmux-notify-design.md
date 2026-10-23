# tmux-notify：tmux 通知中心产品与 UI/UX 设计

> 版本：V1 产品设计草案\
> 产品定位：面向 tmux 多 Pane、多 Window、多 Session
> 工作流的轻量通知中心\
> 交互方案：B --- 终端通知中心型\
> 设计原则：轻量、键盘优先、不抢占焦点、可追踪、工具无关

------------------------------------------------------------------------

## 1. 产品概述

`tmux-notify` 是一个独立于具体 Agent 的 tmux 通知系统。它统一收集来自
Shell 脚本、长时间运行的命令、Claude Code、Codex
及其他工具的事件，并通过状态栏、Popup 和通知中心呈现。

核心目标：

-   不需要频繁切换 Pane 检查后台任务。
-   快速识别需要关注的事件。
-   从通知一键定位到来源 Session、Window 和 Pane。
-   区分通知是否已读与任务是否已处理。
-   在轻量实现的基础上，为未来的多 Agent 任务监控保留扩展空间。

### 1.1 目标用户

-   同时运行多个 AI Agent 的开发者。
-   在不同 Pane 执行构建、测试、部署等耗时任务的开发者。
-   需要管理多个 tmux Session、Window 和 Pane 的终端重度用户。

### 1.2 核心理念

> 让任务主动告诉你发生了什么，而不是让你不断切换 Pane 去检查任务状态。

------------------------------------------------------------------------

## 2. 产品范围与版本规划

### 2.1 V1 功能范围

  模块           功能                       优先级
  -------------- -------------------------- --------
  状态栏         未读、待处理、异常数量     P0
  通知 CLI       主动发送通知               P0
  通知中心       列表、筛选、键盘导航       P0
  Pane 定位      定位到来源 Pane            P0
  通知管理       已读、未读、关闭通知       P0
  事件存储       持久化通知记录             P0
  Popup          重要事件短暂提醒           P1
  通知合并       合并短时间内的重复事件     P1
  静音模式       暂停 Popup，继续记录事件   P1
  任务监控       汇总任务运行状态           V2
  Agent 适配器   Claude Code、Codex 等      V2
  macOS 通知     系统级通知                 V2

### 2.2 V1 不做的事情

-   不尝试自动理解任意终端输出。
-   不把"长时间没有输出"直接判定为等待输入。
-   不要求所有命令都通过专用包装器执行。
-   不依赖 Claude Code 或其他特定 Agent。
-   不在后台任务发生变化时自动切换焦点。
-   不在第一版实现复杂的多 Agent 任务控制台。

### 2.3 产品路线

**Phase 1：MVP** - CLI 发送事件。 - 事件持久化。 - 状态栏摘要。 -
通知中心。 - 筛选、已读/未读、关闭通知。 - 定位来源 Pane。

**Phase 2：任务状态管理** - 任务开始、运行、完成、失败事件。 - Popup
通知。 - 通知去重与合并。 - 静音和暂停通知。 - 任务监控面板。

**Phase 3：生态集成** - Claude Code Hooks。 - Codex 等 Agent 适配器。 -
macOS 系统通知。 - 可配置通知规则与模板。

------------------------------------------------------------------------

## 3. 信息架构

通知系统分为四层：

1.  **Status Bar Indicator**：提供常驻摘要和入口。
2.  **Popup Notification**：重要事件的短暂提醒。
3.  **Notification Center**：完整的事件列表、筛选、搜索与操作。
4.  **Task Monitor**：未来版本提供跨 Pane 的任务状态汇总。

这四层应相互独立。关闭 Popup
不会删除事件；不使用状态栏也不影响通知中心；未来替换 TUI
实现时，事件生产者与存储接口无需改变。

------------------------------------------------------------------------

## 4. UI 设计

## 4.1 状态栏通知指示器

建议在 tmux 状态栏右侧显示通知摘要。

示意：

``` text
┌────────────────────────────────────────────────────────────────────────────┐
│ [0] zsh  [1] frontend*  [2] backend  [3] tests             ◆ 2  ✖ 1  ◉ 3 │
└────────────────────────────────────────────────────────────────────────────┘
```

标识定义：

-   `◆ 2`：2 个待处理事件。
-   `✖ 1`：1 个异常事件。
-   `◉ 3`：3 条未读通知。

待处理数量、异常数量和未读数量是不同维度，不能相互替代：

-   一条通知可以已读，但对应任务仍待处理。
-   一个任务可以产生多条通知。
-   一个任务可以仍在运行，但没有新通知。
-   关闭通知不代表任务已修复。

状态栏只负责摘要与入口，不承载复杂操作。

### 推荐行为

-   状态栏命令只读取轻量状态，不进行昂贵扫描。
-   通知事件入库后更新摘要缓存。
-   状态栏刷新不能重复创建事件。
-   允许用户自定义状态栏格式和快捷键。

## 4.2 Popup 通知

Popup 用于重要事件的短暂提示，不应抢占当前焦点。

### 任务完成

``` text
┌─────────────────────────────────────────────┐
│ ✓ TASK COMPLETED                            │
│                                             │
│ frontend / pane %12                         │
│ Component refactoring completed             │
│                                             │
│ Duration: 4m 32s                             │
│                                             │
│ [Prefix+n] Review notifications              │
└─────────────────────────────────────────────┘
```

### 等待用户操作

``` text
┌─────────────────────────────────────────────┐
│ ◆ ACTION REQUIRED                           │
│                                             │
│ backend / pane %15                          │
│ Waiting for confirmation                    │
│                                             │
│ Task: Update database schema                │
│                                             │
│ [Prefix+n] Review  [s] Snooze                │
└─────────────────────────────────────────────┘
```

### 任务失败

``` text
┌─────────────────────────────────────────────┐
│ ✖ TASK FAILED                               │
│                                             │
│ tests / pane %18                             │
│ Test suite failed                            │
│ Exit code: 1                                 │
│                                             │
│ [Prefix+n] Review notifications              │
└─────────────────────────────────────────────┘
```

### Popup 默认规则

  事件类型       显示 Popup   自动消失           保留记录
  -------------- ------------ ------------------ ------------------------
  成功           是           是，建议 3--5 秒   是
  失败           是           是                 是，保留异常状态
  等待用户操作   是           是                 是，待处理状态持续存在
  普通信息       默认否       ---                可配置
  高频重复事件   合并后显示   是                 是

Popup 消失只代表提示结束，不代表事件已读或任务已解决。

### 通知合并

短时间内同一来源产生大量相似事件时，合并提示，避免连续弹出。

例如：

``` text
┌─────────────────────────────────────────────┐
│ ✓ 3 TASKS COMPLETED                         │
│                                             │
│ frontend, backend, tests                    │
│                                             │
│ Press Prefix+n to review                    │
└─────────────────────────────────────────────┘
```

对 `action_required` 和 `failed`
应采取更保守的合并策略，避免吞掉重要事件。

## 4.3 通知中心

通知中心是 V1 的核心 UI，建议通过 tmux 原生 Popup 打开，不改变现有 Pane
布局。

推荐初始尺寸：终端宽度的约 85%、高度的约 80%，并根据终端尺寸做降级布局。

### 列表视图

``` text
╭──────────────────────────────────────────────────────────────────────────────╮
│ TMUX NOTIFY                                           3 unread  2 pending    │
├──────────────────────────────────────────────────────────────────────────────┤
│ [All] [Pending] [Failed] [Success] [Unread]                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ ◆ Waiting for confirmation                                      10:32:18    │
│   development / backend / pane %15                                          │
│   Please confirm the database migration                                    │
│                                                                              │
│ ✖ Test suite failed                                             10:30:42    │
│   development / tests / pane %18                                            │
│   Exit code: 1                                                              │
│                                                                              │
│ ✓ Frontend build completed                                      10:28:12    │
│   development / frontend / pane %12                                        │
│   Duration: 4m 32s                                                          │
│                                                                              │
│ · New message from Claude Code                                  10:25:03    │
│   development / backend / pane %15                                         │
│   Code review completed. Please check the changes.                         │
├──────────────────────────────────────────────────────────────────────────────┤
│ ↑↓ Navigate  Enter Jump  Space Read  d Details  x Dismiss  m Mute  q Quit  │
╰──────────────────────────────────────────────────────────────────────────────╯
```

布局区域：

1.  标题和统计摘要。
2.  分类筛选栏。
3.  通知列表。
4.  底部快捷键提示。

建议先实现紧凑单列表视图，避免第一版就引入复杂分栏布局。

### 详情视图

``` text
╭──────────────────────────────────────────────────────────────────────────────╮
│ Notification Detail                                                  1 / 4  │
├──────────────────────────────────────────────────────────────────────────────┤
│ ◆ Waiting for confirmation                                      [pending]   │
│ 10:32:18 · development / backend / pane %15                                 │
├──────────────────────────────────────────────────────────────────────────────┤
│ Message                                                                      │
│ Please confirm the database migration. This operation will modify the        │
│ production database schema.                                                  │
│                                                                              │
│ Context                                                                      │
│ Session: development                                                         │
│ Window:  backend                                                             │
│ Pane:    %15                                                                 │
│ Command: ./scripts/migrate.sh                                                │
│                                                                              │
│ Recent output                                                                │
│ > Running database migration...                                              │
│ > Migration 001_add_users_table.sql                                         │
│ > Please confirm to continue (y/n):                                          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Enter Jump  x Dismiss  q Back                                                │
╰──────────────────────────────────────────────────────────────────────────────╯
```

详情视图可显示完整消息、来源位置、事件时间、命令信息，以及事件生产者提供的上下文。终端输出摘要应限制长度，并对控制字符进行清理。

## 4.4 Pane 定位交互

用户在通知列表中选中一条事件并按 `Enter`：

1.  检查来源 Pane 是否仍然存在。
2.  切换到目标 Session。
3.  切换到目标 Window。
4.  选择目标 Pane。
5.  关闭通知中心。
6.  将焦点交给目标 Pane。

应优先保存稳定的 tmux Pane ID（例如 `%15`），而不是只保存 Pane 序号。

如果来源 Pane 已被关闭，应提示"来源 Pane
已不存在"，并允许用户查看通知详情，而不是让通知中心崩溃。

建议默认直接跳转；如果需要确认，可提供配置项切换为跳转确认菜单。

## 4.5 筛选与搜索

建议内置以下筛选：

-   All：全部通知。
-   Pending：尚未处理的事件。
-   Failed：失败或异常事件。
-   Success：成功事件。
-   Unread：未读通知。

搜索可以匹配标题、消息、Session 名、Window 名、Pane ID 和来源工具。

第一版可先实现本地文本匹配，不需要模糊搜索或复杂查询语法。

## 4.6 未来的任务监控 UI

任务监控属于 V2，不应阻塞 V1。

``` text
╭──────────────────────────────────────────────────────────────────────────────╮
│ TASK MONITOR                                                   4 tasks       │
├──────────────────────────────────────────────────────────────────────────────┤
│ STATUS     SESSION       WINDOW       PANE       DESCRIPTION                 │
│ ● Running  development   frontend     %12        Refactoring components     │
│ ◆ Waiting  development   backend      %15        Awaiting confirmation      │
│ ✖ Failed   development   tests        %18        Test suite failed           │
│ ✓ Done     maintenance   cleanup      %21        Cleanup completed           │
├──────────────────────────────────────────────────────────────────────────────┤
│ r Refresh  Enter Jump  n Notifications  q Quit                              │
╰──────────────────────────────────────────────────────────────────────────────╯
```

------------------------------------------------------------------------

## 5. 交互规范

### 5.1 快捷键建议

  快捷键               行为
  -------------------- -----------------
  `Prefix + n`         打开通知中心
  `Prefix + N`         打开待处理通知
  `↑ / ↓` 或 `k / j`   移动选中项
  `g`                  跳到第一条
  `G`                  跳到最后一条
  `Enter`              定位到来源 Pane
  `Space`              切换已读/未读
  `d`                  打开详情
  `x`                  关闭通知
  `/`                  搜索
  `Tab`                切换筛选类别
  `m`                  切换静音
  `q`                  退出或返回

快捷键必须允许用户配置，并避免强制覆盖现有 tmux 或插件绑定。

### 5.2 通知状态与任务状态必须分离

通知状态：

``` text
Created → Unread ↔ Read → Dismissed
```

任务状态：

``` text
Running
  ├── Waiting for Input
  ├── Completed
  └── Failed
```

`Read` 只代表用户看过通知，不代表任务已解决。`Dismissed`
只代表通知从常规列表隐藏，也不代表任务已经修复。

任务状态可以由事件生产者更新；若缺乏可靠信号，应标记为
`Unknown`，而不是猜测。

### 5.3 静音模式

建议支持：

-   Normal：正常通知。
-   Silent：不显示 Popup，但记录事件并更新状态栏。
-   Do Not Disturb：暂停非关键提示，关键事件是否例外由配置决定。

第一版可先实现全局静音。按 Session、Window、Pane 单独静音可以延后。

### 5.4 不抢占焦点

-   后台事件不得自动切换 Session、Window 或 Pane。
-   Popup 不能导致当前工作流被中断。
-   关闭 Popup 不影响任务。
-   只有用户主动操作才定位到来源 Pane。

------------------------------------------------------------------------

## 6. 通知规则与事件来源

### 6.1 显式通知

事件生产者通过 CLI 主动发送事件，这是最可靠的方式。

``` bash
tmux-notify send \
  --level success \
  --title "Build completed" \
  --message "Frontend build succeeded"
```

待处理事件：

``` bash
tmux-notify send \
  --level action \
  --title "Waiting for confirmation" \
  --message "Please confirm the database migration"
```

失败事件：

``` bash
tmux-notify send \
  --level error \
  --title "Test failed" \
  --message "Test suite exited with code 1"
```

### 6.2 命令生命周期通知

可以提供可选的命令包装器：

``` bash
tmux-notify run -- pnpm test
```

包装器记录开始事件，并依据进程退出状态发送成功或失败事件。它不能自动判断所有交互式程序的内部状态。

### 6.3 Pane 状态推断

不应把"长时间没有输出"直接等同于"等待用户输入"。

  观察结果                     建议状态                  可信度
  ---------------------------- ------------------------- --------------
  事件生产者明确发送 waiting   Waiting                   高
  已知工具提供明确等待信号     Waiting                   视适配器而定
  命令退出码为 0               Completed                 高
  命令退出码非 0               Failed                    高
  Pane 长时间没有输出          Unknown / Possibly Idle   低
  进程仍然存在                 Running 或 Unknown        低至中

默认只对高可信度事件触发强提醒。

------------------------------------------------------------------------

## 7. 事件模型与存储

### 7.1 事件示例

``` json
{
  "id": "evt_01JABC123",
  "timestamp": "2026-10-22T10:32:18+08:00",
  "source": "shell",
  "type": "action_required",
  "level": "action",
  "title": "Waiting for confirmation",
  "message": "Please confirm the database migration",
  "session_id": "$2",
  "window_id": "@4",
  "pane_id": "%15",
  "read": false,
  "dismissed": false,
  "task_id": "task_01JABC",
  "task_status": "waiting_input"
}
```

### 7.2 建议分离事件与任务实体

一个任务可能产生多条事件，例如：

``` text
Task: frontend build

10:00  Started
10:03  Failed
10:05  Retried
10:08  Completed
```

因此长期结构建议为：

``` text
Task
├── Task ID
├── Current Status
├── Session / Window / Pane
└── Events
    ├── Started
    ├── Failed
    ├── Retried
    └── Completed
```

V1 可以简化任务模型，但不要把历史事件覆盖成最新状态。

### 7.3 存储方案

建议使用 SQLite 作为正式实现的默认存储：

-   支持并发写入和查询。
-   方便筛选、搜索和保留历史。
-   可用事务维护已读、关闭等状态。
-   不需要独立服务进程。

如果原型阶段希望尽量减少依赖，也可以先用
JSONL，但必须处理并发写入、损坏恢复和状态更新问题。不要让状态栏刷新过程修改事件数据。

### 7.4 清理策略

建议提供可配置的默认保留策略：

-   已读成功通知：保留 24 小时。
-   普通通知：保留 24 小时。
-   已关闭通知：保留 7 天。
-   未解决的待处理事件：持续保留。
-   失败事件：保留 7 天或更久。

清理通知记录不能自动把任务标记为完成。

------------------------------------------------------------------------

## 8. 技术架构

``` text
tmux Panes / Shell Scripts / Agent Hooks
                  │
                  ▼
           tmux-notify CLI
                  │
                  ▼
          Event Dispatcher
    Validate → Normalize → Deduplicate
                  │
                  ▼
            SQLite Store
                  │
          ┌───────┴────────┐
          ▼                ▼
      Status Bar      Python TUI
                           │
                 ┌─────────┴─────────┐
                 ▼                   ▼
          Notification Center   Popup / Details
                 │
                 ▼
            Pane Locator
```

### 8.1 技术选型建议

  组件               建议                      职责
  ------------------ ------------------------- ---------------------------------
  CLI 与 tmux 集成   Shell                     发送事件、打开 Popup、定位 Pane
  存储               SQLite                    事件、状态、查询与清理
  通知中心 UI        Python TUI                列表、筛选、搜索、详情
  Popup              tmux `display-popup`      承载通知中心或重要提示
  状态栏             tmux `status-right`       展示摘要
  测试               ShellCheck、shfmt、Bats   静态检查、格式化、单元测试

Python TUI
可以选择适合终端应用的库。选择时应重点评估键盘导航、终端尺寸变化、Unicode
宽度、颜色主题、依赖体积和 macOS 兼容性。

不建议第一版引入 Node.js 服务、Electron 或常驻后台服务。

### 8.2 状态栏集成示意

``` tmux
set -g status-right '#(tmux-notify status) | %H:%M'
set -g status-interval 2
```

注意：

-   `tmux-notify status` 应快速返回。
-   优先读取缓存摘要，不扫描所有 Pane。
-   输出应控制长度，避免换行和控制字符破坏状态栏。
-   状态栏刷新不得重复写入通知。

### 8.3 快捷键集成示意

``` tmux
# Open notification center
bind n run-shell 'tmux-notify center'

# Show pending notifications
bind N run-shell 'tmux-notify center --filter pending'

# Future task monitor
bind T run-shell 'tmux-notify tasks'
```

以上是示意配置，正式安装时应允许用户选择快捷键，并避免覆盖已有绑定。

### 8.4 Popup 集成示意

``` bash
tmux display-popup \
  -E \
  -w 85% \
  -h 80% \
  "tmux-notify center"
```

应根据终端尺寸进行降级布局。目标 Pane 不存在、tmux Server 不可用或 UI
启动失败时，应显示可理解的错误信息，而不是直接退出并丢失上下文。

------------------------------------------------------------------------

## 9. CLI 设计

建议统一使用 `tmux-notify` 命令：

``` bash
# Send a success notification
tmux-notify send \
  --level success \
  --title "Build completed" \
  --message "Frontend build succeeded"

# Send an action-required notification
tmux-notify send \
  --level action \
  --title "Waiting for confirmation" \
  --message "Please confirm the database migration"

# Send an error notification
tmux-notify send \
  --level error \
  --title "Test failed" \
  --message "Test suite exited with code 1"

# Open notification center
tmux-notify center

# Show pending notifications
tmux-notify center --filter pending

# Show summary for status bar
tmux-notify status

# Future task monitor
tmux-notify tasks

# Clean old dismissed notifications
tmux-notify cleanup
```

CLI、事件模型和存储接口应独立于 TUI 实现，方便未来替换 UI
或添加新事件来源。

------------------------------------------------------------------------

## 10. 工程目录建议

``` text
tmux-notify/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── Makefile
├── .editorconfig
├── .shellcheckrc
├── bin/
│   └── tmux-notify
├── lib/
│   ├── common.sh
│   ├── events.sh
│   ├── store.sh
│   ├── tmux.sh
│   ├── status.sh
│   └── config.sh
├── ui/
│   ├── center.py
│   ├── popup.py
│   └── tasks.py
├── hooks/
│   ├── install.tmux
│   └── uninstall.tmux
├── tests/
│   ├── unit/
│   ├── integration/
│   └── fixtures/
└── docs/
    ├── architecture.md
    ├── configuration.md
    ├── event-model.md
    └── ui-ux.md
```

目录结构可随实现语言调整；重点是把 CLI、事件处理、存储、tmux 集成和 UI
分层。

------------------------------------------------------------------------

## 11. 测试与验收标准

V1 至少应通过以下验收项：

1.  多个 Pane 同时发送通知时，所有事件都能正确保存。
2.  状态栏刷新不会重复创建事件。
3.  已读通知不会被计入未读数量。
4.  阅读待处理通知后，待处理数量不会自动归零。
5.  `Enter` 能定位到正确的 Session、Window 和 Pane。
6.  来源 Pane 被关闭后，通知中心仍可正常工作。
7.  关闭 Popup 不会关闭任务或删除事件。
8.  tmux 重启后，持久化通知仍可查询。
9.  静音只影响提示方式，不影响事件记录。
10. 关闭通知中心后，原有 tmux 布局不变。
11. 终端尺寸变化时，列表和详情仍可用。
12. 消息中的控制字符不会破坏 TUI。
13. 并发写入、数据库锁定和存储异常有可理解的错误处理。
14. 清理操作不会删除仍待处理的事件。

建议使用 ShellCheck、shfmt、Bats 和独立 tmux 测试实例构建基础质量保障。

------------------------------------------------------------------------

## 12. 关键 UX 原则

### 12.1 不抢占焦点

后台事件不能自动切换 Session、Window 或 Pane。用户主动操作才定位任务。

### 12.2 已读不等于已处理

阅读通知不会自动清除待处理状态。

### 12.3 关闭提示不等于解决问题

Popup 消失或通知被关闭，不代表任务成功。

### 12.4 可信度优先

明确的事件优先于对终端输出的猜测。无法确定的状态应标记为 Unknown。

### 12.5 低噪音

普通信息默认不弹 Popup；重复事件合并；关键事件不能被静默丢弃。

### 12.6 工具无关

Claude Code、Codex、普通 Shell
命令和自定义脚本都应通过统一事件接口接入。

### 12.7 渐进增强

先完成通知发送、存储、列表和 Pane 定位，再增加 Popup、任务监控和 Agent
集成。

------------------------------------------------------------------------

## 13. 推荐的完整用户流程

假设用户在三个 Pane 中运行不同任务：

1.  Pane A 执行前端重构。
2.  Pane B 的 Agent 等待用户确认。
3.  Pane C 执行测试。

Pane B 发送 `action_required` 事件后：

1.  状态栏待处理计数增加。
2.  显示短暂 Popup，但不抢占焦点。
3.  用户稍后按 `Prefix + n` 打开通知中心。
4.  通过 Pending 筛选查看待处理事件。
5.  选中事件并按 `Enter`，定位到来源 Pane。
6.  用户处理完任务后，事件生产者或后续状态事件将任务更新为 Resolved。
7.  通知历史仍可供查询。

这构成完整闭环：

``` text
事件发生
   ↓
通知记录
   ↓
状态栏 / Popup 提醒
   ↓
通知中心查看
   ↓
定位来源 Pane
   ↓
处理任务
   ↓
状态更新
```

------------------------------------------------------------------------

## 14. 最终建议

V1 应优先完成：

**状态栏摘要 + 通知中心 + 一键定位 Pane + 持久化事件存储。**

这是一个范围明确、可以测试、对日常工作流有直接价值的最小产品闭环。

推荐采用 **Shell + SQLite + Python TUI + tmux 原生 Popup** 的分层架构：

-   Shell 负责 CLI 和 tmux 集成。
-   SQLite 负责可靠存储与查询。
-   Python TUI 负责通知中心的交互。
-   tmux 原生能力负责 Popup、状态栏和 Pane 定位。

V1 先解决"通知如何可靠到达用户、如何快速定位任务"，再逐步扩展为多 Agent
任务管理系统。
