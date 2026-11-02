# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目一句话

tmux 插件：让 agent（Claude Code 或任何脚本）把状态**推**给 tmux，跨 session 显示在状态栏上。
「我做完了」和「我在等你」由 agent 自己上报 —— tmux 层面不猜、不轮询。

## 开发命令

```sh
make help             # 列出全部目标
make deps             # 装 bats-core / shellcheck / shfmt
make lint             # ShellCheck
make fmt              # shfmt 原地格式化
make fmt-check        # 格式检查（CI 用）
make test-unit        # L1 纯函数单测，不碰 tmux
make test-integration # L2/L3，隔离 socket
make check            # 提交前跑这条 = lint + fmt-check + 全部测试
make install / uninstall / doctor / clean
```

单文件 / 单个用例：

```sh
bats test/integration/badge.bats
bats -f 'menu-args' test/integration/cli.bats   # 按用例名正则过滤
```

改代码 → `make fmt` → `make check` → 提交。当前 486 项测试（87 单测 + 338 集成 + 61 e2e）。

## 架构：分层与唯一写入点

```
L4 生产者   hooks/claude-code.sh   Claude Code hook 推送（主路径，async:true）
            lib/detect.sh          关键词兜底轮询（默认关，会误报）
                        │ 调 bin/tmux-whistle
                        ▼
L3 状态机   lib/core.sh            ★ 唯一状态写入点
                        │ 只读
                        ▼
L2 渲染     lib/status-line.sh     徽章 format 生成 + 幂等注入
            lib/deliver.sh         四渠道投递（边框 / 边框状态行 / 瞬时提示 / 桌面通知）
                        ▼
L1 存储     tmux user option（tmux server 内存，不落盘、不跨 tmux 重启）

旁路        lib/spin.sh            Braille 帧推进器（只在有 running 时活着）
```

**状态存储约定**

状态分成**两条正交通道**：活动通道（这个 pane 里有没有 agent 在干活）与通知通道
（有没有事等你）。一个 pane 可以同时命中两条 —— 所以 pane 级有**两个**真源。

| 作用域 | option | 性质 |
|---|---|---|
| pane | `@whistle` `@whistle_msg` `@whistle_at` `@whistle_src` `@whistle_body` | **活动通道真源**，只有这里能写 |
| pane | `@whistle_notice` `@whistle_notice_msg` `@whistle_notice_at` `@whistle_notice_body` | **通知通道真源**，只有这里能写 |
| pane | `@whistle_sub` | 子 agent 标记，存的是**过期时间戳**（epoch 秒），空 = 无 |
| pane | `@whistle_eff` | 派生：该 pane 的有效态（供 pane 徽章 format 读） |
| window | `@whistle_win` `@whistle_win_msg` `@whistle_win_count` `@whistle_win_pane` | 派生，由 `whistle_recompute_window` 重算 |
| window | `@whistle_win_notice` `@whistle_win_notice_msg` | 派生：窗口通知态与消息 |
| global | `@whistle_pending` `@whistle_count_*` `@whistle_mark` `@whistle_status_right` `@whistle_pane_mark` `@whistle_spin_char` | 派生 / format 串 |

- 活动通道取值：`running` / `idle` / `gone` / 未设置。
- 通知通道取值：`done` / `wait` / `error` / 未设置。
- **有效态** = 两者按 rank 取高者（`error 5 > wait 4 > done 3 > running 2 > idle 1`）。
  窗口徽章、pane 徽章、边框、`whistle_deliver` 都按有效态走。
- 汇总段 `▶N ◉N ◆N ◔N ⚠N`：`▶/◉` 数**活动**通道，`◆/◔/⚠` 数**通知**通道，
  **两组互不排斥**（同一个 pane 可以既在 `count_running` 又在 `count_done` 里）。
  整段是否显示的判据仍是 `running || idle || pending` —— `@whistle_pending`
  就是通知总数，所以那个判据段逐字成立，**不要为双通道去加深 format 嵌套**。

