# OpenCode 接入：技术开发方案与执行计划

> 日期：2026-11-12
> 状态：**Phase 0～4 已实现**（`make check` 449 项全绿）。R3 的运行时验证仍未做 ——
> 需要真实 OpenCode 会话确认插件加载进 TUI 进程（见 §5.2）。
> 版本：rev 4 —— 实现完成后同步实际代码结构（Phase 0 的默认值、`lib/opencode.sh` 拆分、
> install 目录软链、doctor 检查项）。rev 3 修正插件加载形态（**目录软链，非单文件**）；
> rev 2 按对抗性 review 修正 S1～S5、M1～M6 及措辞问题（见 §10 修订记录）。
> 目标：让 tmux-whistle 支持 OpenCode 作为第二个一等接入源，与 Claude Code 并列。
> 实测环境：OpenCode v2.2.7（`opencode serve --service` + TUI 双进程），tmux 3.8，macOS。
> 安装方式：软链（与现有 CLI 软链同一套路），不改用户 `opencode.json`。

## 0. 目标与边界

### 0.1 目标

在不改动现有状态机的前提下，把 OpenCode 的生命周期事件翻译成 whistle 的两条正交通道：

```text
OpenCode 事件
  → hooks/opencode/tui.js（TUI 进程内，持有可信的 TMUX_PANE；只做转发与过滤）
  → hooks/opencode.sh（POSIX sh 薄壳：读 stdin、定位 tmux、调映射、写状态）
  → lib/opencode.sh（纯函数：事件 → 通道 + 状态；不碰 tmux，可被 L1 单测 source）
  → bin/tmux-whistle --activity / --notice -t %N
  → lib/core.sh 唯一写入点（不改）
  → 状态栏徽章 / 汇总计数 / 边框 / 瞬时提示 / 桌面通知（不改）
```

同时做到：

- 与 Claude Code 并存，互不干扰，两个 agent 在同一 tmux server 里各自正确。
- 复用现有全部不变量：双通道正交、汇总数 pane、`gone` 收尾。
- `make check` 仍然零 node 依赖；映射逻辑留在 shell，可用 bats 直接测。
- 首版功能齐到 Phase 3：活动通道 + 通知通道 + 后台 shell + 子 agent。

### 0.2 非目标

第一版不做：

- 改动 `lib/core.sh` 的状态模型或新增 option。
- 支持 `opencode run`（无 TUI）或远程 server 的 pane 归属 —— 没有 TUI 就没有 pane。
- 接管 OpenCode 自带的 `context.attention.notify` 系统通知。
- 为 OpenCode 单独做一套菜单或 UI。
- 让 `hooks/opencode/tui.js` 承载业务逻辑（它只做转发与身份过滤）。
- 在 `opencode.json` 里写 `plugins` 数组（安装走软链，见 §6）。
- 映射 `pty.*` 事件（那是 OpenCode 自己的终端面板，不是 agent 的后台命令，见 §2.3）。

### 0.3 必须保持的不变量

1. 活动通道 `@whistle` 与通知通道 `@whistle_notice` 正交；子 agent 只写通知。
2. 状态写入仍只有 core 一条链；适配器不直接调 tmux set。
3. `running` 只能由「真的开始干活」点亮，TUI 启动报 `idle`。
4. `gone` 只由 TUI 退出写，且必须同步写（不能留给异步）。
5. `lib/opencode.sh` 的全部函数不得出现 tmux 调用（L1 单测要脱离 tmux 跑）。
6. 自动化测试只用隔离 socket，不读不写用户真实配置。

> 消毒不必由适配器负责：`whistle_notice_set` / `whistle_activity_set` 内部已调
> `whistle_sanitize`（`lib/core.sh:748-749`）。适配器**不要**再消毒一遍 —— 重复消毒
> 只会白白截断两次，且掩盖真源在哪。

---

## 1. 关键结论：不能照抄 Claude Code 的接入架构

现有整条链路建立在**一个隐含假设**上：hook 进程是 pane 进程树的孩子，因此能继承
`TMUX_PANE`。`hooks/claude-code.sh:334` 就是拿它定位 pane 的。

OpenCode v2 不成立。本机实测进程树：

```text
37155     1  opencode serve --service        ← 共享后台守护，PPID=1
54957 68171  opencode .                      ← TUI，PPID=zsh，TMUX_PANE=%14
```

- **TUI 进程**在 pane 里，`$TMUX` / `$TMUX_PANE` 正确可信。
- **service 进程**是 PPID=1 的共享守护，环境是**启动那一刻的快照** —— 它当前也带着
  `TMUX_PANE=%14`，但那只是第一个拉起它的那个 pane。所有 pane、所有 session 的事件
  都汇进这一个服务。
- 扫描全部 99 个 V2 事件 schema（`opencode.ai/docs/openapi.json` 的 `V2Event.anyOf`）：
  **没有任何一个事件带 pane、TTY 或 client 标识**，只有 `sessionID` 与 `location.directory`。

因此在 server 侧写状态只能靠 `location.directory` 猜 pane。本机实测这个猜法必然出错：

```text
%8  claude.exe  /Users/rich1e/workspace/code/tmux-whistle  idle
%14 opencode    /Users/rich1e/workspace/code/tmux-whistle
```

同一个目录里两个 agent 并存。这与 `docs/todo.md` 的 TODO-29（server 环境是启动快照）
是同一类坑，只是换了一层。

> **结论：pane 归属必须由 TUI 进程提供，不能由 server 提供。** 这是整个设计的分水岭，
> 也决定了插件必须同时有 TUI 部分（拿 pane）与 shell 部分（做映射）。

补充：事件本身有 `location.directory`，看起来像能定位，但它是 **location 而非 pane** ——
同一个目录下的多个 pane 无法区分。它只能做「找不到 pane 时的诊断线索」，不能做归属依据。

### 1.1 共享 server 的第二个后果：多个 TUI 会重复收到同一批事件

官方文档写得很明确：*"The TUI loads the TUI parts of the plugins **its server** loads."*

server 是共享的（§1 已证），事件里又只有 `sessionID` 没有 client 标识 —— 于是：

> **开两个 OpenCode TUI（两个 pane）时，两个 TUI 都订阅同一条事件流，都会收到
> 全部 session 的事件，并各自往自己的 pane 写一遍。**

后果：在 pane A 里跑任务，pane B 也亮 `▶`；结束时两个 pane 都亮 `◆`，
`@whistle_count_done` 变成 2、菜单列两条 —— 一件事被算成两件。

这与 §3.5「一个 pane 多个 session」是**相反方向**的问题，两者都要处理，不能只处理后者。

**缓解（必须实现）**：TUI 侧只处理「本 TUI 当前有 tab 的 session」：

```js
// context.ui.tabs.list() → 本 TUI 打开的 session 列表（同步读本地缓存，不联网）
const mine = new Set(context.ui.tabs.list())
if (!mine.has(event.data.sessionID)) return
```

**残留（写进 README，作为已知限制）**：同一个 session 在两个 TUI 里都开着时，
仍会双写。事件层没有任何字段能判断「哪个 TUI 才是它的主人」，除非引入认领机制
（不在本版范围）。因此这条只能文档化，不能假装解决。

`tabs.list()` 在「session tab 功能关闭」时返回什么，未知 → 见 R11。

---

## 2. OpenCode 事件 → whistle 状态

字段均从 `openapi.json` 核对。`durable` 字段有信息量：**带 `durable` = 回合级持久记录，
不带 = 瞬时 UI 信号**（`session.idle` / `permission.*` / `pty.*` 都没有）。

### 2.1 映射表

