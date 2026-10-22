# tmux-whistle

在 tmux 里跨 session 接收 agent 状态通知：**工作完成** / **等待下一步**。

你在 session A 跑 agent，在 session B 干别的事。A 做完了或者卡在等你批准，
B 的状态栏立刻告诉你 —— 不用来回切窗口看。

```
  ● agentA ✔          ← 窗口徽章：这个窗口的 agent 做完了
                     🔔2   ← 全局计数：全机器还有 2 件事等着你
  [agentA] 完成: 重构完成，抽出了 core.sh   ← 瞬时提示（5 秒后消失）
```

## 它和 monitor-activity / tmux-notify 有什么不同

| | monitor-activity | tmux-notify | tmux-whistle |
|---|---|---|---|
| 知道"完成"和"等你在批"是两件事 | ✗ | ✗ | ✓ |
| 检测方式 | 有输出变了 | 轮询猜提示符 | **agent 主动上报** |
| 消息内容 | 无 | 无 | 有（最后一条回复） |
| 跨 session 可见 | 只在窗口标签高亮 | 只弹系统通知 | 状态栏计数 + 瞬时提示 + 系统通知 |
| 粘性 | 有 | 无 | 有，直到你切进去 |

根本差别：**"我做完了"和"我在等你"是 agent 自己的判断**，tmux 层面看不到。
所以 tmux-whistle 不去猜，而是让 agent 通过 hook 主动告诉我们。

## 安装

### 用 tpm / tpack（推荐）

```tmux
# ~/.tmux.conf 或 ~/.config/tmux/tmux.conf.local
set -g @plugin 'rich1e/tmux-whistle'
```

然后 `prefix + I`。

### 本地开发

```sh
git clone <this repo> ~/code/tmux-whistle
cd ~/code/tmux-whistle
./install.sh          # 符号链接 + 写 tmux.conf.local + 装 Claude Code hooks
```

`install.sh` 只往 `tmux.conf.local` 追加一段带 marker 的配置，卸载用 `./install.sh --uninstall`。
先看会改什么：`./install.sh --dry-run`。

> 不要把它手动链接进 `~/.config/tmux/plugins/`：oh-my-tmux 重载时会跑 tpm 的
> `clean_plugins`，没有 `@plugin` 声明的目录会被**直接删掉**。

安装完：

```sh
tmux source-file ~/.config/tmux/tmux.conf    # 或 prefix + r
tmux-whistle doctor
```

### macOS 上额外一步（**必做**，否则系统通知静默失效）

```sh
osascript -e 'display notification "tmux-whistle 测试"'
```

没看到弹窗？去 **系统设置 → 通知 → Script Editor** 打开"允许通知"。
`osascript` 的通知是通过系统的 Script Editor 路由的；未授权时它**静默失败，不报错**。
装了 `terminal-notifier` 的话会优先用它，没有这个问题。

## 用法

### 你在状态栏上会看到什么

三个独立信号，可以各自开关：

```
 1 claude.exe✔            ← ① 窗口徽章
                   🔔2     ← ② 全局待处理计数
 [claude.exe] 完成: 重构完成，抽出了 core.sh   ← ③ 瞬时提示（5 秒）
```

| 信号 | 位置 | 回答的问题 |
|---|---|---|
| **窗口徽章** | 该窗口**所属 session** 的窗口列表 | 这个窗口的 agent 现在什么状态 |
| **全局计数** `🔔N` | `status-right`，**每个 session 都显示** | 全机器还有几件事等着我 |
| **瞬时提示** | 状态栏消息行 | 刚刚具体发生了什么 |

跨 session 时**只有 ② 和 ③ 可见** —— 你在 B 的窗口列表里看不到 A 的窗口。
所以 ② 才是"别处有事"的常驻信号，① 是"这个 session 里的细节"。

还有一个可选的第 4 个信号：`@whistle_border_status top` 会在**每个 pane 的边框上**
显示该 pane 自己的状态符号。同一窗口切了多个 pane 时特别有用 —— 一眼看出是哪个 pane 在等你。
默认关，因为它会占掉每个 pane 顶部一行。