`@whistle_body` / `@whistle_notice_body` 是「完整正文」（上限 400），
`@whistle_msg` / `@whistle_notice_msg` 是「徽章上显示的短标题」（上限 80）。
后者被截断就永久丢失，所以前者单独存一份。

**徽章必须是纯 tmux format，一个进程都不 fork。** 状态栏每 `status-interval` 重算一次，
写成 gpakosz 那种 shell function 就会每次刷新都 fork 一个 `sh -c`。整段徽章串存进 global
option `@whistle_mark`，用户配置里只写 `#{E:@whistle_mark}` 占位符 —— 改色只需重跑
publish，不用重载 tmux 配置。

**投递编排**在 `lib/deliver.sh` 的 `whistle_deliver`：它先调 `whistle_ensure_status_line`
（自愈，见下），再依次走边框、边框状态行、状态栏刷新、瞬时提示扇出、桌面通知。
`cmd_set` 与 `cmd_run` 共用 `whistle_finish`（重算 + 投递）—— 复制两份必然分叉。

**CLI 表面**：`done|wait|error`（写**通知通道**）、`running|idle`（写**活动通道**），
都可以带 `--title` / `--body`；`run -- 命令`（开始置活动 `running`，结束置活动
`idle` + 通知 `done`/`error`，带耗时）、`clear` / `list` / `menu` / `jump`（只碰通知通道）/
`on|off` / `doctor` / `install-hooks`。菜单键是 `prefix + n`。
hook 专用、不进用户语法的内部子命令：`--activity <running|idle|gone>`、
`--notice <done|wait|error>`、`--sub-agent-start`、`--sub-agent-stop`。
菜单项格式是 `图标 状态 [session]: 窗口 消息` —— session 名用 `[]` 裹住，
和窗口名、agent 的话分开（`whistle_menu_item_label` 是唯一定义处，
`cmd_menu` 与 `cmd_menu_args` 共用它）。

**图标与颜色**（都可配，见 `WHISTLE_DEFAULTS`）：`◆` 完成（紫 `#af5fff`）、`◔` 等待、
`⚠` 错误、`▶` 运行中（绿 `#00af00`）、`◉` 空闲（灰 `#8a8a8a`）、`⚑` 待处理总数（青 `#5fd7d7`）。
菜单里每项都带对应图标，且与状态栏语义一致：`▶` = 在跑、`◉` = 空闲。

## 不变量（改代码前必须知道）

**POSIX sh 约束**（目标 shell 是 macOS 的 `/bin/sh`）

- **没有局部变量**。函数里的临时变量会覆盖调用方的同名变量 —— 所有临时变量必须带命名空间
  前缀（`_ws` / `_l*` / `_p*` / `_c*` / `_d*` / `_sf*` / `_snc*`）。历史上这条静默覆盖过 session 名。
- 禁用 `[[ ]]`、数组、`local -n`、`mapfile`、`$'...'`。
- `$var` 后面紧跟中文/全角字符必须写 `${var}`，否则 bash 会把字节吞进变量名。
  踩过：漏了花括号 → 全角逗号被吞掉一个字节 → 字符串成了非法 UTF-8 → `tr` 报
  `Illegal byte sequence` 并把消息截断，而报错完全指不到真因。

**tmux 调用**

- `tmux show` **必须带 `-v`**，否则读回的是 `名称 "值"` 整行，写回去会毁掉用户状态栏。
  global option 用 `show -gv`。
- **pane 与 window 不能用同名 user option** —— 会影子遮蔽：清掉 pane 的 `@whistle` 后
  查找回退到 window 的聚合值，pane 看起来"清不掉"。
- **`run-shell` 会阻塞 tmux 命令队列**，绝不能排在 `\;` 链中间。状态写入与聚合只用
  `set` / `setw` / `show` / `list-panes`。
