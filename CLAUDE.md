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

改代码 → `make fmt` → `make check` → 提交。当前 502 项测试（89 单测 + 342 集成 + 71 e2e）。

## 架构：分层与唯一写入点

```
L4 生产者   hooks/claude-code.sh   Claude Code hook 推送（主路径，async:true）
            hooks/opencode/tui.js  OpenCode TUI 插件 → hooks/opencode.sh（第二个接入源）
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

**两个接入源的区别（不要照抄 Claude 那套）**

OpenCode 是「TUI 进程 + `opencode serve --service` 共享守护」双进程。**事件里没有任何
pane 信息**（99 个 V2 事件一个都没有），而 server 的环境是**启动快照** —— 所以：

- **pane 归属只能由 TUI 提供。** `$TMUX_PANE` 在 TUI 里可信，在 server 里是启动时的那个
  pane（所有 pane 的事件都汇进它）。按 `location.directory` 猜也不行：同目录下可能既有
  `opencode` 又有 `claude.exe`（实测）。
- `tui.js` **只做转发与身份过滤**，映射全在 `lib/opencode.sh`（纯函数，可被 L1 source）+
  `hooks/opencode.sh`（薄壳）。逻辑进 JS 就破了「`make check` 不需要 node」。
- 插件必须以**目录形态**软链（`~/.config/opencode/plugins/tmux-whistle` → `hooks/opencode`，
  链接名不带 `.js`）：单文件会被当成 server part，`plugins` 配置里的单文件路径会被官方
  静默跳过。`tui.js` 这个**文件名是契约**，改名就不被认成 TUI part。

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
`cmd_menu` 与 `cmd_menu_args` 共用它）。**菜单按 agent 列出，一个 pane 一条**；
同一窗口里有多个 agent 时，消息列末尾带 `·格N`（N 是该 pane 在窗口里的位置）
以便区分 —— 见「汇总数 pane，菜单也列 pane」那条不变量。

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

**OpenCode 侧：启动必须报 `idle`，事件必须串行**（2026-11-13 真机踩到）

- **TUI 启动要写一次 `idle`**（`hooks/opencode.sh --tui-start`）。上一轮退出的收尾是
  `gone`（rank 0：不显示、不计数、不进菜单），而推导层只把**空**状态推成 idle ——
  `gone` 不是空，救不回来。少了这一步，重启 TUI 后那个 pane 在状态栏上**彻底不存在**，
  用户会以为插件没装上。已有 `running`/`idle` 时不覆盖，否则插件热重载会把正在干活的
  状态打回空闲。
- **事件写入必须串行**（`tui.js` 用 promise 链，不 `detach`）。并发 spawn 时子进程完成
  顺序不保证：实测 `permission.asked`(wait) 与 `execution.succeeded`(done) 同时触发时，
  后到的 `done` 把 `◔` 盖成了 `◆`，等待提示闪一下就没了。状态写入是「后发生者赢」的
  有序语义，queue 不能省。
- **cleanup 要先 `await queue` 再写 `gone`**：否则退出会把排队中还没落盘的事件冲掉
  （实测最后那条 `succeeded` 的 `done` 会丢）。
- `session.execution.interrupted` **必须按 `reason` 分派**，不能一律 `idle`：
  `superseded` 意味着**正在跑新的一轮**（写 idle 会把 `▶` 打成 `◉`）；
  `shutdown` 要写 `gone`；只有 `user` / `inactivity` 才是 `idle`。
- `permission.replied` **必须按 `reply` 分派**：`once`/`always` 只清通知、活动态不动；
  `reject` 要把活动态收成 `idle` —— 拒绝会结束当前 step，之后**可能没有**
  `succeeded`/`failed` 来收尾，否则留一盏永不灭的 `▶`。
- 后台 shell 用「**在飞 id 集合**」（`@whistle_oc_shell`，存 pane option 不落盘），
  不用计数器：重复的 `started` 天然幂等，`ended` 按 id 精确移除。集合非空时不写 `done`。
- **订阅必须逐条 `try/catch`，失败的类型走 `data.listen` 兜底。** 一条 `data.on()` 抛
  异常会打断整个循环，后面的事件全收不到 —— 而探针写在循环**之前**，所以 `doctor`
  照样报「已加载」，看起来一切正常。2026-11-13 的现场就是这样：`@whistle=idle`
  （`--tui-start` 生效）、真实事件数 **0**。
- **`tabs.list()` 的元素形状不能假设是字符串。** 原实现 `new Set(list)` 把元素当
  `"ses_x"`，实际可能是 `{ sessionID }` 对象 —— `Set.has("ses_x")` 永远为假，于是
  **所有事件被身份过滤丢掉**，不报错、不留痕。要同时支持字符串与对象
  （取 `sessionID` / `id` / `session.id`），且**拿不到 id 时 fail-open**，
  绝不把「取不到」当成「一条都不属于我」。
- **诊断要能回答「订阅建立了几条」，而不只是「加载了没」。** 订阅结果带进
  `--probe`（`subs=N failed=...`），`doctor` 直接展示并在 `subs=0` 时报红；
  `--trace`（debug 开时才写）记录每个原始事件与丢弃原因
  （`no-sessionID` / `not-my-tab` / `tabs-shape-unknown`）。
  判据链是「探针证明加载 / subs 证明订阅 / trace 证明事件真的到了」——
  只看第一条会得出相反的结论。

**状态写入的成本（改热路径前先看）**

一次 `done` / `running` 的写入原本要 fork **80 次 tmux**，其中 58 次是读配置
（同一批图标/颜色被读 3~4 遍），另有 22 次 `whistle_sanitize`（每次约 22ms）。
2026-11-13 压到 **25 次**（CPU 1.7x、wall 2.2x）。四条优化各自都有前提，改错会静默失效：

- **配置快照必须在 CLI 入口读并 `export`**（`bin/tmux-whistle` 里一次 `show -g`）。
  不能在 `whistle_conf` 里惰性读 —— 所有调用点都写成 `$(whistle_conf ...)`，
  那是**子 shell**，在里面设的变量改不回父进程，惰性缓存等于没有缓存（实测仍是 58 次）。
  也不能在 source `lib/core.sh` 时读：L1 单测直接 source 它且不碰 tmux。
- **长驻进程必须 `WHISTLE_CONF_NO_CACHE=1`**：`lib/spin.sh` 靠每帧重读 `@whistle_spin_style`
  实现「换风格不用重启推进器」，`lib/detect.sh` 靠每轮重读 `@whistle_detect` 感知关闭。
  缓存了它们就永远用启动时的值。
- **快照必须剥引号**：`show -g`（全量）会给以 `#` 开头或含空格的值加引号，
  `show -gqv`（单项）不会。颜色与 `agent_cmds` 都中招，症状是徽章里出现
  `#[fg="#af5fff"]` —— 颜色不生效，而肉眼很难看出是引号造成的。
