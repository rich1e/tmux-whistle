# tmux-whistle

在 tmux 里跨 session 接收 agent 状态通知：**工作完成** / **等待下一步**。

你在 session A 跑 agent，在 session B 干别的事。A 做完了或者卡在等你批准，
B 的状态栏立刻告诉你 —— 不用来回切窗口看。

```
  ● agentA ◆          ← 窗口徽章：这个窗口的 agent 做完了
                     ⚑2   ← 全局计数：全机器还有 2 件事等着你
  [agentA] 完成: 重构完成，抽出了 core.sh   ← 瞬时提示（5 秒后消失）
```

## 功能特性

- **推送而非轮询**：agent 通过 hook 主动上报状态，tmux 不去 `capture-pane` 猜提示符 —— 没有扫描成本，也没有误报
- **完成与等待分得开**：`done`（做完了）、`wait`（等你批准）、`error`（回合被 API 错误中断）、`running`（在跑）、`idle`（进程在但闲着）五态各自独立上报，这是「有输出变了」「猜提示符」这类做法原理上分辨不了的
- **跨 session 且粘性**：通知出现在你正看着的那个 session，一直保留到你切进去处理完
- **六个独立信号**：窗口徽章、全局计数 `⚑N`、边框变色、边框状态行、瞬时提示、桌面通知，各管各的，可单独关闭
- **任何 agent 都能接入**：Claude Code 装上 hooks 即用；别的 agent 直接在脚本里调 `tmux-whistle done` 就行；另有关键词兜底检测（可选，默认关）
- **零运行时依赖**：只用 tmux 自身能力，兼容 oh-my-tmux 与 tpm / tpack