- **`run-shell` 拉起的子进程继承的是 tmux server 的环境**，不是调用方进程的。
  调用方 `export` 的 `WHISTLE_TMUX_SOCKET` 传不进去 —— 要把 socket 显式拼进
  `run-shell` 的命令串里（`lib/spin.sh` 就靠这个才连得到本 server）。
- **`set-hook` 必须用命名 array key**（`after-select-window[whistle]`）。不带 key 会清空整个
  数组顶掉别的插件；用 `-a` 又会在重复 source 时越加越多。
- **`display-menu` 的第三参是 tmux 命令，不是 shell 命令**。要调外部程序必须包在
  `run-shell -b '...'` 里，否则 tmux 会把路径当命令名 → `Unknown command: <path>`。
  从 shell 调 tmux 时 `\;` 的反斜杠会被 shell 吃掉，要写 `'\;'` —— 否则 tmux 收到裸 `;`
  当成命令分隔符，后半段会被立刻执行掉而不是进 binding。
- **socket 定位优先级**：`$WHISTLE_TMUX_SOCKET` > `$TMUX` > `$TMUX_SOCKET`。`$TMUX_SOCKET`
  会被子进程跨 server 继承，可能指向用户正在用的另一个 server；`$TMUX` 才是 tmux 按 server
  写好的权威值。加载时还要把 `#{socket_path}` 显式钉死传给 `scripts/setup.sh`。
- 嵌套 `#{?...}` 条件式的大括号必须配平。畸形 format 会被 tmux **静默渲染成空字符串**，
  不报错 —— 有配平单测守着。

**option 命名**

- **用户可配的开关**与**插件自己写的状态**必须用不同的 option 名。
  `@whistle_spin`（开关）与 `@whistle_spin_frame`（帧号）曾经撞成一个名字：插件在
  「没有 running」时把帧号写进开关，等于把开关自己置 0，此后永远读不到 `on`，
  动画被**永久判成关** —— 界面上只表现为退回默认图标，看不出任何异常。
- 派生值不要进 `WHISTLE_DEFAULTS`（那是用户可配的表）；表里只放用户能改的。

**同步逻辑**

- **只在「状态变化」时触发的同步逻辑，必须在加载路径上也跑一次。**
  `whistle_deliver` 只在状态变化时执行；一个「早就处于某状态、之后没人动过」的场景
  不会再有 deliver。`scripts/setup.sh` 因此也要调 `whistle_recompute_global`。
- **同步逻辑要挂在「唯一改那个值的地方」**，不是挂在各个调用方。挂在调用方就会漏：
  `--recompute`（由 `pane-exited` / `window-pane-changed` 钩子调用）只重算计数、
  不走 deliver，于是「running 归零时停掉的推进器」在计数回升后没人拉起，
  状态栏与菜单的帧一起冻住。`whistle_recompute_global` 末尾调 `whistle_spin_sync`
  就是为了这个 —— 那是唯一改 `@whistle_count_running` 的地方。

**自愈机制不要删**：`whistle_ensure_status_line()`（在 `lib/deliver.sh` 的
`whistle_deliver` 开头调用）是唯一不依赖加载顺序的补丁时机。oh-my-tmux 在 source 完
`tmux.conf.local` **之后**才重算主题并重设 `status-right` / `window-status-format`，
会覆盖早先打的补丁；固定延迟是竞态。

`scripts/setup.sh` 里还会**重绑一次菜单键**：用户自己的 `tmux.conf` 里可能有
`unbind n`（干掉 tmux 默认的 next-window 是常见做法），而它排在 `tmux.conf.local`
之后执行，会把插件的绑定解掉。setup.sh 是 `run-shell -d 0.5` 之后跑的，
那时整份配置已加载完，重绑即可。**用户的 `tmux.conf.local` 里任何一行非法命令都会
让整份配置加载失败**（`source-file` 返回 1），症状是「按键没反应」。

**绝不覆盖别人的东西**：`lib/install-hooks.sh` 往 `~/.claude/settings.json` 合并时只增删
带 `tmux-whistle` marker 的条目，用户已有的 hook 原样保留；改前先备份。