- **`whistle_sanitize` 有纯 shell 快路径**（干净短串直接返回）。判据是
  「含控制字符 / `#{}|` / 首尾或连续空格 / 字节数超上限」→ 任一命中走原来的管道。
  长度用**字节数**比上限：字节 ≥ 字符数，所以字节不超限必然不需要截断，
  多字节字符不会被误截。**改消毒逻辑要两条路径一起改**，单测同时钉两份行为。
- **`whistle_ensure_status_line` 用配置签名 `@whistle_mark_stamp` 跳过重建**
  （它每次 deliver 都跑，重建一次 400~600ms）。新增**影响渲染**的配置项必须加进
  `whistle_mark_stamp`，否则改了不生效 —— 这正是这类缓存的经典失效方式。
  计数**不进**签名：format 里是引用，不需要因计数变化重建。

**SessionEnd hook 必须同步（不加 `async`）**：Claude Code 退出时会带走后台子进程，
异步的清除可能被杀在半路，留下一个永远灭不掉的 `▶`。其余 hook 都是 `async: true`，
只有这一个例外，`our_entry()` 里按事件名判断。

**`running` 只能由 `UserPromptSubmit` 点亮，`SessionStart` 报的是 `idle`**：
`SessionStart` 不代表 agent 在干活 —— `--continue` / `--resume` 恢复出来的、以及刚敲
`claude` 起的新会话，都只是在提示符前**等着**。早先把它映射成 `running`，配上
resurrect 的 `@continuum-restore` 就是「恢复 3 个会话 → 状态栏亮 `▶3`，一个都没在跑」。
现在映射成 `idle`（`source=compact` 除外 —— 那是轮中压缩，agent 还在干活，原样不动）。

**带 `<task-notification>` 的 `UserPromptSubmit` 不算「已读」**：后台任务结束时
Claude Code 把通知包成 user 角色消息喂回会话，于是 hook 也会收到一次
`UserPromptSubmit`。活动态照旧点亮（agent 确实在处理它），但**跳过 `--read-pane`** ——
那不是真人输入，拿它当已读会把用户还没看过的 `◆` 悄悄抹掉（`hooks/claude-code.sh`
的 `UserPromptSubmit` 分支按 prompt 里有没有 `<task-notification>` 判断）。

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

