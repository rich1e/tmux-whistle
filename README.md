# tmux-whistle

在 tmux 里跨 session 接收 agent 状态通知：**工作完成** / **等待下一步**。

你在 session A 跑 agent，在 session B 干别的事。A 做完了或者卡在等你批准，
B 的状态栏立刻告诉你 —— 不用来回切窗口看。

```
  ● agentA ✓          ← 窗口徽章：这个窗口的 agent 做完了
                     🔔2   ← 全局计数：全机器还有 2 件事等着你
  [agentA] 完成: 重构完成，抽出了 core.sh   ← 瞬时提示（5 秒后消失）
```

## 功能特性

- **推送而非轮询**：agent 通过 hook 主动上报状态，tmux 不去 `capture-pane` 猜提示符 —— 没有扫描成本，也没有误报
- **完成与等待分得开**：`done`（做完了）、`wait`（等你批准）、`error`（回合被 API 错误中断）、`running`（在跑）四态各自独立上报，这是「有输出变了」「猜提示符」这类做法原理上分辨不了的
- **跨 session 且粘性**：通知出现在你正看着的那个 session，一直保留到你切进去处理完
- **六个独立信号**：窗口徽章、全局计数 `🔔N`、边框变色、边框状态行、瞬时提示、桌面通知，各管各的，可单独关闭
- **任何 agent 都能接入**：Claude Code 装上 hooks 即用；别的 agent 直接在脚本里调 `tmux-whistle done` 就行；另有关键词兜底检测（可选，默认关）
- **零运行时依赖**：只用 tmux 自身能力，兼容 oh-my-tmux 与 tpm / tpack