**SessionEnd hook 必须同步（不加 `async`）**：Claude Code 退出时会带走后台子进程，
异步的清除可能被杀在半路，留下一个永远灭不掉的 `▶`。其余 hook 都是 `async: true`，
只有这一个例外，`our_entry()` 里按事件名判断。

**`running` 只能由 `UserPromptSubmit` 点亮，`SessionStart` 报的是 `idle`**：
`SessionStart` 不代表 agent 在干活 —— `--continue` / `--resume` 恢复出来的、以及刚敲
`claude` 起的新会话，都只是在提示符前**等着**。早先把它映射成 `running`，配上
resurrect 的 `@continuum-restore` 就是「恢复 3 个会话 → 状态栏亮 `▶3`，一个都没在跑」。
现在映射成 `idle`（`source=compact` 除外 —— 那是轮中压缩，agent 还在干活，原样不动）。

**活动与通知是两条正交通道，永远不会互相顶掉**：`@whistle`（活动）与
`@whistle_notice`（通知）是两个独立状态槽，写入点也分开
（`whistle_activity_set` / `whistle_notice_set`）。这条不是可有可无的洁癖 ——
早先只有一个槽时，「后台 agent 完成」这条通知会把主 agent 的 `running` 顶掉，
用户读掉通知后整格被清空、再被「按进程发现」判成 `idle`，一个**正在干活**的
agent 显示成「空闲」，**全程零报错**。新增任何一种「要告诉你的事」都写通知通道，
**不要往活动通道挤**。

**已读路径只清通知通道，绝不动活动通道**：`whistle_clear_window` /
`whistle_clear_all` / `whistle_read_window` / `whistle_read_pane` 只清
`@whistle_notice*`。「切进窗口 = 已读」只该表示「那件事我看过了」，不该顺手
把「它还在干活」这件事也抹掉 —— 抹掉之后没有任何事件会把它点回来。
⚠️ 这四个函数的判据入口横跨 `lib/core.sh` 与 `lib/status-line.sh` 两个文件，
改的时候两边都要找一遍（`bin/tmux-whistle` 的 `cmd_read_pane` 里还有第三个判据）。

**`running` 的含义是「这个 pane 里有任何 agent 在干活」**，不只是主 agent 的一轮：
子 agent / 后台 agent 存活也算（`@whistle_sub` 标记 + 推导层覆盖），
`PreToolUse` 也会点亮它 —— 后者顺带覆盖了 plan mode「批准后 agent 继续跑、
但没有新的 `UserPromptSubmit`」那条路。

**`◉` 不再表示「零个在跑」**：`@whistle_count_idle` 是独立计数，汇总里 `▶N ◉N`
两格并存。整段的显示判据必须同时看 running / idle / pending 三个 —— 漏掉 idle 的话
「三个 agent 全空闲」会被判成没活动而整段隐藏，而那一格正是恢复 tmux 后最想看到的。
`▶/◉` 与 `◆/◔/⚠` 两组**互不排斥**：同一个 pane 可以既在 `count_running` 又在
`count_done` 里。整段是否隐藏的判据仍写 `running || idle || pending` ——
`@whistle_pending` 就是通知总数，所以那个 format 段逐字成立，**别为双通道去加深嵌套**。

**「空闲」有两个来源**：hook 在 `SessionStart` 报 idle，以及**按进程发现** ——
`whistle_resolve_idle_panes`（纯函数）把「没上报状态、但前台跑着
`@whistle_agent_cmds` 里那些进程」的 pane 推导成 idle。推导发生在纯函数之前，
窗口徽章、全局计数、菜单三处因此口径一致。
判据是 tmux 自己的事实（这个 pane 的前台跑着谁），不是从屏幕文字里猜提示符。