| OpenCode 事件 | 载荷（实测 schema） | whistle | 说明 |
|---|---|---|---|
| `session.execution.started` | `sessionID` | 活动 `running` | 对应 `UserPromptSubmit`，**唯一**该点亮 running 的入口 |
| `session.tool.called` | `sessionID, id, input, executed` | 活动 `running` | 对应 `PreToolUse`，覆盖 plan 批准后继续跑 |
| `session.execution.succeeded` | `sessionID` | 活动 `idle` + 通知 `done` | 对应 `Stop` |
| `session.execution.failed` | `sessionID, error{type,message,status}` | 活动 `idle` + 通知 `error` | 对应 `StopFailure`；`error.message` 取首行进徽章，全文进 `--body` |
| `session.execution.interrupted` | `sessionID, reason` | **按 reason 分派**，见 §2.2 | 不能一律 `idle` |
| `permission.asked` | `sessionID, action, resources[], source, message?` | 通知 `wait` | 对应 `permission_prompt`，**即时，无 60 秒延迟** |
| `permission.replied` | `sessionID, requestID, reply` | **按 reply 分派**，见 §2.4 | `once/always` 继续跑；`reject` 结束当前 step |
| `form.created` | `form{id, sessionID, title, fields[]}` | 通知 `wait` | **第二种「等你回答」**，见 §2.9。question 工具 / MCP elicitation / provider 选择 |
| `form.replied` | `id, sessionID, answer` | 已读（清通知） | 答完继续跑，活动态不动 |
| `form.cancelled` | `id, sessionID` | 已读（清通知） | **不写 `idle`**：取消只是把 tool error 还给模型，同一轮通常还在跑 |
| `session.shell.started` | `sessionID, shell{id,status,command,pid}` | 后台在飞标记（起） | 只认 `shell.status=running` |
| `session.shell.ended` | `sessionID, shell{...}, output` | 后台在飞标记（止） | 见 §2.5，注意四态 |
| `session.retry.scheduled` | `sessionID, error, attempt, at` | **不映射**（见 §2.6） | 只是「要重试了」，不是终态 |
| `session.idle` | `sessionID`（无 `durable`） | **不映射**（见 §2.6） | 瞬时 UI 信号，不承载语义 |
| `pty.created/updated/exited/deleted` | `info{id,title,command,cwd,status,pid}` | **不映射** | OpenCode 自己的终端面板，不是 agent 后台命令 |

### 2.2 `session.execution.interrupted` 必须按 reason 分派

`reason` 枚举 `{user, shutdown, superseded, inactivity}`，语义差别很大，**一律映 `idle`
是错的**：

| reason | 映射 | 理由 |
|---|---|---|
| `user` | 活动 `idle` | 用户按 Esc 中断了这一轮，TUI 还在，agent 回到提示符前等着 |
| `inactivity` | 活动 `idle` | 超时中断，语义同上 |
| `shutdown` | 活动 `gone` | 正在关闭。写 `idle` 会留一盏 `◉` 等 cleanup 覆盖；若 cleanup 没跑（R7）就是永久残留 |
| `superseded` | **不动活动通道** | 被新一轮取代 = **现在正在跑新的一轮**。写 `idle` 会把 `▶` 打成 `◉`，而下一个事件可能很久才来 |
| 其它 / 未知 | 活动 `idle` | 兜底取最保守的「不亮 ▶」，宁可少报不可误报 |

`superseded` 那条是最容易踩的：它和「一轮结束」长得几乎一样，但语义正好相反。

### 2.3 为什么 `pty.*` 不映射

`pty.*` 是 OpenCode 的终端面板（`Pty.status ∈ {running, exited}`，带 `title` / `command`），
属于「用户在 OpenCode 里开了个终端」，不是 agent 的后台命令。把它算成「后台在飞」
会让 `▶` 在用户开一个终端面板时长期亮着 —— 与 Claude 侧刻意排除 `monitor` / `MCP task`
是同一个理由。

### 2.4 `permission.replied` 必须按 reply 分派

官方文档：*"A plain rejection ends the current step."* 也就是说 `reject` 之后**可能没有**
`successed` / `failed` 事件跟进 —— 只清通知不清活动态的话，`▶` 会一直挂着。

| reply | 映射 |
|---|---|
| `once` / `always` | 清该 pane 的通知（已读）；活动态**不动**（执行继续，仍是 `running`） |
| `reject` | 清通知；活动态写 `idle`（当前 step 已结束，不会有后续终态事件来收尾） |

### 2.5 `session.shell.*` 只认 `status=running`

`Shell.Info.status` 有 `running / exited / timeout / killed` 四态，只有 **`running`** 算「在飞」。
`ended` 事件里也会带 `shell.status`，实现时**只看 status 字段，不要因为「收到了 ended
就认为结束」** —— 一条 `ended` 里的 `timeout` 与 `killed` 同样是结束，而重复的 started
（重试）不该把计数加两次。

实现上不要维护计数器，而是维护「本 pane 在飞的 shell id 集合」，`ended` 时按 id 移除。
集合为空才算「没有后台在飞」。这样重复事件天然幂等。

### 2.6 两个刻意不映射的事件

**`session.retry.scheduled`（带 `durable`）** —— 载荷是 `{sessionID, error, attempt, at}`，
语义是「这一轮失败了、将在 at 时刻重试」。它**不是终态**：

- 若映 `error`，用户会在每次自动重试时收到一条 `⚠`，而多数重试会自动成功 —— 噪音。
- 若映 `running`，它本来就是 running，没有信息增量。

真正的终态由随后的 `execution.succeeded` / `execution.failed` 给出（重试耗尽才算 failed）。
因此**不映射**，但记入 `@whistle_debug` 日志，方便排查「为什么这一轮特别慢」。

> 反向确认：`session.step.*` 与 `session.execution.*` **同时存在**，说明 `execution` 是
> **回合级**、`step` 是**步级**。所以 `execution.succeeded` 天然就是「这一轮做完了」，
> 不会在工具循环中间触发。R1 的风险因此比 rev 1 判断的低。

**`session.idle`（无 `durable`）** —— 瞬时 UI 信号，语义上与 `execution.succeeded` 重叠
但**不承载持久语义**（没有 `durable` 块）。rev 1 写的「疑似 `execution.succeeded` 的重复」
措辞不准：它不是重复，而是**同一件事的瞬时通知**。跳过的理由是「持久语义已由
`execution.succeeded` 覆盖」，不是「怕重复」。

### 2.7 必须保留的 Claude 侧判断（不要简化掉）

| Claude 侧规则 | 在 OpenCode 上的对应 | 为什么仍要守 |
|---|---|---|
| 子 agent 事件只写通知，不碰活动 | 子 session（`parentID` 非空）的 `execution.*` 不清主 session 活动态 | 否则主 agent 正在跑时被子 agent 报成 idle，零报错 |
| 已读只清通知通道 | `permission.replied` 只清 `@whistle_notice*` | 抹掉活动态后没有任何事件能点回来 |
| `running` 不把派生结果烤进真源 | 后台在飞状态由标记 + 推导层合成 | 否则标记清掉后留一盏永不灭的 `▶` |
| `SessionStart` 报 idle 不是 running | TUI 启动 = `idle` | 恢复会话不等于在干活 |
| 有后台在飞时 `Stop` 不写 done | 有在飞 shell 时**不写 `done`** | `done 3 > running 2`，报 done 会盖掉 running（TODO-18 的现场） |
| 子 agent 结束只清标记，不写活动态 | 子 session 结束 → 只清标记 | 主 agent 通常还在等结果，写 idle 会把正在干活标成空闲 |
| 多行消息取首行进徽章 | `error.message` / 权限提示先 `head -n 1`，全文进 `--body` | 徽章只有一行宽度；多行会把格子撑坏 |

### 2.8 比 Claude Code 更整齐的两点

**① 不需要 `idle_prompt` 那套 60 秒 hack。**

Claude 侧「agent 在正文里问了一句」不产生任何工具事件，只能靠回合结束 60 秒后的
`Notification{idle_prompt}` 补，而且它每回合都发，必须加两道守卫（见 `CLAUDE.md`）。
OpenCode 的 `permission.asked` 是 `wait` 的一等公民、**且即时**，`permission.replied`
又给了明确的清除时机。整条链路因此更短、更少守卫。