详见 [使用](#使用)、[配置](#配置)、[兼容性](#兼容性)。

## 为什么不是 monitor-activity

| | monitor-activity | tmux-notify | tmux-whistle |
|---|---|---|---|
| 知道"完成"和"等你在批"是两件事 | ⚠ | ⚠ | ◆ |
| 检测方式 | 有输出变了 | 轮询猜提示符 | **agent 主动上报** |
| 消息内容 | 无 | 无 | 有（最后一条回复） |
| 跨 session 可见 | 只在窗口标签高亮 | 只弹系统通知 | 状态栏计数 + 瞬时提示 + 系统通知 |
| 粘性 | 有 | 无 | 有，直到你切进去 |

根本差别：**"我做完了"和"我在等你"是 agent 自己的判断**，tmux 层面看不到。
所以 tmux-whistle 不去猜，而是让 agent 通过 hook 主动告诉我们。

---

## 安装

### 方式一：tpm / tpack（推荐）

```tmux
# ~/.tmux.conf 或 ~/.config/tmux/tmux.conf.local
set -g @plugin 'rich1e/tmux-whistle'
```

然后按 `prefix + I`。tpm 会 clone 仓库并执行插件入口，徽章、全局计数、
边框、瞬时提示、`prefix + n` 菜单随即就位。

**还要补两步**（tpm 路径不会自动做）：

```sh
# ① 装 Claude Code hooks —— 不装的话 agent 干完不会自动亮徽章
~/.config/tmux/plugins/tmux-whistle/bin/tmux-whistle install-hooks

# ② 把 CLI 链进 PATH —— 不装的话 tmux-whistle 命令找不到
ln -sfn ~/.config/tmux/plugins/tmux-whistle/bin/tmux-whistle ~/.local/bin/tmux-whistle
```

### 方式二：手动安装（不用 tpm）

```sh
git clone https://github.com/rich1e/tmux-whistle.git
cd tmux-whistle
./install.sh          # 链接 + 写 tmux.conf.local + 装 Claude Code hooks
```

`install.sh` 做四件事：

1. 把仓库软链到 `~/.local/share/tmux-whistle`
2. 把 CLI 软链到 `~/.local/bin/tmux-whistle`（hook 与命令行都要能找到它）
3. 往 `~/.config/tmux/tmux.conf.local` 追加一段带 marker 的配置块（改前备份原文件）
4. 幂等地把 Claude Code hooks 合并进 `~/.claude/settings.json`（改前备份，只管理带 `tmux-whistle` marker 的条目）

常用参数：

```sh
./install.sh --dry-run     # 预览安装与配置改动
./install.sh --no-hooks    # 不修改 Claude Code 的 settings.json
./install.sh --cleanup     # 额外清理失效的 tmux-notify 按键绑定
./install.sh --uninstall   # 移除本插件的 marker 配置块与两个软链
```

卸载不会动 Claude Code hooks；也要移除的话，再跑
`lib/install-hooks.sh --uninstall`，它只摘除本插件的条目。

> **两条路别混用。** `install.sh` 会往 `tmux.conf.local` 写一行加载插件的命令；
> 如果 tpm 也装了同一个插件，就会加载两份、互相覆盖 `@whistle_root`。选一条即可。

装完重载 tmux：

```sh
tmux source-file ~/.config/tmux/tmux.conf    # 或 prefix + r
tmux-whistle doctor
tmux-whistle --version
# tmux-whistle 0.1.0-alpha.1+20261030.1
```

版本由「主版.次版.修订 + 内测/公测阶段 + 构建日期与流水号」组成，规则见
[版本号与发布规范](docs/versioning.md)。

> **升级插件后要重跑一次 `tmux-whistle install-hooks`。** 当前共管理 8 个事件；
> hooks 是快照式写进 `settings.json` 的，这次新增的 `PreToolUse` /
> `SubagentStop` 不会自己出现。不重跑的话，工具调用（含 plan 批准后继续跑）与
> 后台/子 agent 的状态不会完整上报。该命令幂等，其它 hook 原样保留；
> 重跑后需重启 Claude Code 或开新会话才生效。

### macOS：桌面通知（可选，默认关）

需要离开 tmux 也能收到提醒时，推荐安装 **terminal-notifier 3.1+**
（v3 要求 macOS 10.14+）。它是可选依赖，插件不会自动安装：

```sh
brew install terminal-notifier
terminal-notifier -diagnose    # 检查通知授权、提醒样式与 Focus 等系统设置
tmux set -g @whistle_os on     # 默认 off；确认授权后再开
```

若诊断显示未授权，去 **系统设置 → 通知 → terminal-notifier** 打开「允许通知」。
旧版本不支持 `-diagnose` 时请升级到 3.1+；`tmux-whistle doctor` 也会提示。

没有 terminal-notifier 时可降级使用 `osascript`。它的通知由 Script Editor 路由，
授权位置是 **系统设置 → 通知 → Script Editor**，未授权时可能静默失败：

```sh
osascript -e 'display notification "tmux-whistle 测试"'
```

---

## 配置

所有配置都是 tmux 的 user option，写在 `~/.config/tmux/tmux.conf.local` 里长期生效，
或者用 `set -g` 临时改。

### 配置项

| option | 默认 | 说明 |
|---|---|---|
| **总开关** | | |
| `@whistle_enabled` | `on` | 总开关 |
| **投递渠道**（各管各的，互不影响） | | |
| `@whistle_badge` | `on` | 窗口标签徽章 |
| `@whistle_border` | `on` | pane 边框变色 |
| `@whistle_border_status` | `off` | pane 边框状态行：`top` / `bottom`，分屏时按 pane 显示符号 |
| `@whistle_display` | `on` | 状态栏瞬时提示 |
| `@whistle_os` | `off` | 桌面系统通知 |
| `@whistle_os_app` | 空 | 点击通知时要激活的 macOS 应用 bundle ID，如 `com.googlecode.iterm2` / `com.apple.Terminal`；无法识别终端时省略激活 |
| **行为** | | |
| `@whistle_self` | `off` | 是否也提示自己所在的 session |
| `@whistle_clear_on_focus` | `on` | 切进窗口自动把通知标为已读（不清 `running` / `idle`） |
| `@whistle_display_ms` | `0` | 瞬时提示显示时长，`0` = 跟随 tmux 的 `display-time` |
| **外观** | | |
| `@whistle_color_done` | `#af5fff` | 完成色（紫） |
| `@whistle_color_wait` | `#af8700` | 等待色 |
| `@whistle_color_error` | `#d70000` | 错误色 |
| `@whistle_color_running` | `#00af00` | 运行中色（绿） |
| `@whistle_color_idle` | `#8a8a8a` | 空闲色（灰） |
| `@whistle_color_pending` | `#5fd7d7` | 待处理总数 `⚑N` 的颜色（青色，独立于等待色） |
| `@whistle_icon_pending` | `⚑` | 全局计数前面的图标 |
| `@whistle_icon_done` | `◆` | 完成符号 |
| `@whistle_icon_wait` | `◔` | 等待符号 |
| `@whistle_icon_error` | `⚠` | 错误符号 |
| `@whistle_icon_running` | `▶` | 运行中符号（`@whistle_spin on` 时是 Braille 帧，计数为 0 或 `spin off` 时用它） |
| `@whistle_icon_idle` | `◉` | 空闲符号（汇总的 `◉N`、窗口徽章、菜单三处共用） |
| `@whistle_agent_cmds` | `claude claude.exe` | 哪些前台进程算「agent」（按进程发现空闲时用） |
| **动画** | | |
| `@whistle_spin` | `on` | running 用 Braille 帧轮转（`off` 退回静态图标） |
| `@whistle_spin_interval` | `0.5` | 每帧间隔（秒） |
| `@whistle_recompute_every` | `60` | 推进器每 N 帧触发一次全局重算（配 0.5 秒 ≈ 30 秒）；用来让过期的后台 agent 标记自行回落 |
| `@whistle_sub_ttl` | `1800` | 「pane 里有后台/子 agent 在跑」这个标记的存活秒数；`0` = 永不过期 |
| **调试与兜底检测** | | |
| `@whistle_debug` | `off` | 同时写投递日志与 hook 事件日志（路径见下） |
| `@whistle_detect` | `off` | 关键词兜底检测（见下） |
| `@whistle_detect_interval` | `15` | 兜底检测的轮询间隔（秒） |
| `@whistle_detect_idle` | `180` | 输出静默多少秒判为完成 |
| `@whistle_detect_wait-re` | 见下 | 等待关键词的扩展正则（ERE） |
| `@whistle_detect_done-re` | 见下 | 完成关键词的扩展正则（ERE），还要满足静默时长 |

调试日志分两份：投递层写 `${TMPDIR:-/tmp}/tmux-whistle.log`，hook 接入层写
`${TMPDIR:-/tmp}/tmux-whistle-hooks.log`；可分别用环境变量 `WHISTLE_LOG` 与
`WHISTLE_HOOK_LOG` 覆盖路径。

兜底检测的两个正则未设置时使用以下默认值，也可以照这个形式自定义：

```tmux
set -g @whistle_detect_wait-re 'esc to interrupt|Do you want to|❯ 1\. Yes|waiting for your input'
set -g @whistle_detect_done-re '⏵⏵|Bypass Permissions on'
```

### 改完怎么生效

- 写在 `tmux.conf.local` 里 → `prefix + r` 重载
- 命令行临时改 → 立刻生效：

```tmux
set -g @whistle_badge off          # 关掉窗口徽章，只留全局计数
set -g @whistle_border off         # 关掉 pane 边框变色
set -g @whistle_self on            # 也提示自己所在的 session
set -g @whistle_color_done '#00af00'  # 改色
set -g @whistle_color_running '#5faf00'  # 运行中的 ▶ 换另一种绿色
set -g @whistle_display_ms 3000    # 瞬时提示显示 3 秒
```

```tmux
# 换图标（默认 ⚑ / ◆ / ◔ / ⚠ / ▶ / ◉）
set -g @whistle_icon_pending '●'
set -g @whistle_icon_done    '★'
set -g @whistle_icon_wait    '⏸'
set -g @whistle_icon_error   '⚠'
set -g @whistle_icon_running '⏵'

# 显式设成空串 = 不要图标，只留颜色和数字
set -g @whistle_icon_pending ''
```

图标要过一遍消毒（剔掉 `# { } |`），所以填这些字符不会破坏状态栏。**设成空串**与**不设置**是两回事：不设置用默认图标，设成空串就是真的不显示。

**改颜色和图标不需要重载配置** —— 徽章是纯 format，重跑一次 `scripts/setup.sh`（或 `prefix + r`）即可。

> `@whistle_badge` / `@whistle_self` 这类**开关**也建议重载一次：它们决定徽章
> format 的内容与投递目标，重载（`prefix + r`）能让改动立刻生效。

### `@whistle_self` 到底控制什么

它只管**发起方自己所在的**那个 session（也就是 agent 跑任务的那个 session），
不管其它 session 的扇出：

| | 你在别的 session（常见情况） | 你和 agent 在同一个 session |
|---|---|---|
| `off`（默认） | 收得到（其它 session 的扇出） | **收不到**瞬时提示 |
| `on` | 收得到 | 也收得到 |

也就是说：**只有你一个人、且只有一个 session 时，默认配置下不会有瞬时提示**。
那种场景想看到提示，开 `@whistle_self on`，或者直接看窗口徽章 / `⚑N`。

### 徽章在 oh-my-tmux 里的位置

徽章走 oh-my-tmux 的官方扩展点 `tmux_conf_theme_window_status_format`，落在 powerline
芯片**内部**而不是外侧。没配这个扩展点的话，插件会自己 patch `window-status-format`
兜底 —— 效果一致。

---

## 使用

### 状态栏上会看到什么

三个独立信号，可以各自开关：

```
 1 claude.exe◆            ← ① 窗口徽章
      ⠋ 1 ◉ 2 ◆ 1 ◔ 0 ⚠ 0   ⚑ 2  ← ② 五态汇总 + 全局待处理计数
 [claude.exe] 完成: 重构完成，抽出了 core.sh   ← ③ 瞬时提示（5 秒）
```

| 信号 | 位置 | 回答的问题 |
|---|---|---|
| **窗口徽章** | 该窗口**所属 session** 的窗口列表 | 这个窗口的 agent 现在什么状态 |
| **五态汇总** `⠋ 1 ◉ 2 ◆ 1 ◔ 0 ⚠ 0` | `status-right`，**每个 session 都显示** | 全机器各状态各有多少（`⠋` 在跑 / `◉` 空闲 / `◆` 完成 / `◔` 等待 / `⚠` 失败） |
| **全局计数** `⚑N` | `status-right`，紧跟在汇总后面 | 总共还有几件事等着我处理 |
| **瞬时提示** | 状态栏消息行 | 刚刚具体发生了什么 |

汇总段只在真有 agent（`▶` / `◉` / `⚑` 任一非零）时出现；五个格子一起出现、
**计数为 0 的也保留**，这样状态栏宽度不会随计数跳动。

**两组计数互不排斥。** 汇总里的 `▶N` / `◉N` 数的是「agent 在不在干活」，
`◆N` / `◔N` / `⚠N` 数的是「有没有事等你」—— 这是两件正交的事，同一个 pane
可以既在跑、又有事等你。所以看到 `▶ 1 ◉ 2 ◆ 1` 时，`▶1` 与 `◆1` 很可能是**同一个
agent**：它一边跑着，一边刚给过你一条要看的东西。窗口徽章那一格只能显示一个符号，
按优先级取（`⚠` > `◔` > `◆` > `▶` > `◉`）。

### running 的动画

`▶` 那格是动的 —— 有 agent 在跑时会转。用的是经典 Braille 点阵 spinner：

```
⠋ → ⠙ → ⠹ → ⠸ → ⠼ → ⠴ → ⠦ → ⠧ → ⠇ → ⠏ → ⠋ …
```

十帧，默认每 0.5 秒一帧。

**计数为 0 时退回静态 `▶`**（不是继续挂着最后一帧）：推进器在 running 归零时自己退出，
但帧字符还留在 option 里 —— 不判计数的话状态栏会一直显示 `⠋ 0`，动画早停了、字形还在，
看起来像卡死。

**这是怎么做到的**：状态栏里的串是预先算好存在 global option 里的**纯 format**
（不 fork 是硬红线），而 format 本身是静态的 —— tmux 没有「每 N 帧换字符」的原生
能力。所以插件在真有 running 时会拉起一个极小的后台进程（`lib/spin.sh`），
它只做两件事：把当前帧字符写进 `@whistle_spin_char`、重画状态栏。
**running 归零时它自己退出，不常驻。**

（插件存的是**帧字符本身**而不是帧号 —— 早先存帧号、再用嵌套条件式翻成字符，
10 帧要嵌 9 层，大括号配错就会让 tmux 静默渲染成空白。存字符则一层都不用嵌。）

不想有动画：`set -g @whistle_spin off`（退回静态 `▶`）。调速度改
`@whistle_spin_interval`。

动画**只出现在状态栏汇总的 ▶ 格**；菜单和窗口徽章都用静态图标（菜单是一次性快照，帧冻在上面像渲染错乱）
（徽章一格只有一个字符，转起来反而看不清是哪个窗口）。

跨 session 时只有 status-right 上那几项和瞬时提示可见 —— 你在 B 的窗口列表里
看不到 A 的窗口。所以汇总和计数才是"别处有事"的常驻信号，窗口徽章是"这个
session 里的细节"。

还有一个可选的第 4 个信号：`@whistle_border_status top` 会在**每个 pane 的边框上**
显示该 pane 自己的状态符号。同一窗口切了多个 pane 时特别有用 —— 一眼看出是哪个 pane 在等你。
默认关，因为它会占掉每个 pane 顶部一行。

### 状态与符号

状态分成**两条正交通道**，一个 pane 可以同时命中两条：

**活动通道 —— 这个 pane 里有没有 agent 在干活**

| 状态 | 徽章 | 计入 ⚑ | 什么时候出现 |
|---|---|---|---|
| `running` | `▶` | 否 | 主 agent 正在干活（发了一条 prompt 之后），**或这个 pane 里有后台/子 agent 在跑** |
| `idle` | `◉` | 否 | 进程在、但没在干活：刚敲 `claude` 或 `--continue` 恢复，停在提示符前等你输入 |

**通知通道 —— 有没有事等你**

| 状态 | 徽章 | 计入 ⚑ | 什么时候出现 |
|---|---|---|---|
| `done` | `◆` | 是 | 一轮工作结束 |
| `wait` | `◔` | 是 | 等你批准 / 等你输入 |
| `error` | `⚠` | 是 | 回合因 API 错误结束（限流 / 过载 / 认证失败 …） |

> **为什么分两条**：早先只有一个状态槽，于是「后台 agent 完成」这条通知会把
> 主 agent 的 `▶` 顶掉；你切进窗口读掉通知、那一格被清空之后，「按进程发现」
> 又会把一个**正在干活**的 agent 判成 `◉` 空闲 —— 全程零报错。分成两条通道
> 之后，通知再怎么来也碰不到活动状态。

`running` 与 `idle` 都不计入 `⚑N`，也不发瞬时提示与桌面通知 —— 每敲一次 prompt
就朝所有 session 推一条「运行中」纯属噪声。它们出现在状态栏汇总的 `▶N` / `◉N` 里，
`prefix + n` 菜单里分别是绿色 `▶` 与灰色 `◉`，agent 退出（`SessionEnd`）时一起熄灭。

`idle` 有两个来源：

- **会话开始 / 恢复**时 hook 报上来（`SessionStart`）；
- **按进程发现**：某个 pane 从没上报过状态、但前台跑着 agent 进程
  （`@whistle_agent_cmds` 里那些，默认 `claude claude.exe`）—— 用 resurrect
  恢复 tmux 之后，那几个还停在提示符前等你的 agent 就属于这一类。

> 按进程发现比对的是 tmux 的 `pane_current_command`，那是**进程名**而不是命令行。
> 原生二进制装出来的 `claude` 匹配得上；跑在 node 上的 `claude` 那边看到的是
> `node` —— 那就把 `node` 也加进清单（但别只填 `node`：跑 node 的 pane 不止 agent）。
> 对不上的时候先看一眼实际值：
> `tmux list-panes -a -F '#{pane_id} #{pane_current_command}'`。

`idle` **顶不掉待处理通知**：恢复会话不会把上一轮还没读的 `◆` / `◔` / `⚠` 当成
已读。读完一条 `done` 之后，那一格会被清空；但只要 agent 还活着（前台进程还在），
按进程发现会把它算回 `◉` —— 所以「活着但在等」这件事不会因为你读过就消失。

> **已知限制：后台 Bash 看不见。** 插件只认 Claude Code 的 hook 事件，而
> `Bash(run_in_background: true)` 起的后台命令（比如几分钟的 `xcodebuild test`）
> **不产生任何本插件订阅的事件**。所以「主 agent 一轮结束了、后台命令还在跑」时，
> 徽章会落 `◆` / `◉`，而那个命令其实还在转 —— 看起来就像「在跑却显示空闲」。
> 后台/子 **agent** 能看见（`PreToolUse` 的 `Agent`/`Task` 调用会点亮 `▶`），
> 后台 **Bash** 目前看不见。要对上这个场景，先打开 `@whistle_debug on` 看
> `${TMPDIR:-/tmp}/tmux-whistle-hooks.log` 里那一刻到底来了哪些事件。

### 怎么响应

| 操作 | 效果 |
|---|---|
| **`prefix + n`** | 弹出 agent 菜单。每项的格式是 `图标 状态 [session]: 窗口 消息` —— session 名用 `[]` 裹住，和窗口名、agent 的话分开；每项都带状态图标（`◆` 完成 / `◔` 等待 / `⚠` 错误 / `▶` 运行中 / `◉` 空闲）；**待处理项与运行中/空闲的项都能点**，按编号跳过去；待处理项跳过去后顺带清除，其余只是跳过去看看 |
| **直接切进那个窗口** | 徽章自动消失（已读 = 焦点进入，不需要额外确认） |
| `prefix + n` 之外还想要列表 | `tmux-whistle list`（只看待处理，含消息与已存在时长） |
| 都不想做 | `tmux-whistle clear -a` 全清 |

**典型流程**：在 B 看到 ⚑2 → `prefix + n` → 按 `1` → 落到 A 的那个窗口，徽章自己消失。

### 场景一：Claude Code —— 装上就能用，无需任何操作

hooks 装好后自动工作：

| 你做了什么 | agent 的反应 | 状态栏 |
|---|---|---|
| 启动 / 恢复 Claude Code（含 `--continue`） | `SessionStart` hook | `◉`，不计入 ⚑（进程在，但停在提示符前等你） |
| 发一条 prompt | `UserPromptSubmit` hook | `▶`，不计入 ⚑ |
| agent 在调工具（含 plan 批准后继续跑） | `PreToolUse` hook | `▶`（保持亮着） |
| agent 派了后台 / 子 agent | `PreToolUse`（`Agent`/`Task`） | `▶` 一直亮到那个 agent 结束 —— 哪怕主 agent 已经交付 |
| agent 跑完一轮 | `Stop` hook | `◆` + ⚑ + 提示（活动转 `◉`，但 `◆` 优先显示） |
| agent 要你批准工具调用 | `Notification/permission_prompt` | `◔` + ⚑ + 提示 |
| 回合因 API 错误中断 | `StopFailure` hook | `⚠` + ⚑ + 提示（消息就是错误文本） |
| 退出 Claude Code | `SessionEnd` hook | `▶` / `◉` 熄灭（`◆`/`◔`/`⚠` 保留，等你处理） |

⚠️ **后台 `Bash` 不在上表里** —— 用 `run_in_background: true` 起的后台命令不产生
本插件订阅的任何事件，那个 pane 会显示 `◆` / `◉` 而命令还在跑。见下方「已知限制」。

### 场景二：任何 agent / 脚本

不需要 Claude Code，在 tmux 的 pane 里直接调：

```sh
tmux-whistle run -- long_job.sh          # 跑完自动亮 ◆ 或 ⚠，消息带耗时
tmux-whistle run '备份' -- ./backup.sh    # 也可以自己起个标签
```

`run` 按**退出码**决定状态（0 → `◆`，非 0 → `⚠`），并把子命令的退出码原样透传出来，
所以 `make && tmux-whistle run -- …` 失败时仍然返回非零。
它只认退出码、不解析输出 —— 一个退出码 0 的命令是不是「真的完成了」，包装器判断不了。

纯状态上报也行（脚本自己知道该报什么的时候）：

```sh
long_job.sh && tmux-whistle done "备份完成" || tmux-whistle error "备份失败"
```

或者从别人的 session 里主动求助：

```sh
tmux-whistle wait "需要你选数据库"
```

### 命令速查

```sh
tmux-whistle done    "重构完成"     # 标记完成
tmux-whistle wait    "等你批准"     # 标记等待
tmux-whistle error   "构建失败"     # 标记出错
tmux-whistle running               # 开始干活（亮 ▶，不计入 ⚑）
tmux-whistle idle "等你输入"        # 进程在但闲着（亮 ◉，不计入 ⚑）

tmux-whistle run -- npm test       # 包一个命令：按退出码落 ◆ / ⚠，带耗时
tmux-whistle run '测试' -- npm test # 自定义标签

tmux-whistle list                  # 看所有待处理项
tmux-whistle menu                  # = prefix + n
tmux-whistle jump other:api        # 跳到 session:window 并清除
                                   # 裸窗口名（api）也可以；撞名会列出候选让你指定
tmux-whistle clear                 # 清当前窗口
tmux-whistle clear -a              # 全清
tmux-whistle on | off              # 总开关
tmux-whistle doctor                # 自检
```

不给 `-t` 时默认作用于当前 pane（`$TMUX_PANE`）；也支持 `-t %3` / `-t other:api`。
**选项和消息的顺序随意** —— `done -t %3 "消息"` 与 `done "消息" -t %3` 等价。
消息本身以 `-` 开头时用 `--` 隔开。

### 长消息：`--title` 与 `--body`

徽章位置只有一行宽度，所以消息超 80 字会被截断 —— 改动前截掉的部分**无处可寻**。
现在可以分开给：

```sh
tmux-whistle done --title '重构完成' --body '第一段…第二段…（全文留在这里）'
```

| 参数 | 存到哪 | 上限 |
|---|---|---|
| `--title` | 通知命令 `done` / `wait` / `error` 存 `@whistle_notice_msg`；活动命令 `running` / `idle` 存 `@whistle_msg` —— 徽章与菜单显示的就是它 | 80 字符 |
| `--body` | 通知命令 `done` / `wait` / `error` 存 `@whistle_notice_body`；活动命令 `running` / `idle` 存 `@whistle_body` —— 完整内容（会消毒：剔掉 `# { } \|`、折叠换行） | 400 字符 |

只给 `--body` 时徽章会显示正文的前 80 字；都不给就只有一个普通消息。
Claude Code 的回复全文也会自动作为 `--body` 存下来。

> 完整正文目前**存了但没有正文详情界面**，也不会默认塞进桌面横幅。
> 桌面通知只显示短消息，点击后跳到对应 pane；以上面的 `done` 为例，手工查完整正文：
> `tmux show -pqv -t %<pane_id> @whistle_notice_body`。

---

## 桌面通知（可选，默认关）

推荐 terminal-notifier 3.1+；安装、授权与开启命令见
[macOS：桌面通知](#macos桌面通知可选默认关)。也可以按需指定点击时要激活的终端：

```tmux
set -g @whistle_os on
set -g @whistle_os_app 'com.googlecode.iterm2'  # iTerm2
# set -g @whistle_os_app 'com.apple.Terminal'   # macOS 终端
```

`@whistle_os_app` 默认空：插件会尝试识别终端，无法识别时省略应用激活，
不会猜成某个终端。activate 只负责把应用带到前台；终端有多个 macOS 窗口或标签时，
**不保证所有终端都能精确聚焦对应的 OS 标签**。tmux 内的 client / window / pane 跳转另行处理。

使用 terminal-notifier 时：

- 通知按 pane 分组：同一 pane 的新通知替换旧通知，不同 pane 的通知可以并存。
- 点击通知会激活可识别的终端，并跳到精确 client / window / pane。
  **只有完整跳转成功才标为已读**；没有 attached client、目标 pane 已消失或任一切换失败时，
  通知仍保留，可以处理后再次点击。
- 在 tmux 内 `clear`、切窗 / 菜单已读，或桌面跳转成功，都会同步撤回清除范围内对应的
  macOS 通知。即使之后已经关掉 `@whistle_os`，旧通知也仍会撤回。
- 已读与撤回只清通知通道，**不会清掉活动通道的 `running` / `idle`**。

terminal-notifier 不存在或发送失败时，可降级到 `osascript` / `notify-send`；
降级渠道只有基本提醒，**没有精确点击跳转、逐 pane 替换与 group 撤回**。
桌面投递失败不影响 agent 状态写入。

桌面横幅仍只显示短消息；`--body` 的完整正文保存在 tmux 中，不会默认放进横幅，
点击通知也不是正文详情查看器。

## 兜底检测（可选，默认关）

没有配 hooks 的 agent 也想被检测到：

```tmux
set -g @whistle_detect on
set -g @whistle_detect_interval 15
```

它每 N 秒 `capture-pane` 一次，匹配关键词。**会误报**，所以默认关闭。
一旦某个 pane 被 hook 接管过，检测就再也不碰它 —— hook 永远优先。

另外提供可选的 OSC 133 片段，让 tmux 知道命令边界（配合
`pane-command-finished` hook 可免轮询）：

```zsh
# ~/.zshrc
source /path/to/tmux-whistle/share/whistle.zsh
```

## 兼容性

- tmux **>= 3.2**（用到 `run-shell -b`、`refresh-client -S`）
- **oh-my-tmux**：徽章走官方扩展点 `tmux_conf_theme_window_status_format`，落在 powerline 芯片内部；
  没配的话插件会自己 patch `window-status-format` 兜底
- tpm / tpack：标准插件布局（`*.tmux` 入口）
- 运行时零第三方依赖；只有 `osascript` / `notify-send` / `terminal-notifier` 这些系统工具，缺失则静默跳过

## 出问题时

```sh
tmux-whistle doctor                  # 逐项自检：版本 / 注入 / 渠道 / hooks / 失效绑定
terminal-notifier -diagnose          # 3.x：检查通知授权与系统投递设置；旧版请升级
tmux-whistle list                    # 状态确实写进去了吗
```

桌面通知异常时，doctor 会对 terminal-notifier 3.x 调用 `-diagnose`，区分
「命令存在」与「通知已授权」；旧版本会提示升级，而不是把缺少该选项误报成未授权。
注意 doctor 的 PATH 与 Claude Code hook 的运行环境可能不同，doctor 通过不代表
hook 或通知点击回调一定能找到同样的命令。

还查不出来就开调试日志：

```tmux
set -g @whistle_debug on
# 日志写到 ${TMPDIR:-/tmp}/tmux-whistle.log
```

## 文档

- [开发文档](docs/development.md) —— 本地开发、测试、目录结构、贡献
- [版本号与发布规范](docs/versioning.md) —— SemVer、alpha/beta、构建戳与发布流程
- [功能待办](docs/todo.md) —— 已知问题与限制
- [需求分析](docs/requirements-analysis.md) —— 需求来源与竞品调研
- [设计方案评审](docs/notify-design-review.md) —— 「事件收件箱」形态的取舍与吸收路线