**`@whistle_sub` 存的是过期时间戳，不是布尔**：`PreToolUse`(Agent/Task) 写
`now + @whistle_sub_ttl`，`SubagentStop` / `Notification(agent_completed)` 清空。
过期由推导层按时间戳判断（**不需要写回**）。这是防「标记泄漏 → 永久亮 `▶`」的
安全阀：宁可漏报 `running`（回到旧行为），不可永久误报。让过期真正落地的是
`lib/spin.sh` 每 `@whistle_recompute_every` 帧触发的一次全局重算 ——
挂在推进器上不是偶然，它**只在 `count_running > 0` 时活着**，恰好就是需要自愈的场景。

**带 `|` 的行要按固定列数读**：POSIX 的 `read` 在字段数多于变量数时，会把余下的
（含分隔符）全塞进**最后一个**变量。所以「消息」必须在**末位**（它拿到的是余下的
全部，消息里带 `|` 也不会被截断），而**中间不能多留列** —— 多留一列，
消息列就变成「消息|进程名」，而 `@whistle_win_msg` 与菜单标签会把它原样显示出去。
`whistle_resolve_idle_panes` 因此**把命令列整列去掉**再往下传，输出的列布局是
`<前导列> | pane_id | 有效态 | 通知态 | 活动态 | 消息`（消息在末位）；
`whistle_aggregate` 只读 **5** 个变量，菜单那侧读 **9** 个 —— 改列数时两边都要跟着改。

**`gone` 不是用户能报的状态**：只有 `SessionEnd` 会写它（`whistle_forget_agent`）。
它解决的是一个具体竞态：钩子跑的时候 agent 进程**还没退出**，
`pane_current_command` 仍是 claude —— 那时若把状态清空，紧接着的重算会按
「前台跑着 agent」又把它认成空闲，留下一盏灭不掉的 `◉`。写成 `gone` 就绕开了。
`gone` 的 rank 是 0：徽章不显示、计数不涨、菜单不列。

**消息消毒**：任何进入 tmux format 的文本都要过 `whistle_sanitize` —— 剔掉 `# { } |`
与控制字符，截断 80 字符。否则 `#{` 会被二次展开、`}` 会截断条件式。
**例外：插件自己生成的 format 片段不过消毒** —— 例如 `whistle_spin_build` 的帧选择器，
消毒会把 `#{}` 剔掉、整个 format 变成空串（tmux 静默渲染成空白）。

## 动画帧的设计要点

状态栏 running 那一格用 Braille 点阵转（`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`，默认 0.5 秒一帧）。

**插件把「当前帧字符本身」写进 `@whistle_spin_char`，format 里只写
`#{@whistle_spin_char}`，一层都不嵌套。** 早先的版本存帧号、再用 N 层嵌套条件式把
帧号翻成字符 —— 4 帧还勉强，10 帧就要嵌 9 层，大括号必然配错，而配错了 tmux
只会静默渲染成空字符串。存字符而不是序号，帧数随便加。

`lib/spin.sh` 是独立的推进器进程：只在真有 running 时被 `run-shell -b` 拉起，
running 归零时下一轮循环 break 并清掉自己那份 PID 记录，不常驻。

**推进器的 PID 记在目标 server 自己的 option（`@whistle_spin_pid`）里，不是磁盘
pidfile。** 早先的 pidfile 路径按用户命名、**不含 socket** —— 用户的真 server 与
测试的隔离 server 共用一份，于是隔离 server 的 `whistle_spin_stop` 会把**用户真
server 的推进器 kill 掉**，用户那边下一次重算又拉起来：状态栏汇总格反复重画，
CPU 跟着抖（2026-11-02 实测）。凡是「按 server 隔离」的状态，一律放进 server
自己的 option，别落按用户命名的文件。

**杀 / 认推进器之前先确认那确实是推进器**（`whistle_spin_alive`）：推进器被 SIGKILL 后
option 里的 PID 会残留，OS 复用 PID 之后 `kill -0` 对一个**无关进程**也会成功 ——
裸 `kill` 会误伤别人，裸 `kill -0` 守卫又会让动画再也不转。所以 `whistle_spin_stop` /
`whistle_spin_ensure` / `lib/spin.sh` 的守卫都要过 `ps` 确认命令行里是 `spin.sh`。