详见 [使用](#使用)、[配置](#配置)、[兼容性](#兼容性)。

## 为什么不是 monitor-activity

| | monitor-activity | tmux-notify | tmux-whistle |
|---|---|---|---|
| 知道"完成"和"等你在批"是两件事 | ✗ | ✗ | ✓ |
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
边框、瞬时提示、`prefix + W` 菜单随即就位。

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
3. 往 `~/.config/tmux/tmux.conf.local` 追加一段带 marker 的配置块
4. 幂等地把 Claude Code hooks 合并进 `~/.claude/settings.json`

先看它会改什么：`./install.sh --dry-run`。卸载：`./install.sh --uninstall`。

> **两条路别混用。** `install.sh` 会往 `tmux.conf.local` 写一行加载插件的命令；
> 如果 tpm 也装了同一个插件，就会加载两份、互相覆盖 `@whistle_root`。选一条即可。

装完重载 tmux：

```sh
tmux source-file ~/.config/tmux/tmux.conf    # 或 prefix + r
tmux-whistle doctor
```

> **升级插件后要重跑一次 `tmux-whistle install-hooks`。** hooks 是快照式写进
> `settings.json` 的，新增的事件（`StopFailure` / `SessionEnd`）不会自己出现 ——
> 不重跑的话 agent 因 API 错误中断时不会亮 `✗`，退出后 `●` 也不会自己灭。
> 该命令是幂等的，其它 hook 原样保留。

### macOS：系统通知授权（**必做**，否则系统通知静默失效）

```sh
osascript -e 'display notification "tmux-whistle 测试"'
```

没看到弹窗？去 **系统设置 → 通知 → Script Editor** 打开"允许通知"。
`osascript` 的通知是通过系统的 Script Editor 路由的；未授权时它**静默失败，不报错**。
装了 `terminal-notifier` 的话会优先用它，没有这个问题。

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
| **行为** | | |
| `@whistle_self` | `off` | 是否也提示自己所在的 session |
| `@whistle_clear_on_focus` | `on` | 切进窗口自动清除 |
| `@whistle_display_ms` | `0` | 瞬时提示显示时长，`0` = 跟随 tmux 的 `display-time` |
| **外观** | | |
| `@whistle_color_done` | `#00af00` | 完成色 |
| `@whistle_color_wait` | `#af8700` | 等待色 |
| `@whistle_color_error` | `#d70000` | 错误色 |
| `@whistle_color_running` | `#5f87af` | 运行中色 |
| `@whistle_icon_pending` | `🔔` | 全局计数前面的图标 |
| `@whistle_icon_done` | `✓` | 完成符号 |
| `@whistle_icon_wait` | `◷` | 等待符号 |
| `@whistle_icon_error` | `✗` | 错误符号 |
| `@whistle_icon_running` | `●` | 运行中符号 |
| **调试** | | |
| `@whistle_debug` | `off` | 写调试日志到 `${TMPDIR:-/tmp}/tmux-whistle.log` |
| `@whistle_detect` | `off` | 关键词兜底检测（见下） |
| `@whistle_detect_interval` | `15` | 兜底检测的轮询间隔（秒） |
| `@whistle_detect_idle` | `180` | 输出静默多少秒判为完成 |

### 改完怎么生效

- 写在 `tmux.conf.local` 里 → `prefix + r` 重载
- 命令行临时改 → 立刻生效：

```tmux
set -g @whistle_badge off          # 关掉窗口徽章，只留全局计数
set -g @whistle_border off         # 关掉 pane 边框变色
set -g @whistle_self on            # 也提示自己所在的 session
set -g @whistle_color_done '#00af00'  # 改色
set -g @whistle_display_ms 3000    # 瞬时提示显示 3 秒
```

```tmux
# 换图标（默认 🔔 / ✓ / ◷ / ✗ / ●）
set -g @whistle_icon_pending '●'
set -g @whistle_icon_done    '★'
set -g @whistle_icon_wait    '⏸'
set -g @whistle_icon_error   '⚠'
set -g @whistle_icon_running '▶'

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
那种场景想看到提示，开 `@whistle_self on`，或者直接看窗口徽章 / `🔔N`。

### 徽章在 oh-my-tmux 里的位置

徽章走 oh-my-tmux 的官方扩展点 `tmux_conf_theme_window_status_format`，落在 powerline
芯片**内部**而不是外侧。没配这个扩展点的话，插件会自己 patch `window-status-format`
兜底 —— 效果一致。

---

## 使用

### 状态栏上会看到什么

三个独立信号，可以各自开关：

```
 1 claude.exe✓            ← ① 窗口徽章
      ●1 ✓1 ◷0 ✗0   🔔2  ← ② 四态汇总 + 全局待处理计数
 [claude.exe] 完成: 重构完成，抽出了 core.sh   ← ③ 瞬时提示（5 秒）
```

| 信号 | 位置 | 回答的问题 |
|---|---|---|
| **窗口徽章** | 该窗口**所属 session** 的窗口列表 | 这个窗口的 agent 现在什么状态 |
| **四态汇总** `●1 ✓1 ◷0 ✗0` | `status-right`，**每个 session 都显示** | 全机器四种状态各有多少（`●` 在跑 / `✓` 完成 / `◷` 等待 / `✗` 失败） |
| **全局计数** `🔔N` | `status-right`，紧跟在汇总后面 | 总共还有几件事等着我处理 |
| **瞬时提示** | 状态栏消息行 | 刚刚具体发生了什么 |

汇总段只在真有 agent 活动（`●` 或 `🔔` 非零）时出现；四个格子一起出现、
**计数为 0 的也保留**，这样状态栏宽度不会随计数跳动。

跨 session 时只有 status-right 上那几项和瞬时提示可见 —— 你在 B 的窗口列表里
看不到 A 的窗口。所以汇总和计数才是"别处有事"的常驻信号，窗口徽章是"这个
session 里的细节"。

还有一个可选的第 4 个信号：`@whistle_border_status top` 会在**每个 pane 的边框上**
显示该 pane 自己的状态符号。同一窗口切了多个 pane 时特别有用 —— 一眼看出是哪个 pane 在等你。
默认关，因为它会占掉每个 pane 顶部一行。

### 状态与符号

| 状态 | 徽章 | 计入 🔔 | 什么时候出现 |
|---|---|---|---|
| `running` | `●` | 否 | agent 开始干活 |
| `done` | `✓` | 是 | 一轮工作结束 |
| `wait` | `◷` | 是 | 等你批准 / 等你输入 |
| `error` | `✗` | 是 | 回合因 API 错误结束（限流 / 过载 / 认证失败 …） |

`running` 不计入 `🔔N`，也不发瞬时提示与桌面通知 —— 每敲一次 prompt 就朝所有
session 推一条「运行中」纯属噪声。它只是让窗口列表能看出「这个窗口有 agent 在跑」，
agent 退出（`SessionEnd`）时自动熄灭。

### 怎么响应

| 操作 | 效果 |
|---|---|
| **`prefix + W`** | 弹出 agent 菜单：待处理项带编号，按数字键选中 → 跳过去并清除；运行中的项灰显、不可选，只用来告诉你「哪些窗口有 agent」 |
| **直接切进那个窗口** | 徽章自动消失（已读 = 焦点进入，不需要额外确认） |
| `prefix + W` 之外还想要列表 | `tmux-whistle list`（只看待处理，含消息与已存在时长） |
| 都不想做 | `tmux-whistle clear -a` 全清 |

**典型流程**：在 B 看到 🔔2 → `prefix + W` → 按 `1` → 落到 A 的那个窗口，徽章自己消失。

### 场景一：Claude Code —— 装上就能用，无需任何操作

hooks 装好后自动工作：

| 你做了什么 | agent 的反应 | 状态栏 |
|---|---|---|
| 发一条 prompt | — | `●`，不计入 🔔 |
| agent 跑完一轮 | `Stop` hook | `✓` + 🔔 + 提示 |
| agent 要你批准工具调用 | `Notification/permission_prompt` | `◷` + 🔔 + 提示 |
| 回合因 API 错误中断 | `StopFailure` hook | `✗` + 🔔 + 提示（消息就是错误文本） |
| 退出 Claude Code | `SessionEnd` hook | `●` 熄灭（`✓`/`◷`/`✗` 保留，等你处理） |

### 场景二：任何 agent / 脚本

不需要 Claude Code，在 tmux 的 pane 里直接调：

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
tmux-whistle running               # 开始干活（亮 ●，不计入 🔔）

tmux-whistle list                  # 看所有待处理项
tmux-whistle menu                  # = prefix + W
tmux-whistle jump other:api        # 跳到 session:window 并清除
tmux-whistle clear                 # 清当前窗口
tmux-whistle clear -a              # 全清
tmux-whistle on | off              # 总开关
tmux-whistle doctor                # 自检
```

不给 `-t` 时默认作用于当前 pane（`$TMUX_PANE`）；也支持 `-t %3` / `-t other:api`。
**选项和消息的顺序随意** —— `done -t %3 "消息"` 与 `done "消息" -t %3` 等价。
消息本身以 `-` 开头时用 `--` 隔开。

---

## 桌面通知（可选，默认关）

开了之后离开 tmux 也能收到：

```sh
osascript -e 'display notification "test"'    # ① 先测，必须看到弹窗
#  没弹窗 → 系统设置 → 通知 → Script Editor → 允许通知
```

```tmux
set -g @whistle_os on                          # ② 确认能弹窗后再开
```

不先授权就开，它会**静默失败** —— 你以为开了，其实什么都收不到。

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
tmux-whistle list                    # 状态确实写进去了吗
```

还查不出来就开调试日志：

```tmux
set -g @whistle_debug on
# 日志写到 ${TMPDIR:-/tmp}/tmux-whistle.log
```

## 文档

- [开发文档](docs/development.md) —— 本地开发、测试、目录结构、贡献
- [功能待办](docs/todo.md) —— 已知问题与限制
- [需求分析](docs/requirements-analysis.md) —— 需求来源与竞品调研
- [设计方案评审](docs/notify-design-review.md) —— 「事件收件箱」形态的取舍与吸收路线