**② 后台任务有对称的起止事件。**

Claude 侧只有 `Stop` 输入里的 `background_tasks` 快照，**没有「后台任务结束」事件**，
只能等下一次被叫醒的 `Stop`（`CLAUDE.md` 记为已知限制）。OpenCode 的
`session.shell.started` / `session.shell.ended` 成对出现，`@whistle_sub` 的 TTL
可以退化成防漏事件的兜底，而不是主路径。

### 2.9 「等你回答」有两条通路，只接 `permission.*` 会漏

| 通路 | 事件 | 场景 |
|---|---|---|
| 权限确认 | `permission.asked` / `permission.replied` | 跑命令、改文件、跨目录访问 |
| 交互式表单 | `form.created` / `form.replied` / `form.cancelled` | `question` 工具（AskUserQuestion）、MCP elicitation、websearch provider 选择 |

2026-11-17 的现场：用户跑 `opencode --auto`（权限自动通过，`permission.asked` 根本不产生），
question 工具弹出来等答案时状态栏一直是 `▶` —— 因为 `form.created` 既没订阅、也没映射，
被 `*` 分支静默吃掉；活动通道的 `running` 是这一轮开头就点亮的。

三条容易踩的细节：

- 事件名**没有** `session.` 前缀。`session.form.*` 是 REST 接口名（`session.form.list` /
  `.reply` / `.cancel`），不是事件流里的 type。
- `form.created` 的 `sessionID` 嵌在 `payload.form.sessionID`，**顶层没有**。`tui.js`
  的「无 sessionID 就丢」guard 会把它整条丢掉。
- `sessionID === "global"` 的全局表单不属于任何 pane，不能按 cwd 猜 —— 直接忽略。

回答 / 取消只清通知通道，**绝不写活动态**：取消 question 只是把一个 tool error 还给模型，
同一轮通常还在跑；写 `idle` 会留一盏错的 `◉`，而下一个 `execution.started` 要等下一轮。

另外 `--tui-exit` 要顺手清掉挂着的 `wait`：表单随 TUI 一起消失，已经无从回答，而
`gone`(rank 0) 赢不过 `wait`(rank 4)，不清就是永久残留（`done` / `error` 是历史提醒，保留）。

---

## 3. 组件设计

### 3.1 文件布局

```
lib/
  opencode.sh                 # 新增：纯函数（事件 → 通道 + 状态），不碰 tmux
hooks/
  claude-code.sh              # 既有，不动
  opencode.sh                 # 新增：薄壳（stdin → 定位 tmux → 调 lib/opencode.sh）
  opencode/                   # 新增：**插件目录**，整体软链进 plugins/
    tui.js                    #   TUI part —— 文件名必须是 tui.js（见 §3.1.1）
```

> ⚠️ **`hooks/opencode/` 是「插件目录」，不是随便放文件的目录。** OpenCode 按
> **目录内的固定文件名**识别各 part（`server` 或 `index` = server part，`tui` = TUI part）。
> 所以 `tui.js` 这个名字**不能改** —— 改了就不再被认成 TUI part，而会被当成默认
> （server）part 加载进错误的进程。这条约束由 §3.1.1 与 §6.1 共同保证，测试与 review
> 都要守。

#### 3.1.1 为什么是「目录 + tui.js」，而不是单文件

官方 `docs/plugins` 对两种形态的规定不同，这直接决定安装方式：

| 形态 | 官方原文 | 结果 |
|---|---|---|
| `plugins/` 下的**直接 `.js` 文件** | "loads direct `.ts` and `.js` files and immediate plugin package directories" | 被当作**默认 part（server）**，加载进 server 进程 |
| `plugins/` 下的**目录** | 同上（"immediate plugin package directories"） | 按目录内文件名识别 part，`tui.js` → **TUI part** |
| `plugins` 配置里指向**单个文件** | "Configured local paths **must be directories**. A path to a single file is **skipped**." | ❌ **被直接跳过，静默不加载** |

结论：**只有「目录形态」能把 part 正确投递到 TUI 进程**。单文件软链会被当成 server part，
而 server 的 `TMUX_PANE` 是启动快照（§1）—— 正是整份方案要避开的东西。

目录内若**同时**有 `index.js`/`server.js`，插件就成为「server + TUI 双 part」，会加载进
两个进程。本方案首版**不要**放 server part：双 part 会让 server 侧也订阅事件，
`TMUX_PANE` 不可信的问题立刻复现。只有在 §5 提到的那条「proxy 兜底」路径下才引入
server part，且它必须明确**不写 tmux**。

**关于「纯 TUI 插件要放 `cli.json`」的说法**：build/plugins 里另有一句 *"A package with
only a TUI part goes in `cli.json` instead."*，与「`plugins/` 目录会自动发现」存在张力。
这是 R3 剩下的唯一未知点，验证方法见 §5.2。

**为什么映射拆成 `lib/` 与 `hooks/` 两个文件**：rev 1 把映射全放进 `hooks/opencode.sh`，
却要求 L1 单测覆盖它 —— 做不到，因为该文件照 `claude-code.sh` 同构会有
`_hk_input=$(cat)`（source 时阻塞读 stdin）与结尾 `exit 0`（source 会退出测试进程）。

拆分规则：

- **`lib/opencode.sh` = 纯函数**。输入是 JSON 字符串与事件名，输出是「哪个通道、哪个状态、
  什么消息」。零 tmux 调用，可被 `source`，对应 `test/unit/opencode.bats`。
- **`hooks/opencode.sh` = 薄壳**。读 stdin、定位 tmux、取 option、调 CLI。
  不可 source，只由 `test/e2e/opencode_hook.bats` 以子进程方式测。

这与仓库既有分工一致：`lib/core.sh` 的四个纯函数能被 L1 测（`test/unit/core.bats:13`
直接 `source`），`hooks/claude-code.sh` 只由 L3 测。

**关于「hook 不 source 状态机」那条老约定**：`claude-code.sh` 顶部写明不 source
`lib/core.sh`，理由是「状态机改坏了会让 hook 整个不跑」。`lib/opencode.sh` 不违反它 ——
它是 50 行左右的纯查表函数，不含任何 tmux 调用与状态机逻辑，blast radius 远小于
source `core.sh`。这条差别要在文件头注释里写明，否则后人会以老约定为由拒绝拆分。

`hooks/opencode/tui.js`（TUI-only 插件，约 60–80 行）职责三件：订阅、过滤、spawn。
业务逻辑一概不在 JS 里。

```js
// 只做转发与身份过滤。状态判断全在 lib/opencode.sh ——
// JS 里少写一行，就少一处受 @opencode-ai/plugin 版本漂移影响（见 R6）。
const EVENTS = [
  "session.execution.started", "session.execution.succeeded",
  "session.execution.failed", "session.execution.interrupted",
  "session.tool.called", "permission.asked", "permission.replied",
  "form.created", "form.replied", "form.cancelled",   // 第二种「等你回答」见 §2.9
  "session.shell.started", "session.shell.ended",
  "session.retry.scheduled",   // 只写 debug 日志，不写状态
]
```

要点：

- `setup(context)` 里用 `context.data.on(type, handler)` 订阅，返回的 unsubscribe 在
  cleanup 里调；cleanup 里再跑一次退出收尾（见 §3.5）。
- **身份过滤**（§1.1）：`context.ui.tabs.list()` 里没有的 `sessionID` 直接 return。
- 事件载荷原样 `JSON.stringify` 后经 stdin 传给 shell。
- **显式把 `TMUX_PANE` / `TMUX` 放进 `spawn` 的 `env`**，不依赖继承 —— server 进程的
  环境是快照，依赖继承是错的。