**帧外面必须再套一层「有没有 running」的判断**：推进器退出后 `@whistle_spin_char`
还留着最后一帧，不判计数的话状态栏会一直挂着 `⠋ 0` —— 动画早停了、字形还在，
看起来像卡死。所以 `whistle_summary_build` 里 running 那格是
`#{?#{@whistle_count_running},<帧选择器>,<静态图标>}`，归零退回 `▶`。

**菜单是自绘 popup，会自己刷新**（`lib/menu.sh` 的 `whistle_menu_ui` 每约 0.5 秒
重读一次模型，变了才重绘；列表重排后高亮按 window id 跟随原来那个窗口）。
因此菜单里的 running 项仍用固定的 `▶` 而非 Braille 帧 —— 一直在变的帧在列表里
读不出来，看着像渲染错乱。

**菜单只用 Esc 退出**（`q` 是第 26 项的普通快捷键，未分配时不执行操作）：
方向键的 `Esc [ A/B` 序列不能被当成单独 Esc 拆开。

**菜单只有「模型变了」才整帧重绘；方向键移动只重画旧行与新行**
（`whistle_menu_paint_row`）。整帧重绘会清屏并把每一行重新 clip，26 项就是 26 个
awk 子进程 —— 每按一次方向键都重来一遍，慢终端上肉眼可见地卡。

**`j` / `k` 在没被分配成快捷键时上下移动**（≤18 项时 `j`、≤19 项时 `k`）；
一旦这两项确实分到了 `j` / `k` 快捷键就照旧跳转 —— 同一个键在同一份列表里只做一件事。
`q` 不参与退出，理由见上。

**菜单首帧只调一次 tmux 取配置**（`whistle_menu_palette` → `whistle_conf_bulk`，
一次 `show -g` 拿齐五态图标与颜色）。逐项 `whistle_conf` 是 10 次进程，popup 打开
时的延迟几乎全在这里；调色板整个菜单生命周期取一次，行内重绘直接查表、不调 tmux。

## 测试约定

三层，越往下越慢：

| 层 | 目录 | 依赖 | 目标 |
|---|---|---|---|
| L1 | `test/unit/` | 无（不碰 tmux） | `whistle_sanitize` / `whistle_rank` / `whistle_aggregate` / `whistle_count_states` / 帧表 |
| L2 | `test/integration/` | `tmux -L` 隔离 socket | 渲染、注入幂等、边框可还原、hooks、CLI |
| L3 | `test/e2e/` | 隔离 server + 构造的 hook JSON | `bin/tmux-whistle` 与 `hooks/claude-code.sh` 完整链路 |

`lib/core.sh` 里 `whistle_sanitize` / `whistle_rank` / `whistle_aggregate` /
`whistle_count_states` 四个函数**不得出现任何 tmux 调用** —— 这是 L1 单测能脱离 tmux 跑的前提。

helper（`test/test_helper/whistle.bash`）的约定：

- 每个测试文件一个独立 socket（`tmux -L whistle-test-$$`），用 `-f /dev/null` 起 server，
  绝不读用户真实的 `tmux.conf`。
- **绝不在 helper 里装 `trap ... EXIT`** —— 会覆盖 bats 自己的 trap，静默吞掉测试失败
  （表现是 `Executed N instead of expected M`，而不是 `not ok`）。清理交给 `teardown()`。
- `teardown` 必须 kill-server **并显式删掉 socket 文件**（`kill-server` 不总会 unlink，
  反复跑会攒出几百个残留）。