**汇总数 pane，菜单也列 pane —— 两处必须是同一个粒度。** `@whistle_count_*` 按
`list-panes -a` 的**每个 pane** 计数，`whistle_agent_windows` 也必须**一个 pane 一行**。
早先菜单按 `window_id` 去重、只留 rank 最高的一行，于是「一个窗口里两个 agent 都在跑」
时状态栏写 `▶2`、弹窗只列 1 条，用户以为少了一个（2026-11-04 实测：`▶3` 对 2 条）；
更糟的是被去重丢掉的那一行连 pane id 都没留下，**第二个 agent 在菜单里没有入口、
跳不过去**。同一窗口的多个 agent 用消息列末尾的 `·格N` 区分（N 是它在窗口里的位置）。
窗口徽章是唯一允许不同粒度的地方 —— 它天然一个窗口一格，按 rank 取窗口内最高的那个态。

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

**`@whistle` 只存 agent 自己报的值，绝不把「标记有效」翻译成 running 写进去**：
「还有子 agent 在跑」由**推导层**按 `@whistle_sub` 合成，写进真源就等于把推导结果
烤死 —— Stop 时子 agent 还在跑就存下 running，子 agent 结束、标记被清掉之后，
那份 running **没有任何事件会再改写它**，于是用户读掉 `◆` 之后就是一盏永不熄灭的
`▶`（2026-11-02 实测：dayfold 的一个 pane 亮了 33 分钟）。存 idle 的话，标记一清或
TTL 一到，推导层立刻回落 —— 自愈。判据链是「真源只放上报值 / 派生值放推导结果」。

**`SubagentStop` 只清标记，绝不写活动态。** 子 agent 结束时，主 agent 那一轮
通常**还在跑**（它派了子 agent、正等结果）—— 早先这里写 idle，把正在干活的
主 agent 标成「空闲」，状态栏与菜单都显示错且全程零报错（2026-11-02 实测）。
活动态的收尾只有两个出口：主回合结束的 `Stop` 事件写 idle；`SessionEnd` 写 gone。
「主回合已结束、子 agent 还在跑」由标记兜底（推导层把活动态钉成 running）。

**后台命令在飞时这一轮不算「做完」**：Claude Code v2.1.145 起，`Stop` / `SubagentStop`
的 hook 输入带 `background_tasks` 数组，只收「**已后台化且 `status ∈ {running, pending}`**」
的任务（`type` 是友好标签：`shell` / `subagent` / `workflow` / `monitor` / `MCP task` …）。
`hooks/claude-code.sh` 的 Stop 分支看到 `shell` / `subagent` / `workflow` 就把活动态写成
`running`（标题「后台: <描述>」）并**不写 `done` 通知** —— 有效态按 rank 取高者
（`done 3 > running 2`），报 done 会把 running 盖掉、徽章显示成 `◆`，正是 TODO-18
记的现场。后台任务结束、Claude 被叫醒再跑一轮时，那一轮的数组已经空了，才写 done。
`monitor` / `MCP task` 刻意不算（长驻监视器会让 `▶` 长期亮着）。
**没有「后台任务结束」这个 hook 事件**，靠的就是那一轮叫醒后的 `Stop`；
已知限制：后台进程被手工 kill 且 Claude 没被叫醒时，`▶` 会留到下一次事件。
`TaskCreated` / `TaskCompleted` **不是**后台任务事件（那是 todo 清单），别接错。

**「他在正文里问我一句」靠 `idle_prompt` 补回来，而且必须有守卫。**
Stop 因 `background_tasks` 在飞而刻意不写通知（上一条），可「agent 在正文末尾
问了一句、停在那里等你」恰恰不产生任何工具事件 —— 2026-11-11 的现场就是
`▶ 后台: 2 个任务`，用户完全收不到提醒。Claude Code 在回合结束后约 60 秒发
`Notification{notification_type:"idle_prompt"}`（`Claude is waiting for your
input`），`hooks/claude-code.sh` 把它映射成 `wait`（标题「等你回复」）。
实测它在后台 **shell** 仍 running 时照样发（v2.1.304），后台 **subagent** 在飞时
则不发 —— 后者仍是盲区。**它每个回合都会发，所以守卫不可省**：通知通道为空
**且** 活动态是 `running` 才写。少了第一条，正常做完的回合 60 秒后会被 `◆` 改写成
`◔`（rank `wait 4 > done 3`）；少了第二条，用户读掉 `◆` 之后留下的空档会被误判成
「在等你」。`test/e2e/claude_hook.bats` 的三条用例逐条钉住。

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

状态栏 running 那一格用 Claude Code 同款 spinner 转（`· ✢ ✳ ✷ ✸ ✻ ✽`，默认 0.5 秒一帧）。
帧表以 Claude Code 自己的实现为底（v2.1.304 的 `p` 数组：圆点逐级长成星），中间的
`✶` 换成了 `✷ ✸` 两级八芒星。