- 非 tmux 启动（`TMUX_PANE` 为空）时整个插件退化为 no-op。
- 失败一律静默：插件绝不能因为 whistle 出问题而影响 OpenCode 本身。

### 3.2 插件如何定位仓库：用 `import.meta.url`，不要用 cwd 或 `$0`

`install.sh` 把 `$ROOT/hooks/opencode`（整个**目录**）**软链**到
`~/.config/opencode/plugins/tmux-whistle`。于是插件里所有「按自身路径推仓库根」的
写法都会失效或指错：

| 写法 | 结果 | 结论 |
|---|---|---|
| `process.cwd()` | 用户**项目**目录，不是仓库 | ❌ 绝对不能用 |
| `process.argv[1]` / `__dirname` | 是**软链路径**，`..` 会指到 `~/.config/opencode/` | ❌ |
| `import.meta.url` + Node 的默认解析 | Node 默认按**真实路径**解析模块，得到仓库内路径 | ✅ |

ESM 下 `import.meta.url` 指向的是模块被解析后的真实位置（软链已被解析），
所以 `fileURLToPath(import.meta.url)` 再 `../../..` 就回到仓库根。
但**不要依赖这个默认行为**：显式 `realpath()` 一次（`node:fs` 的 `realpathSync`），
万一将来 `--preserve-symlinks` 类行为变化也不会静默指错。

拿到仓库根后，`WHISTLE_CLI = <root>/bin/tmux-whistle`、`HOOK_SH = <root>/hooks/opencode.sh`。

补充：CLI 本身**不能再依赖** `bin/tmux-whistle` 的软链自解析去反推仓库（那是给
`~/.local/bin` 那条链接用的，已有循环 readlink 逻辑，不用改）。插件侧只需传绝对路径。

### 3.3 为什么映射放 shell 而不是 JS

| 理由 | 说明 |
|---|---|
| 零运行时依赖 | 仓库现在 `make check` 不需要 node。逻辑进 JS 就等于引入 npm 依赖链。 |
| 测试打法可复用 | `test/e2e/claude_hook.bats` 的「喂构造 JSON、断言 option 值」原样适用。 |
| 版本漂移可控 | 本机 `~/.config/opencode/package.json` 锁的是 `@opencode-ai/plugin 1.18.11`（V1），而二进制是 **2.2.7**（V2 API）。JS 里少写一行，就少一处受影响。 |
| 排查手段一致 | `@whistle_debug` 的事件日志是上次「在跑却显示空闲」的破案关键，两边应该长得一样。 |

### 3.4 pane 归属

TUI 侧拿 `process.env.TMUX_PANE`，非 tmux 启动时为空 → 静默 no-op。
`bin/tmux-whistle` 的 `cmd_activity` / `cmd_notice` 已经会把最后一个位置参数是 `%N`
的情况当作目标 pane（`_cs_pane_hint`，`bin/tmux-whistle:647-665`），所以
**CLI 一行都不用改**。

### 3.5 退出收尾必须写 `gone`

TUI cleanup 执行时进程还没退，`pane_current_command` 仍是 `opencode`。此时若清空活动态，
紧接着的重算会按「前台跑着 agent」重新认成 `◉ idle`，留下一盏灭不掉的空闲标记 ——
这正是 `whistle_forget_agent` 用 `gone` 绕开的那个竞态（`lib/core.sh:951-958`）。

调用链**只有一条**（rev 1 在这里写了两个名字，读起来像矛盾）：

```
tui.js cleanup
  → spawn  <root>/hooks/opencode.sh --tui-exit
  → 该分支内部执行  bin/tmux-whistle --clear-pane %N
```

`--tui-exit` 是**适配器**的参数（表示「这不是事件，是 TUI 要退了」），
`--clear-pane` 是 **CLI 的已有子命令**（gone + 清子 agent 标记 + 重算，一次调用干完）。
两者不是二选一。

### 3.6 一个 pane 里多个 session

whistle 的状态单元就是 **pane**，一个 TUI 实例 = 一个 pane。TUI 里开多个 tab/session
时，它们的事件都落在同一个格子，只能显示 rank 最高的那个。

这是**刻意的妥协**，与「汇总数 pane」的不变量一致，不是缺陷：`@whistle_count_*` 按
`list-panes -a` 计数，菜单也一个 pane 一条，两处粒度必须相同。

README 要同时写明两个方向的限制：

- 一个 pane 多个 session → 只显示最高 rank（不会显示 `▶3`）。
- 一个 session 多个 pane（§1.1）→ 每个 pane 各显示一份，计数会翻倍。

---

## 4. 执行计划

首版含 Phase 0～3，Phase 4 是安装与自检。每期都能独立验收、独立回滚。

### Phase 0 — 每个文件一行，立刻有收益（不依赖任何插件）

把 `opencode` 加进 `@whistle_agent_cmds` 默认值（**三个文件各改一行**）：

- `lib/core.sh:234`
- `bin/tmux-whistle:111`
- `README.md` 配置表

`pane_current_command` 实测就是 `opencode`（见 §1 的 `%14`），所以「按进程发现空闲」
立刻生效：恢复 tmux 后 opencode pane 会显示 `◉`，零配置、零风险。

**先做这一步**，因为它同时验证了 Phase 3「按进程发现」的前提。

### Phase 1 — 活动通道

`lib/opencode.sh` 的纯映射 + `hooks/opencode.sh` 薄壳 + `tui.js`，只处理
`execution.started` / `tool.called` / `succeeded` / `failed` / `interrupted`（含 §2.2 的
reason 分派），只点亮 `▶` / `◉` / `gone`，不碰通知通道。

**验收**：一轮任务下来，状态栏 `▶` 在跑、结束回落 `◉`；TUI 退出后不留 `▶` / `◉`；
`reason=superseded` 时不把 `▶` 打成 `◉`。

### Phase 2 — 通知通道

加 `succeeded → done`、`failed → error`、`permission.asked → wait`、
`permission.replied → 已读`（含 §2.4 的 `reject` 分支）。这一步才是「跨 session 提醒」
的核心价值。

**验收**：在 `%14` 跑任务，`%7` 的状态栏亮 `◆`；切过去后 `◆` 消失但 `▶`/`◉` 保留；
拒绝一次权限请求后 `▶` 回落 `◉`。

> ⚠️ 这条验收在 Phase 3 落地后会**按设计**变红：Phase 3 规定「有在飞 shell 时不写 done」。
> Phase 3 必须同步把它改写成「**无**后台任务在飞时亮 `◆`」。这是有意变更，不是回归。

### Phase 3 — 后台 shell 与子 agent

- `session.shell.started/ended` 维护**在飞 shell id 集合**（§2.5），`ended` 按 id 移除；
  集合非空时**不写 `done`**。
- 子 session（`parentID` 非空）的事件只写通知通道；活动态靠 `@whistle_sub` 的
  过期时间戳 + 推导层合成，不把 `running` 烤进 `@whistle`。
- 子 session 判定用 `context.data.session.get(id).parentID`（或 `root(id)`），
  是本地缓存同步读，不发请求 —— 判定在 **JS 侧**做，结果作为布尔字段传下来
  （shell 侧不该为了这个再打一次 API）。
- 复用 `@whistle_sub_ttl` 的 TTL 安全阀：宁可漏报 `running`，不可永久误报。

**验收**：

- 后台任务在飞时 `▶` 且**无** `◆`；后台结束后那一轮 `Stop` 才写 `done`。
- `timeout` / `killed` 结束的后台命令同样会解除「在飞」（§2.5）。
- 子 agent 结束时主 agent 仍显示 `▶`。
- 手工 kill 掉后台进程且没有后续事件时，`▶` 会在 TTL 后回落（不是永久亮）。
- 同一条 `started` 重复到达两次，计数不会变成 2（幂等）。

### Phase 4 — 安装与自检