### 状态与符号

| 状态 | 徽章 | 计入 🔔 | 什么时候出现 |
|---|---|---|---|
| `running` | 无 | 否 | agent 开始干活 |
| `done` | `✔` | 是 | 一轮工作结束 |
| `wait` | `⏳` | 是 | 等你批准 / 等你输入 |
| `error` | `✗` | 是 | 出错 |

`running` 刻意不显示徽章 —— agent 在跑的时候你不需要被打扰。

### 场景一：Claude Code —— 装上就能用，无需任何操作

hooks 装好后自动工作：

| 你做了什么 | agent 的反应 | 状态栏 |
|---|---|---|
| 发一条 prompt | — | `running`，无徽章 |
| agent 跑完一轮 | `Stop` hook | `✔` + 🔔 + 提示 |
| agent 要你批准工具调用 | `Notification/permission_prompt` | `⏳` + 🔔 + 提示 |

### 场景二：任何 agent / 脚本

不需要 Claude Code，在 tmux 的 pane 里直接调：

```sh
long_job.sh && tmux-whistle done "备份完成" || tmux-whistle error "备份失败"
```

或者从别人的 session 里主动求助：

```sh
tmux-whistle wait "需要你选数据库"
```

### 怎么响应

| 操作 | 效果 |
|---|---|
| **`prefix + W`** | 弹出待处理菜单，按数字键选中 → 跳过去并清除 |
| **直接切进那个窗口** | 徽章自动消失（已读 = 焦点进入，不需要额外确认） |
| `prefix + W` 之外还想要列表 | `tmux-whistle list`（含消息与已存在时长） |
| 都不想做 | `tmux-whistle clear -a` 全清 |

**典型流程**：在 B 看到 🔔2 → `prefix + W` → 按 `1` → 落到 A 的那个窗口，徽章自己消失。

### 命令速查

```sh
tmux-whistle done    "重构完成"     # 标记完成
tmux-whistle wait    "等你批准"     # 标记等待
tmux-whistle error   "构建失败"     # 标记出错
tmux-whistle running               # 开始干活（清掉之前的徽章）

tmux-whistle list                  # 看所有待处理项
tmux-whistle menu                  # = prefix + W
tmux-whistle jump other:api        # 跳到 session:window 并清除
tmux-whistle clear                 # 清当前窗口
tmux-whistle clear -a              # 全清
tmux-whistle on | off              # 总开关
tmux-whistle doctor                # 自检
```

不给 `-t` 时默认作用于当前 pane（`$TMUX_PANE`）；也支持 `-t %3` / `-t other:api`。

### 桌面通知（可选，默认关）

开了之后离开 tmux 也能收到：

```sh
osascript -e 'display notification "test"'    # ① 先测，必须看到弹窗
#  没弹窗 → 系统设置 → 通知 → Script Editor → 允许通知
```

```tmux
set -g @whistle_os on                          # ② 确认能弹窗后再开
```

不先授权就开，它会**静默失败** —— 你以为开了，其实什么都收不到。

### 调优

```tmux
set -g @whistle_badge   off          # 关掉窗口徽章，只留全局计数
set -g @whistle_border  off          # 关掉 pane 边框变色
set -g @whistle_self    on           # 也提示自己所在的 session
set -g @whistle_color_done '#00af00' # 改色
set -g @whistle_display_ms 3000      # 瞬时提示显示 3 秒
```

改完 `prefix + r` 生效，不用重启。

### 出问题时

```sh
tmux-whistle doctor                  # 逐项自检：版本 / 注入 / 渠道 / hooks / 失效绑定
tmux-whistle list                    # 状态确实写进去了吗
```

还查不出来就开调试日志：

```tmux
set -g @whistle_debug on
# 日志写到 ${TMPDIR:-/tmp}/tmux-whistle.log
```


## Claude Code 集成

`install-hooks` 会往 `~/.claude/settings.json` **追加**四条 hook（`async: true`，不阻塞 agent）：