**风格可配：`@whistle_spin_style`。** 帧表集中在 `whistle_spin_frames()` 的 case 里
（纯函数，加一套只需加一行）。内置 `claude`（默认）、`symbols_3`、`circles_5`、
`lines_3`、`squares_9`、`togglers_4`；除 `claude` 外取自
[cli-loaders](https://github.com/cbmongithub/cli-loaders)（MIT）的
`src/cli-loaders.ts`。未知值回落到默认风格 —— option 被手改错时那格不能渲染成空白。

`lib/spin.sh` **每帧重读** `@whistle_spin_style`，所以换风格不用重启推进器；新表里没有
当前字符时 `whistle_spin_next_char` 会回落到该风格的第一帧。这跟「改了帧表代码要重启
推进器」（`scripts/setup.sh` 里的 `whistle_spin_stop`）是两件事：那是代码，这是配置。

两处刻意不照搬 cli-loaders：① `symbols_3` 原版有一帧重复（`✹` 出现两次做「弹回去」），
按下面那条无状态查表的约束去掉了；② 各 loader 自带的 `speed`（50–130ms）没搬 ——
那是进程内 TUI 的节奏，状态栏每帧要 fork 一次 tmux，间隔统一由 `@whistle_spin_interval`
控制。

**为什么是星形而不是 Braille 点阵。** 早先用的是经典 6 点图案
（`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`）：常见等宽字体（MapleMono 等）把整个 Braille 单元画在
cap 高到基线之间，只占上三行的 6 点图案墨迹比旁边的数字与 `◆` / `◉` 高出约
1/4 格 —— 状态栏里看起来「飘在行首上方」（2026-11-10 用户报的现象）。中间一度
换成覆盖四行的 Braille 组，观感又太像一竖条点（同日用户否掉）。星形与数字、
图标同一套度量，天然居中，且与 Claude Code 的观感一致。

**⚠️ `✢ ✳ ✷ ✸ ✻ ✽` 不在 MapleMono 里**，显示靠终端回落到系统里带这些字形的字体
（本机命中 Meslo / DejaVu Nerd Font）—— 与 Claude Code 在同一个终端里走的是同一条路。换到没有这些
字形的终端会显成豆腐块，届时 `@whistle_spin off` 退回静态 `▶`。

**⚠️ 帧表里不能有重复字形。** `whistle_spin_next_char` 是「查当前字 → 取下一个」
的无状态查表，同一个字出现两次时永远匹配到前一个，动画会卡死在同一帧。
Claude Code 原版是 12 帧「长—缩」循环（`p` + `p.toReversed()`），缩的半段与长的
半段同字形，搬不过来 —— 这里只取长的半段（七帧）；`test/unit/spin.bats` 有一条用例守着
「表里不许有重复字形」。

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
还留着最后一帧，不判计数的话状态栏会一直挂着 `· 0` —— 动画早停了、字形还在，
看起来像卡死。所以 `whistle_summary_build` 里 running 那格是
`#{?#{@whistle_count_running},<帧选择器>,<静态图标>}`，归零退回 `▶`。

**菜单是自绘 popup，会自己刷新**（`lib/menu.sh` 的 `whistle_menu_ui` 每约 0.5 秒
重读一次模型，变了才重绘；列表重排后高亮按 **pane id** 跟随原来那个 agent ——
一个窗口里可以有多个 agent，按 window id 跟随会永远落回第一条）。
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
- **`opt` 读全局 option**（`show -gqv`，`set -g` 写的那种）；**`optw` 读的是
  全局 window option**（`show -gwv`，给 `window-status-format` 这类用）——
  拿它读 `@whistle_count_*` 会报 `invalid option`，断言静默读空、测试假绿。
  要读某个窗口自己的 option 用 `wt show -wv -t "$w" <name>`；`optp` 要两个参数
  （option 名 + pane id）。
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
- **idle_prompt 验证记录**：`docs/idle-prompt-verification.md` —— 「agent 在正文里提问
  却不提醒」的现象、三层根因、探针实验与真机回归时间线，以及怎么再验一次。
- **设计方案评审**：`docs/notify-design-review.md` —— 「事件收件箱」形态（事件溯源 +
  SQLite + Python TUI）的取舍分析，说明为什么只吸收模型、不换技术栈。
- 需求来源：`docs/requirements-analysis.md`
- 使用说明：`README.md`
- 设计记录（含时序图、API 映射、16 个技术点、实施记录与踩过的坑）在本机的 plan 文件里，
  **不在仓库内**：`/Users/rich1e/.claude/plans/tmux-tmux-session-session-agent-a-partitioned-wadler.md`