- `install.sh` 软链**插件目录**（§6.1），`--no-hooks` 时跳过。
- **`--uninstall` 要一并删那条链接** —— 现有卸载只处理 `BIN_DIR/tmux-whistle` 与
  `PLUGIN_DIR` 两条（`install.sh:145-146`），新增的第三条链接必须加进去，否则卸载后
  插件仍被加载、仍往 tmux 写状态。
- `doctor` 增加「OpenCode 插件」一节（§6.4）。
- README 增加「场景三：OpenCode」，含两条已知限制（§3.6、§1.1）。

Phase 4 依赖 R3（加载路径与目标进程）先验通；**验通后只保留一条安装路径**，
不要三套并存。

---

## 5. 风险与待实测

| # | 风险 | 为什么要紧 | 怎么验 |
|---|---|---|---|
| **R3** | TUI-only **目录**插件（`tui.js`、无 server part）放 `~/.config/opencode/plugins/` 下，其 TUI part 是否真的加载进 **TUI 进程** | 整份方案的地基。加载失败**完全不报错**；加载进 server 进程则 `TMUX_PANE` 不可信（§1） | **部分已验证**：`opencode plugin list` 已识别目录形态，server 未把其当 server part（§5.2 实测记录）。**仍待补**：真实 TUI 里 setup 是否执行 —— 用内建 `--probe` + doctor 一条命令即可确认 |
| **R10** | `interrupted.reason` 四种取值的真实语义 | §2.2 的分派表是基于枚举名推断的，`superseded` 是否真如表所述「之后立刻有新执行」需实测 | 触发一次 superseded（连发两条 prompt）看事件序列 |
| **R11** | `context.ui.tabs.list()` 在「tab 功能关闭 / 单 session 模式」下返回什么 | §1.1 的身份过滤建立在它之上；返回空数组会导致**全部事件被过滤掉**（静默无状态） | 关闭 tabs 后观察过滤结果，必要时改为 fail-open + 日志告警 |
| R1 | `execution.succeeded` 是每回合还是每 step | **风险已下调**：`step.*` 与 `execution.*` 并存，说明前者步级、后者回合级 | 仍建议探针确认，但不再是阻塞项 |
| R2 | `session.idle` 与 `execution.succeeded` 的关系 | 已定性为「瞬时信号 vs 持久语义」（§2.6），映射上无歧义 | 探针顺带看一眼即可 |
| R4 | TUI 插件能否稳定读到 `TMUX_PANE`；非 tmux 启动时如何 | 整个 pane 归属的地基 | 在 `%14` 与本机 GUI 各跑一次 |
| R5 | 子 agent 事件是否带子 `sessionID` 冒到 TUI | 决定 Phase 3 的 `parentID` 判定是否可用 | 派一个 subagent 观察事件 |
| R6 | `@opencode-ai/plugin` 1.18.11 与二进制 2.2.7 的 API 漂移 | V2 只认 `Plugin.define({id,setup})`；本机 `petdex.js` 是 V1 写法，**不能作为「能用」的证据**（见 §6.2） | 用最小 `setup()` 打日志确认被调用 |
| R7 | TUI cleanup 在正常退出 / Ctrl-C / kill 下是否都跑 | 不跑就留一盏灭不掉的 `▶` | 三种退出手动各验一次 |
| R8 | 一个 TUI 里多个 tab/session 并发 | 同属一个 pane，状态互相覆盖 | 开两个 session 同时跑，确认只剩 rank 最高那个（§3.6） |
| R9 | `session.shell.ended` 是否覆盖所有结束路径 | `status` 四态中只有 `running` 算在飞（§2.5） | 跑一个超时命令与一个被 kill 的命令 |
| R12 | 同一 session 在两个 TUI 里都打开 | §1.1 的残留双写，无字段可判定归属 | 两个 TUI 同时打开同一 session，确认计数翻倍并记录为已知限制 |
| R13 | 软链目录后，改 `tui.js` 是否需要 `/reload` 或 `service restart` | 决定开发体验（能否「改完即生效」）。官方说 watched 目录自动 reload，但**软链目标在仓库内**，未必被 watch | 改一行 `tui.js`，看是否自动生效；不生效则文档写明要 `/reload` |

**唯一的真阻塞项是 R3**：插件不加载或加载错进程，后面全是空谈。
R10 / R11 建议探针时一并看清，但不阻塞开工（分派表已按最保守取值兜底）。

### 5.2 R3 的验证方法（一次运行区分三种结果）

> **实现已内建这条验证**：`tui.js` 在 setup 时会 spawn `hooks/opencode.sh --probe`，
> 该分支在 `@whistle_debug=on` 时往 hook 日志写一行
> `agent=opencode event=tui-probe TMUX_PANE=%N loaded=ok`。
> `tmux-whistle doctor` 直接读这一行来判断「插件跑没跑」——
> 没加载则一行都没有；加载进 server 则 `TMUX_PANE` 是启动快照那个错的。
>
> 所以实测只需三步：`set -g @whistle_debug on` → 重启 OpenCode → `tmux-whistle doctor`。

关键是要能**区分「没加载」/「加载进 server」/「加载进 TUI」**，而不是只知道「有没有反应」。
下面是手工排查法（doctor 报黄时用它定位）：

**步骤 1：放目录，不放文件**

```sh
mkdir -p ~/.config/opencode/plugins
ln -sfn "$PWD/hooks/opencode" ~/.config/opencode/plugins/tmux-whistle
# 确认形态：应该是目录软链，ls -ld 的输出以 d/l 开头、且 -> 指向仓库
ls -ld ~/.config/opencode/plugins/tmux-whistle
# 插件确实被识别（这是官方 CLI，最权威）
opencode plugin list | grep tmux-whistle
```

**步骤 2：开 debug 让探针落盘**

```sh
tmux set -g @whistle_debug on
# 重启 OpenCode（TUI 侧插件只在启动时 setup）
```

**步骤 3：读探针日志**

```sh
grep 'event=tui-probe' "${TMPDIR:-/tmp}/tmux-whistle-hooks.log"
```

**判定表**（三种结果互斥，一次就能定）：

| 观察到的现象 | 含义 | 下一步 |
|---|---|---|
| 有 `event=tui-probe` 且 `TMUX_PANE=%N` 是当前 pane | ✅ TUI part 加载成功 | 走方案 A，已定稿 |
| 没有这行，但 `opencode plugin list` 里有 | ❌ 加载了但没进 TUI（或 setup 没跑） | 检查链接名是否误带 `.js`、目标是目录还是文件 |
| `opencode plugin list` 里都没有 | ❌ 完全没被发现 | 检查 plugins 目录位置；试方案 B（`cli.json` 登记目录） |

实测记录（2026-11-12，v2.2.7）：

- `opencode plugin list` 列出了 `local .../plugins/tmux-whistle` —— **目录形态被识别**。
- server 日志只对 `petdex.js`（单文件）尝试加载并失败，**没有把 `tmux-whistle` 当 server part** ——
  印证了「目录 + `tui.js` → TUI part」这条判断。
- 该单文件的失败原因正是 R6 预测的：*"Plugin must export a default definition with an id
  and an effect or setup function"* —— V1 的 `async ({client}) => ({...})` 形状在新版不认。

补充两条：

- **日志里必须能看到 TUI 与 server 是两个不同 pid** 才说明拓扑正常。若只见到一个，
  可能是 standalone 模式，那样的结论不可移植。
- 探针日志默认不产生文件（`@whistle_debug=off` 时直接 return）—— 这是刻意的，
  不能让自检机制本身变成噪音源。

### 5.3 三段证据：加载 / 订阅 / 事件

排查「opencode 在跑但状态栏一直 `◉`」时，**只看第一段会得出相反结论**。
`tui-probe` 是在订阅循环**之前**写的，所以「加载成功」不代表「能收到事件」。