| 事件 | 变成 | 消息来自 |
|---|---|---|
| `Stop` | `done`（工作完成） | `last_assistant_message` |
| `Notification` / `permission_prompt` | `wait`（等你批准） | `message` |
| `Notification` / `agent_needs_input` | `wait` | `message` |
| `Notification` / `agent_completed` | `done` | `message` |
| `UserPromptSubmit`、`SessionStart` | `running`（熄灭徽章） | — |

`auth_success` / `quota_*` / `plugin_notification` 等无关通知会被忽略，不会刷屏状态栏。

**你已有的 hooks 不会被覆盖** —— 合并前自动备份到 `settings.json.bak.<时间戳>`，
只增删带 `tmux-whistle` 标记的条目。

```sh
tmux-whistle install-hooks --dry-run    # 先看合并结果
tmux-whistle install-hooks --uninstall  # 精确摘除
```

## 配置

写在 tmux 里（`set -g ...`），或放进 `.tmux.conf.local`：

| option | 默认 | 说明 |
|---|---|---|
| `@whistle_enabled` | `on` | 总开关 |
| `@whistle_badge` | `on` | 窗口标签徽章 |
| `@whistle_border` | `on` | pane 边框变色 |
| `@whistle_border_status` | `off` | pane 边框状态行：`top` / `bottom`，分屏时按 pane 显示符号 |
| `@whistle_display` | `on` | 状态栏瞬时提示 |
| `@whistle_os` | `off` | 桌面系统通知 |
| `@whistle_self` | `off` | 是否也提示自己所在的 session |
| `@whistle_clear_on_focus` | `on` | 切进窗口自动清除 |
| `@whistle_color_done` | `#00af00` | 完成色 |
| `@whistle_color_wait` | `#af8700` | 等待色 |
| `@whistle_color_error` | `#d70000` | 错误色 |
| `@whistle_display_ms` | `0` | `0` = 跟随 tmux 的 `display-time` |
| `@whistle_debug` | `off` | 写调试日志到 `${TMPDIR:-/tmp}/tmux-whistle.log` |
| `@whistle_detect` | `off` | 关键词兜底检测（见下） |

改颜色后重跑 `scripts/setup.sh`（或 `prefix r`）即刻生效，不用重启。

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
source ~/.local/share/tmux-whistle/share/whistle.zsh    # 或插件目录下的 share/whistle.zsh
```

## 兼容性

- tmux **>= 3.2**（用到 `run-shell -b`、`refresh-client -S`）
- **oh-my-tmux**：徽章走官方扩展点 `tmux_conf_theme_window_status_format`，落在 powerline 芯片内部；
  没配的话插件会自己 patch `window-status-format` 兜底
- tpm / tpack：标准插件布局（`*.tmux` 入口）
- 运行时零第三方依赖；只有 `osascript` / `notify-send` / `terminal-notifier` 这些系统工具，缺失则静默跳过

## 开发

```sh
make deps     # 装 bats-core / shellcheck / shfmt
make check    # lint + 格式检查 + 全部测试
make fmt      # shfmt 格式化
```

测试全程在 `tmux -L whistle-test-*` 隔离 server 上跑，**不会碰你正在用的 tmux**。

```
lib/core.sh          状态机（唯一写入点，纯函数可单测）
lib/status-line.sh   徽章 format 生成 + 幂等注入
lib/deliver.sh       四渠道投递
lib/detect.sh        关键词兜底
hooks/claude-code.sh Claude Code hook 适配器
```

开发命令见 `make help`。

## 已知边界

- 状态存在 tmux server 内存里，**不跨 tmux 重启**。通知本就不该有陈旧残留。
- 不在 tmux 里运行时 hook 静默退出（没有状态栏可显示）。
- `osascript` 通知归属显示为 "Script Editor"，这是系统行为，不是 bug。
- 徽章的"已读清除"依赖 `after-select-window`。极端多 client 场景下由 tmux
  决定该 hook 的窗口上下文；测试覆盖了单 client 与"读别的窗口不影响本窗口"。