- **残留的隔离 server 不只是攒文件**：tmux-continuum 把「存在第二个 tmux server」
  当成「另一个环境在跑」，于是**静默关闭自动恢复与自动保存** —— 用户重启 tmux 后
  会话恢复不出来，而界面上完全看不出原因（踩过，见 `docs/todo.md` 的 TODO-20）。
  两道防线：`wt_start` 会先清掉「owner 已死」的残留 socket（`wt_reap_stale_sockets`）；
  `make check` 末尾的 `check-no-stray-servers` 断言跑完没有 `whistle-test-*` 活着。
  **用 `pkill` 杀 bats 会让 `teardown` 跑不到**，那之后务必看一眼这个断言。
  `tmux-whistle doctor` 也会报「本机还有别的 tmux server」。
- `display -pF` 不解析 `#[...]` 样式，断言前要剥掉（helper 的 `wt_render_windows` 已处理）。
- hook 走 `run-shell -b` 是异步的，断言前用 `wt_wait_until` 轮询，别 sleep 一下就假定好了。
- **`optw` 读的是 global option**（实现是 `show -gwv`）。要读 window 级 option 得用
  `wt show -wv -t "$w" <name>`；`optp` 要两个参数（option 名 + pane id）。
  读错作用域会让断言静默读空、测试假绿。
- `bin/tmux-whistle` 的 `cmd_menu` 与 `cmd_menu_args` 是两份几乎相同的循环，
  后者只为让测试能在无 attached client 时断言 argv。**改一边不改另一边 = 假绿**。

## 风格

- 注释与用户可见文案一律中文；代码标识符英文。
- `shfmt` 按方言分两次调用（`-ln=posix` 给 `bin/ lib/ hooks/ install.sh`，`-ln=bash` 给
  `test/**/*.bash`）。**`.bats` 不是合法 bash，shfmt 解析不了**，格式化与格式检查都排除，
  这些文件靠 review 保证风格。
- ShellCheck 用 `shell=sh` 定向 POSIX 检查 —— `[[ ]]` 之类会直接报错，这是 KP-14 的兜底。
- `.shellcheckrc` 的 directive 不接受 `=` 两侧的空格（带空格会报 SC1134）。

## 安装布局与入口链路

入口链路：`tmux-whistle.tmux`（tpm 把 `*.tmux` 当**可执行文件**跑，不是 source）
→ `.tmux-whistle.conf`（bind `prefix + n` + `run-shell -b -d 0.5` 调 setup）
→ `scripts/setup.sh`（发布 mark、幂等 patch、注册读侧 hooks、清理残留边框）。

- 本地安装落在 `~/.local/share/tmux-whistle`（符号链接到仓库），**不放进
  `~/.config/tmux/plugins/`** —— tpm 的 `clean_plugins` 会删掉没有 `@plugin` 声明的目录。
- CLI 符号链接到 `~/.local/bin/tmux-whistle`；`bin/tmux-whistle` 自己循环解析符号链接再定位
  `lib/`（macOS 的 `readlink` 没有 `-f`）。
- `install.sh` 只往 `tmux.conf.local` 追加一段带 marker 的块，卸载用 `--uninstall`。
- 读侧 tmux hooks 只负责「已读 = 焦点进入」与聚合重算；**推送侧不碰 tmux hooks** ——
  tmux 没有能表达"agent 做完了"的事件。

## 延伸资料

- **开发文档**：`docs/development.md` —— 仓库内的开发指南（命令、目录结构、红线、测试约定）。
  README 只面向使用者，不写开发内容。
- **功能待办**：`docs/todo.md` —— 已知问题与限制，含现象 / 触发方式 / 原因。
- **设计方案评审**：`docs/notify-design-review.md` —— 「事件收件箱」形态（事件溯源 +
  SQLite + Python TUI）的取舍分析，说明为什么只吸收模型、不换技术栈。
- 需求来源：`docs/requirements-analysis.md`
- 使用说明：`README.md`
- 设计记录（含时序图、API 映射、16 个技术点、实施记录与踩过的坑）在本机的 plan 文件里，
  **不在仓库内**：`/Users/rich1e/.claude/plans/tmux-tmux-session-session-agent-a-partitioned-wadler.md`