| 顺序 | 证据 | 证明什么 | 不满足说明 |
|---|---|---|---|
| ① | `event=tui-probe ... loaded=ok` | 插件加载进了 TUI 进程，`TMUX_PANE` 可信 | 加载问题（形态 / 路径 / 进程） |
| ② | 同一行带上 `subs=N` | **N 条 `data.on()` 订阅建立成功** | 订阅循环被打断 —— 一条抛异常会断掉后面全部 |
| ③ | `event=js-trace` 的 `accept` / `drop` 行 | 事件真的到了 TUI，以及为什么被丢 | 事件没到，或被身份过滤丢掉 |

对应的两个真实故障（2026-11-13）：

- ② 缺失 → 订阅没有逐条 `try/catch`，某个类型抛异常后全军覆没。
- ③ 全是 `drop ... reason=not-my-tab` → `tabs.list()` 的元素是对象而不是字符串，
  `new Set(list).has("ses_x")` 永远为假，**所有事件被静默过滤**。

查询命令：

```sh
grep -E 'tui-probe|js-trace' "${TMPDIR:-/tmp}/tmux-whistle-hooks.log" | tail -30
tmux-whistle doctor | sed -n '/OpenCode/,/Claude Code/p'
```

`doctor` 已展示 `subs`，`subs=0` 直接报红。

若 R3 落在方案 B 或 C 上，把其余分支的安装代码删掉 —— 三套并存会让 doctor 无法判断
「当前是哪一种」，反而制造新的静默失效面。

### 5.1 先写探针插件，再动映射

先写一个 20 行的探针（只 `console.error` 事件名 + `sessionID` + `parentID` +
`tabs.list()` 长度），跑一轮真实任务把事件序列录下来，再动 `lib/opencode.sh`。

理由与 `docs/idle-prompt-verification.md` 相同：**先探针、再真机回归**。上次
「agent 在正文里提问却不提醒」就是因为推测事件语义、没有实测，绕了三层根因。
OpenCode 侧同样会踩 —— R3 / R10 / R11 全是「看一遍就能定，猜一定会错」的类型。

---

## 6. 安装：软链

### 6.1 主路径：软链**目录**，不是文件

沿用现有 CLI 软链的做法，只加一条 —— 但链路的目标是**目录**，且**链接名不带扩展名**：

```sh
# install.sh
# 仓库 → ~/.local/share/tmux-whistle（既有）
# CLI  → ~/.local/bin/tmux-whistle（既有）
# 插件 → ~/.config/opencode/plugins/tmux-whistle/（新增：软链一个**目录**）
mkdir -p "$HOME/.config/opencode/plugins"
run ln -sfn "$ROOT/hooks/opencode" "$HOME/.config/opencode/plugins/tmux-whistle"
```

三处细节都不能省：

| 细节 | 为什么 |
|---|---|
| 链的是 `$ROOT/hooks/opencode`（目录） | 目录形态才会按文件名识别 part（§3.1.1）。链单文件会被当成 server part。 |
| 链接名是 `tmux-whistle`，**不带 `.js`** | 带 `.js` 会被当成「直接 `.js` 文件」处理，而不是「插件目录」。名字与磁盘上的目录同名即可。 |
| `mkdir -p` 先建父目录 | 用户可能从没装过 OpenCode 插件（现有 `install.sh` 对 `BIN_DIR` 也是这么做的）。 |

```sh
# 错：单文件 → 被当成 server part，TMUX_PANE 是启动快照
ln -sfn "$ROOT/hooks/opencode/tui.js" "$HOME/.config/opencode/plugins/tmux-whistle.js"

# 错：链接名带扩展名 → 同样被当成「直接 .js 文件」
ln -sfn "$ROOT/hooks/opencode" "$HOME/.config/opencode/plugins/tmux-whistle.js"
```

- 不碰用户的 `opencode.json` / `cli.json`。
- 卸载就是 `rm` 那条链接，**必须同步加进 `--uninstall` 分支**（§4 Phase 4）。
  注意判断条件要用目录软链（`[ -L "$path" ]` 对指向目录的软链同样成立）。
- **改完代码不用重装** —— 软链的是整个目录，改 `tui.js` 不需要重新 `install.sh`。
  但是否需要 `/reload` / `opencode service restart` 取决于是 watched 目录还是软链目标
  （软链目标在仓库内，未必被 watch）—— **见 R13**，验完把结论写死在这里，不要想当然。

### 6.2 关于 `petdex.js`：它连「单文件能加载」都不足以证明

本机 `~/.config/opencode/plugins/` 下有一个单文件插件 `petdex.js`。rev 1 拿它当
「单文件插件能工作」的证据，rev 2 已删掉这个推断，这里补上更完整的反证：

1. 它用的是 **V1 形状**（`export default async ({client}) => ({...})`，监听的键是
   `"tool.execute.before"` 这类字符串钩子），而 v2.2.7 的 V2 API 只认
   `Plugin.define({id, setup})`。
2. 它监听的 `session.error` **在 99 个 V2 事件里根本不存在**（V2 里叫
   `session.execution.failed`）。也就是说它至少有一条分支在 V2 下必然不触发。

更关键的是第 3 点：

3. 按官方文档，`plugins/` 下的**直接 `.js` 文件**是**默认 part（server）**。所以就算
   `petdex.js` 被加载了，它也是跑在 **server 进程**里 —— 恰恰是本方案刻意要避开的那个
   进程。它「能跑」不构成「TUI part 能跑」的任何证据。

结论：

- **不要**在文档或代码注释里引用 `petdex.js` 作为范例。
- 「TUI part 会被自动加载」这件事**没有任何现成实例可以佐证**，必须实测（R3）。

### 6.3 回退路径：只有「目录」这一条

⚠️ rev 2 这里写过「在 `cli.json` 里登记**单文件**路径」—— **那条是确定不可行的**，官方原文：

> Configured local paths **must be directories**. A path to a single file is **skipped**.

所以 `"plugins": [".../hooks/opencode/tui.js"]` 会被**静默跳过**（不报错、不加载）——
比没有回退更糟，因为 doctor 只会看到「配了但没生效」。

真正可用的形态只有两种，**都必须是目录**：

| 方案 | 形态 | 何时用 |
|---|---|---|
| **A（主路径）** | 软链目录到 `~/.config/opencode/plugins/tmux-whistle` | 自动发现覆盖 TUI part 时（R3 通过） |
| **B** | 在 `cli.json` 的 `plugins` 里登记**目录路径** | 自动发现不覆盖纯 TUI 插件时 |
| **C（兜底）** | 目录里加最小 `index.js`（server part）做零成本代理 | A/B 都不通时，见下 |

方案 B 的写法（路径指向**目录**，不是文件）：

```jsonc
{
  "plugins": ["/Users/<user>/.local/share/tmux-whistle/hooks/opencode"]
}
```

方案 C 是针对「纯 TUI 插件必须走 `cli.json`」这条歧义的兜底：给目录补一个最小
`index.js`（`Plugin.define({id, setup(){}})`），插件就从「纯 TUI」变成「TUI + server 双 part」，
从而落进 `plugins/` 自动发现覆盖的范围。

> ⚠️ **方案 C 的 server part 必须一个 tmux 调用都不做。** 它的存在只是为了满足
> 「插件要有个 server part」的形状要求，事件转发与状态写入仍然全部由 **TUI part** 完成。
> 一旦 server part 开始写 tmux，`TMUX_PANE` 是启动快照的问题立刻复现（§1）——
> 那就等于把整份方案的地基拆了。
>
> 实现上更安全的做法是让 `index.js` 只做一件事：**什么都不做**（空 `setup`）。
> 不需要「转发」，因为 TUI part 自己就能直接收到事件。

R3 的实测顺序：**A → B → C**，只在前一个失败时才试下一个。
验通之后把 install 代码里其余分支删掉，不要留三套并存（§5.2）。

若最终只能走 B（要改用户 `cli.json`），按 `lib/install-hooks.sh` 的规矩办：
先备份、只增删带 `tmux-whistle` marker 的条目、重复执行结果一致。

### 6.4 doctor 要能回答「插件跑没跑」

`doctor` 加一节，至少回答五件事，因为它是最容易静默失效的一环：

1. `~/.config/opencode/plugins/tmux-whistle` 是否存在，且是**指向目录**的有效软链
   （`[ -L ]` 且 `[ -d "$(readlink …)" ]`）。**注意不能只判 `-f`** —— 目录形态用 `-f`
   会永远为假，doctor 会误报「未安装」。
2. 目录里有没有 `tui.js`（part 文件名错了就不会被当成 TUI part，§3.1.1）。
3. 插件是否真的加载进 **TUI 进程**（§5.2 的 `role=cli` 判定，而不是只看「有没有日志」）。
4. `TMUX_PANE` 是否可读 —— 为空说明 TUI 不在 tmux 里，所有写入都是 no-op。
5. 是否有多个 TUI 在收同一批事件（§1.1）—— 至少提示「同一 session 可能在多个 pane 重复显示」。

第 3 条是重点：**不能只检查文件存在就报绿**。它恰恰是「文件在、但没加载 / 加载错进程」
这种静默失效的典型场景，也是 R3 存在的原因。

---

## 7. 测试计划

| 层 | 文件 | 内容 |
|---|---|---|
| L1 | `test/unit/opencode.bats` | `source lib/opencode.sh`，测纯函数：事件名 + JSON → 通道/状态（含 §2.2 的四种 reason、§2.4 的三种 reply、§2.6 的不映射）、在飞 shell 集合的增删幂等、`error.message` 取首行。不碰 tmux。 |
| L2 | `test/integration/opencode.bats` | 真实 `hooks/opencode.sh` + 隔离 server，断言 `@whistle` / `@whistle_notice` 最终值；重点守 §2.7 那七条。 |
| L3 | `test/e2e/opencode_hook.bats` | 完整链路：spawn `opencode.sh` → 状态栏真实渲染；`--tui-exit` 收尾不留 `◉`。 |
| 回归 | 既有 `test/integration/subagent.bats` | TTL 用例必须对 OpenCode 的事件集同样成立。 |
| 静态 | `test/integration/install.bats` | **守插件目录形态**：`install.sh` 之后断言 `~/.config/opencode/plugins/tmux-whistle` 是**目录软链**、且其下有 `tui.js`；`--uninstall` 之后断言链接已删。这条防止有人把安装改回单文件而无人发现。 |

`lib/opencode.sh` 与 `hooks/opencode.sh` **都被 `Makefile` 的 wildcard 自动覆盖**：

```make
LIB_SH   := $(wildcard lib/*.sh)        # :11
HOOK_SH  := $(wildcard hooks/*.sh)      # :12
POSIX_SH := $(LIB_SH) $(HOOK_SH) $(BIN_SH)   # :14
```

所以 `make lint` / `make fmt` **不需要改 Makefile**。只有将来新增
`scripts/*.sh` 时才要手工加进 `BIN_SH`（`scripts/` 是显式列举，不是 wildcard）。

`hooks/opencode/tui.js` 不参与 shfmt / shellcheck（不是 shell 文件）。

---

## 8. 已定的取舍

| 取舍 | 决定 | 理由 |
|---|---|---|
| 首版范围 | **完整到 Phase 3** | 活动通道单独上线收益有限；通知通道才是「跨 session」的核心价值。后台与子 agent 一起做，避免「在跑却显示完成」这类必须在同版解决的语义问题。 |
| 安装方式 | **软链到 plugins 目录** | 与现有 CLI 软链一致；不碰用户 JSON；改完代码不用重装；卸载即删链接。 |
| 插件形态 | **目录 + `tui.js`，绝不单文件** | 单文件会被当作 server part 加载进错误进程；`plugins` 配置里的单文件路径会被**静默跳过**（§3.1.1、§6.3）。 |
| 映射位置 | **`lib/opencode.sh` 纯函数 + `hooks/opencode.sh` 薄壳** | 守住 `make check` 零 node 依赖；让 L1 单测可 source；测试打法与 core 一致。 |
| pane 归属 | **TUI 提供，不用 server** | server 环境是启动快照且事件无 pane 信息，猜必错（§1 有实测）。 |
| 多 TUI 重复事件 | **按 `tabs.list()` 过滤 + 文档化残留** | 事件层无 client 标识，无法彻底解决（§1.1）。 |
| 多 session / 单 pane | **按 pane 合并，显示最高 rank** | 与「汇总数 pane」不变量一致；写进 README（§3.6）。 |

---

## 9. 参考

- `hooks/claude-code.sh` —— 事件映射的对照实现，`hooks/opencode.sh` 应与它同构
- `lib/core.sh:951-958`（`whistle_forget_agent`）、`575-583`（子 agent 推导层）
  —— `gone` 与 `@whistle_sub` 的原始理由
- `bin/tmux-whistle:647-665` —— `_cs_pane_hint` / `%N` 目标 pane 的现成管道
- `docs/terminal-notifier-integration-plan.md` —— 本文档的格式与验收写法参照
- `docs/idle-prompt-verification.md` —— 「先探针再回归」的方法论来源
- `docs/todo.md` TODO-18 / TODO-29 —— 后台任务与 server 环境快照的既有记录
- `CLAUDE.md`「不变量」一节 —— 双通道、`gone`、`@whistle_sub` TTL
- OpenAPI：`https://opencode.ai/docs/openapi.json`（事件 schema 的事实来源）
- TUI 插件上下文：`https://opencode.ai/docs/build/plugins/cli`
  （`context.ui.tabs`、`context.data.session.root`）

---

## 10. 修订记录（rev 1 → rev 2 → rev 3）

| 编号 | 问题 | 修正 |
|---|---|---|
| S1 | 漏掉「多 TUI 重复收到同一批事件」 | 新增 §1.1（过滤策略 + 已知限制）、R12、§3.6 与 README 的双向限制 |
| S2 | §7 的 L1 单测无法覆盖 `hooks/opencode.sh`（有 `cat` 与 `exit`） | 拆出 `lib/opencode.sh`（纯函数、可 source）+ `hooks/opencode.sh`（薄壳）；新增 §3.1 的拆分理由与对老约定的说明 |
| S3 | 「要把 `hooks/opencode.sh` 加进 Makefile」是错的 | §7 改为「wildcard 自动覆盖，无需改 Makefile」 |
| S4 | `interrupted` 一律映 `idle` | §2.2 按 `reason` 四态分派；新增 R10 |
| S5 | 软链后插件无法用自身路径定位仓库 | 新增 §3.2（`import.meta.url` + `realpathSync`，禁用 cwd/`$0`） |
| M1 | `session.retry.scheduled` 未纳入 | §2.6 说明「不映射」的理由，仅记 debug 日志 |
| M2 | `permission.replied` 的 `reject` 路径会留 `▶` | §2.4 按 `reply` 分派：`once/always` 不动活动态，`reject` → `idle` |
| M3 | `cli.json` 回退方案未验证 | §6.3 标为「本身也待验」，并给出三种形态的实测顺序 |
| M4 | 拿 `petdex.js` 当可用性证据不成立 | §6.2 删除该推断，给出两条反证（V1 形状、`session.error` 不存在） |
| M5 | Phase 2 验收与 Phase 3 冲突 | §4 Phase 2 加显式提示：Phase 3 会**按设计**改写该验收 |
| M6 | `session.idle` 定性不准、R1 风险高估 | §2.6 改为「瞬时信号 vs 持久语义」；R1 降级为非阻塞 |
| m1 | §3.1 与 §3.4 的退出调用链像矛盾 | §3.5 合并为单一路径：`opencode.sh --tui-exit` → `--clear-pane %N` |
| m2 | Phase 0「一行改动」却列三个文件 | 改为「每个文件一行」 |
| m3 | 把 sanitize 写成不变量会让实现者重复消毒 | §0.3 改为说明「由 core 负责，适配器不要重复」 |
| m4 | 多行 `error.message` 未说明截断 | §2.7 表末行加「首行进徽章，全文进 `--body`」 |
| m5 | `__uninstall` 漏删新链接 | §4 Phase 4 与 §6.1 显式要求同步 `--uninstall` 分支 |
| m6 | `pty.*` 易与 `shell.*` 混淆 | §2.3 明确不映射并给理由 |

### rev 2 → rev 3（依据官方 `docs/plugins` 原文核对）

| 编号 | 问题 | 修正 |
|---|---|---|
| S6 | **软链单个 `tui.js` 文件是错的**：`plugins/` 下的直接 `.js` 文件是**默认 part（server）**，会被加载进 `TMUX_PANE` 不可信的 server 进程 | §3.1.1 新增「目录 vs 单文件」对照表；§6.1 改为**软链目录、链接名不带 `.js`**；§3.1 文件布局标注「`hooks/opencode/` 是插件目录、`tui.js` 名字不能改」 |
| S7 | rev 2 §6.3 的「`cli.json` 登记单文件路径」**确定不可行** | 官方原文：*"Configured local paths must be directories. A path to a single file is **skipped**."* → 删掉该回退；改为 A/B/C 三种**目录**形态，并给出适用条件 |
| S8 | R3 的验证方法太模糊（「打一行 toast 确认」），无法区分「没加载 / 加载进 server / 加载进 TUI」 | 新增 §5.2：探针打 `role=` 标记 → 读日志 → **三种结果互斥的判定表**；补「必须见到两个不同 pid」的前提检查 |
| m7 | §6.2 的「单文件仍可信」在 rev 3 下已不成立 | 补第 3 条反证（直接 `.js` 是 server part），明确「TUI part 无现成实例可佐证」 |
| m8 | doctor 用 `-f` 判目录会永远误报未安装 | §6.4 改为 `-L` + `-d`，并加「目录里有 `tui.js`」与「加载进 TUI 进程」两条检查 |
| m9 | 缺一条防止「安装被改回单文件」的守卫 | §7 新增 `test/integration/install.bats` 静态断言目录形态 |
| m10 | 软链目录后改 `tui.js` 是否即时生效未知 | 新增 R13（watched 目录 vs 软链目标在仓库内） |

### rev 3 → rev 4（实现完成后回填）

| 编号 | 事项 | 结果 |
|---|---|---|
| I1 | Phase 0 默认值 | `lib/core.sh`、`bin/tmux-whistle`、`README.md` 三处各加 `opencode`；`pane_current_command` 实测就是 `opencode`，按进程发现空闲立刻生效 |
| I2 | 映射层拆分 | `lib/opencode.sh`（纯函数、可 source）+ `hooks/opencode.sh`（薄壳）。L1 实测能直接 source 并断言 36 条 |
| I3 | 事件分派 | §2.2 / §2.4 的分派已落地；`superseded` 不动活动通道、`reject` 收尾活动态，均有测试钉住 |
| I4 | 后台 shell | 用**在飞 id 集合**（`@whistle_oc_shell`，存 pane option 不落盘）而非计数器；重复 started 幂等，`ended` 按 id 精确移除 |
| I5 | 安装 | `install.sh` 目录软链 + `--uninstall` 同步删除；`test/integration/install.bats` 静态钉住形态 |
| I6 | doctor | 读 `--probe` 日志判断「插件跑没跑」；debug 关闭时只报黄不报红（诚实标注「无法确认」） |
| I7 | R3 可观测性 | `tui.js` setup 时 spawn `--probe`；该分支只在 `@whistle_debug=on` 落盘，默认零副作用 |
| I8 | 实测记录 | `opencode plugin list` 识别目录形态；server 只尝试加载单文件 `petdex.js` 并失败（V1 形状）—— 两点都印证 §3.1.1 的判断 |
| I9 | `make check` | 452 项全绿，无残留隔离 server |

### rev 5（真机验证补记）

真机跑通后补了两处实现缺陷，都是「不报错、只是效果不对」的类型：

| 编号 | 问题 | 修正 |
|---|---|---|
| I10 | **TUI 启动没写 idle** —— 上次退出的 `gone`（rank 0）一直留着，而推导层只把**空**状态推成 idle，`gone` 不是空。用户重启 TUI 后那个 pane 在状态栏上彻底不存在，看起来像「插件没装上」 | 新增 `hooks/opencode.sh --tui-start`：启动报 `idle`（与 Claude 侧 SessionStart 同一理由）。已有 `running`/`idle` 时不覆盖，避免热重载把正在干活的打回空闲 |
| I11 | **事件并发 spawn 导致乱序** —— 实测 `permission.asked`(wait) 与 `execution.succeeded`(done) 并发时，后到的 done 把 ◔ 盖成 ◆。状态写入是「后发生者赢」的有序语义 | `tui.js` 改成 promise 链串行；cleanup 先 `await queue` 再写 `gone`，否则退出会把排队中未落盘的事件冲掉 |

R3 的最终结论（2026-11-13 09:39 真机日志）：

```
09:39:31 [11015] agent=opencode event=tui-probe TMUX_PANE=%8 loaded=ok
```

- 插件**确实加载进了 TUI 进程**（`TMUX_PANE=%8` 是正确 pane，不是 server 的启动快照）。
- `opencode plugin list` 识别目录形态；server 只尝试加载单文件 `petdex.js` 并失败。
- 目录 + `tui.js` 的形态得到验证，无需回退到方案 B/C。

另外用模拟 context 直接驱动 `tui.js` 验证了完整链路（JS → `hooks/opencode.sh` → tmux）：

```
started → @whistle=running
succeeded → @whistle=idle, @whistle_notice=done
permission.asked → @whistle_notice=wait, msg="edit: a.js"
cleanup → @whistle=gone，通知保留
```

### rev 6（2026-11-13：opencode 在跑但状态栏一直 ◉）

现场：`%8` 的 `@whistle=idle`（`--tui-start` 生效），但真实事件数为 **0**。

排查暴露两个「静默吞掉全部事件」的缺陷，都不报错：

| 编号 | 问题 | 修正 |
|---|---|---|
| I12 | **订阅循环没有逐条 try/catch** —— 任意一条 `data.on()` 抛异常就打断整个循环，后面的事件全收不到，探针却照样有记录（探针在循环之前） | 逐类型 try/catch；失败的类型改由 `data.listen` 全量流兜底；订阅结果带进 `--probe`（`subs=N failed=...`），doctor 直接展示 |
| I13 | **`tabs.list()` 的元素形状假设错了** —— 原实现 `new Set(list)` 把元素当字符串，实际可能是对象（`{sessionID}`）。`Set.has("ses_x")` 永远为假 → **所有事件被身份过滤丢掉**，且完全静默 | 元素既支持字符串也支持对象（取 `sessionID`/`id`/`session.id`）；**拿不到 id 时 fail-open** 而不是当成「都不属于我」 |
| I14 | 排查时无据可依 | 新增 `--trace`：debug 开时把每个原始事件与丢弃原因（`no-sessionID` / `not-my-tab` / `tabs-shape-unknown`）写进同一份 hook 日志 |

真机复核（插件热重载后）：

```
10:17:53 agent=opencode event=tui-probe TMUX_PANE=%8 loaded=ok subs=11
```

11 条订阅全部建立，`doctor` 现在会报「插件已加载，订阅 11 个事件」，并把
`tui.js` 里 `EVENTS` 数组逐条列出来（失败的那条标 `✗ ← 订阅失败`；声明数
与实际挂上数不一致时额外告警）。
此前 doctor 只能回答「加载了没」，回答不了「订阅建立了没」—— 而后者才是
「加载了却一直 ◉」的判别点。
