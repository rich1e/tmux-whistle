# AGENTS.md

tmux 插件：agent（Claude Code / Codex / OpenCode 或任意脚本）把状态**推**给 tmux，
跨 session 显示在状态栏。
纯 POSIX sh + tmux，无运行时依赖，无 package.json / 构建步骤。

**深层参考（改代码前值得读）**：`CLAUDE.md`（不变量与踩坑全记录）、`docs/development.md`（命令 / 红线 / 测试约定）、`docs/todo.md`（已知缺陷，含现象与原因）。本文件只放高频、易猜错的。

## 命令

```sh
make deps      # 首次：bats-core / shellcheck / shfmt（expect 需 brew install expect）
make fmt       # shfmt 原地格式化
make check     # 提交前唯一必跑：check-version → lint → fmt-check → test-unit → test-integration → check-no-stray-servers
bats test/integration/badge.bats               # 单文件
bats -f 'menu-args' test/integration/cli.bats  # 按用例名过滤
./install.sh                                   # 软链 + 写 tmux.conf.local + 装 hooks；--dry-run 可预览
tmux-whistle doctor                            # 环境自检（也报「本机还有别的 tmux server」）
```

改完代码直接 `prefix + r` 重载即可（`install.sh` 把仓库软链到 `~/.local/share/tmux-whistle`，不用重装）。

## 结构

- `bin/tmux-whistle` — CLI 入口，**版本号唯一真源在文件顶部**（`WHISTLE_VERSION` / `BUILD_DATE` / `BUILD_NUMBER`）。用户子命令：`done|wait|error|running|idle|run|clear|list|menu|jump|codex|on|off|doctor|install-hooks|install-codex-hooks`；`--activity` / `--notice` / `--sub-agent-*` / `--menu-*` 等是 hook 与测试用的内部入口。
- `bin/tmux-whistle-codex` — pane 本地 Codex 启动器。它建立 `PaneBinding` 后强制 `codex --no-daemon`，是多个 Codex TUI 正确上报的前提。
- `lib/core.sh` — **唯一状态写入点**。`lib/status-line.sh` 生成 tmux format 徽章（零 fork），`lib/deliver.sh` 负责六渠道投递，`lib/menu.sh` 是自绘 popup（`prefix + n`），`lib/spin.sh` 是独立的动画推进器进程。
- **三个 agent 接入源**：
  - Claude Code — `hooks/claude-code.sh`（hook 进程在 pane 进程树里，继承 `TMUX_PANE`）。`lib/install-hooks.sh` 合并 `~/.claude/settings.json`（只动带 marker 的条目）。
  - Codex — `hooks/codex.sh`。**managed daemon 被多个 TUI 复用后 `TMUX_PANE` 是 daemon 启动快照，不可信**；必须由 `tmux-whistle-codex` 建立 PaneBinding 并以 `--no-daemon` 启动。设计见 `docs/codex-pane-attribution-design.md`。`lib/install-codex-hooks.sh` 合并 `~/.codex/hooks.json`（只动带 marker 的条目，且**只追加**，避免 Codex 的 trust index 漂移）。`lib/install-agent-hooks.sh` 是 Claude + Codex 的聚合入口。
  - OpenCode — `hooks/opencode/tui.js`（TUI 插件，只有它的 `TMUX_PANE` 可信）+ `hooks/opencode.sh`（薄壳）+ `lib/opencode.sh`（纯函数映射，可被 L1 source）。**事件里没有 pane 信息**（99 个 V2 事件一个都没有），且 `opencode serve --service` 是 PPID=1 的共享守护、环境是启动快照 —— 所以绝不能按 cwd 猜 pane。
- 入口链路：`tmux-whistle.tmux`（tpm 当**可执行文件**跑）→ `.tmux-whistle.conf` → `scripts/setup.sh`。这三个 `.sh`/`.tmux` 必须是可执行文件。
- **OpenCode 插件必须以目录形态软链**（`~/.config/opencode/plugins/tmux-whistle` → `hooks/opencode`，链接名**不带 `.js`**）。单文件会被当成 server part 加载进 `TMUX_PANE` 不可信的进程；`plugins` 配置里的单文件路径会被官方**静默跳过**。`tui.js` 这个文件名是契约，改名就不再被认成 TUI part。

状态是**两条正交通道**：活动（`@whistle`，`running|idle|gone`）与通知（`@whistle_notice`，`done|wait|error`）。
有效态按 rank 取高：`error 5 > wait 4 > done 3 > running 2 > idle 1 > gone 0`。
新功能要「告诉用户一件事」就写通知通道，**不要挤活动通道**。

## 硬约束（违反不报错，只会静默出错）

- **POSIX sh（目标是 macOS `/bin/sh`）**：没有局部变量 —— 函数内临时变量会覆盖调用方同名变量，必须带前缀（`_ws` / `_l*` / `_p*` / `_c*` / `_d*`）。禁用 `[[ ]]`、数组、`local -n`、`mapfile`、`$'...'`。
- `$var` 后紧跟中文/全角字符必须写 `${var}`，否则字节被吞进变量名 → 非法 UTF-8。
- `lib/core.sh` 里 `whistle_sanitize` / `whistle_rank` / `whistle_aggregate` / `whistle_count_states` **不得出现任何 tmux 调用** —— L1 单测脱离 tmux 的前提。
- `tmux show` 必须带 `-v`（global 用 `-gv`），否则读回 `名称 "值"` 整行。
- **pane 与 window 不能用同名 user option**（影子遮蔽，pane 看似清不掉）；用户可配开关与插件自写状态也必须不同名。
- `run-shell` 会阻塞 tmux 命令队列，绝不能排在 `\;` 链中间；`run-shell` 子进程继承 **tmux server** 的环境，调用方 `export` 的变量传不进去，socket 要显式拼进命令串。
- `set-hook` 必须用命名 array key（`after-select-window[whistle]`），否则清空别人的 hook。
- **`display-menu` 的参数是 tmux 命令**，调外部程序要包 `run-shell -b`；从 shell 传 `\;` 要写 `'\;'`。
- 进入 tmux format 的文本必须过 `whistle_sanitize`（剔 `# { } |` 与控制字符）。**例外**：插件自己生成的 format 片段不能消毒。
- 嵌套 `#{?...}` 大括号必须配平 —— 畸形 format 被 tmux **静默渲染成空串**。
- 别删 `whistle_deliver` 开头的 `whistle_ensure_status_line`：oh-my-tmux 在 source 完 `tmux.conf.local` 后才重设状态栏，自愈是唯一不依赖加载顺序的时机。
- 只在「状态变化」触发同步的逻辑，必须在加载路径（`scripts/setup.sh`）也跑一次。

## Codex 接入（第二个推送源）

- `hooks/codex.sh` 映射：`SessionStart(startup/resume/clear)→idle`、`SessionStart(fork)→不写`、
  `UserPromptSubmit→running`、
  `PermissionRequest→wait`、`PostToolUse→仅清 wait`、`SubagentStart/Stop→子 agent 标记`、
  `Stop→idle+done`、`Interrupt→idle`、`SessionEnd→gone`。
- **默认 `@whistle_codex_pane_mode=strict`**：只接受启动器注入的 PaneBinding；缺失或无效时 Hook 静默不写状态。迁移期可显式设为 `auto` 或 `legacy`，但多 TUI 会写错 pane，doctor 会报红。
- **strict 下 Codex 不按进程猜 idle**：没有 Hook 上报时，进程名只能证明 TUI 还活着，不能区分 running / idle；`whistle_resolve_idle_panes` 必须跳过未上报的 Codex。旧的 `hook|migration` `running` / `idle` 也由全局重算清成 `gone`，不能降成 `idle`。
- **启动器建立绑定后立即写 `idle`**：当前 Codex 可能到首个 prompt 才发 `SessionStart`；少了这一步，strict 模式会让刚打开的 TUI 在状态栏里完全不可见。
- **菜单打开前先重算全局计数**：菜单列表是 live pane 推导，状态栏读缓存计数；`cmd_menu` / `cmd_menu_args` 必须先 `whistle_recompute_global`，否则无 hook 的 raw Codex 启停会让两边数量不一致。
- **前台进程已退回 shell 时清掉 hook/migration 活动态**：`running` / `idle` 只代表临时活动；菜单打开与插件重载入口会在重算前把 `@whistle_src=hook|migration` 且不再是 agent 的活动态降为 `gone`，通知通道保留。
- **同一 pane 多 session 要聚合**：活动态由 `@whistle_cx_running` / `@whistle_cx_idle` 集合推导，任一 session running 就不能被另一个 Stop 降成 idle；SessionEnd 只移除自己的 session。
- **Codex hook 只有 `PostToolUse` 异步**。它只清 wait、不写活动态；其余生命周期事件同步，
  防止 `SessionStart → UserPromptSubmit → Stop` 的写入乱序留下永久 `▶`。
- **不要在 `SessionStart` 写 running**：新开 / 恢复停在提示符前，只有
  `UserPromptSubmit` 代表真开始干活；`compact` 是一轮中间，`fork` 可能是后台摘要，
  两者都必须原样不动。
- **内部 Codex fork 必须整段静默**：episodic-memory 用固定英文 marker 发起临时摘要
  turn，和父会话共用 `TMUX_PANE`。`UserPromptSubmit` 命中 marker 后把 `session_id`
  写进 pane option `@whistle_cx_quiet`，后续 `Stop` / `SessionEnd` 等事件全部跳过，
  否则会覆盖父会话 activity、清掉未读通知并产生系统通知。
- **`SubagentStop` 只移除自己的 id，绝不写活动态**。Codex 的 `@whistle_sub` 是 `agent_id:expiry` 集合，最后一个子 agent 结束才回落。
- `lib/install-codex-hooks.sh` 合并 `~/.codex/hooks.json` 时**追加**条目，不能前插：
  Codex 把信任绑定在 `event/index` 上，前插会让用户已有的 ping-island 等条目失去信任。
- 新装或改命令后，用户必须在 Codex 里输入 `/hooks` 审核并信任；安装器不修改信任状态。
- 同一层同时有 `hooks.json` 与 inline `[hooks]` 时 Codex 会合并并警告；doctor 会提示。

## OpenCode 接入（第三个推送源）

- **pane 归属只能由 TUI 提供。** 事件里没有 pane 信息，`opencode serve --service` 的环境是启动快照 —— 按 cwd 猜必错（同目录可能既有 opencode 又有 claude）。
- 插件必须**目录形态**软链（`~/.config/opencode/plugins/tmux-whistle` → `hooks/opencode`，链接名不带 `.js`）。单文件会被当成 server part；`plugins` 配置里的单文件路径会被静默跳过。`tui.js` 文件名是契约。
- **TUI 启动要写 `idle`**（`--tui-start`）。上一轮的 `gone`（rank 0）不会自己恢复成 idle，因为推导层只把**空**状态推成 idle。
- **事件必须串行**（`tui.js` 的 promise 链，不 detach）。并发 spawn 会乱序：实测 `wait` 被后到的 `done` 盖掉。cleanup 要先 `await queue` 再写 `gone`。
- `interrupted` 按 `reason` 分派（`superseded` 不动活动通道、`shutdown` 写 `gone`）；`permission.replied` 按 `reply` 分派（`reject` 要收成 idle）。
- **「等你回答」两条通路**：`permission.asked` 是权限确认；**question 工具 / MCP elicitation 走 `form.created`** → 同样 `wait`，回答/取消（`form.replied` / `form.cancelled`）只清通知。事件名无 `session.` 前缀，sessionID 在 `data.form.sessionID`；`form.cancelled` 不写 `idle`（同一轮还在跑）。
- 后台 shell 用**在飞 id 集合**（`@whistle_oc_shell`）而非计数器；集合非空时不写 `done`。
- **订阅要逐条 `try/catch` + `data.listen` 兜底。** 一条 `data.on()` 抛异常会断掉整个循环，后面全收不到；而探针在循环之前，`doctor` 照样报绿。
- **`tabs.list()` 别假设是字符串数组。** `new Set(list)` 遇上 `{sessionID}` 对象会让 `has()` 永远为假 → 所有事件被静默过滤。支持两种形状，取不到 id 时 **fail-open**。
- **通知文案必须兜底**：多 session / 多 TUI 时 `session.get()` 可能取不到标题，空 msg 会让徽章只剩图标、桌面通知只剩状态标签。按 `title → slug → "OpenCode"` 回落。
- **子 session 的 `done` 不覆盖主 session**：只在通知通道为空且没有后台在飞时补一条固定文案，且绝不替子 session 写活动通道。
- 桌面通知的 group **每条唯一**（`@whistle_os_group` 记最近一条）。固定 group 下「先删旧再加新」与已读 `-remove` 会撞出空横幅。
- 排查顺序看三段证据：`tui-probe`（加载了没）→ `subs=N`（订阅几条）→ `js-trace`（事件到没到、为什么丢）。`doctor` 已展示 `subs`，`subs=0` 会报红。

## 读屏降级通道（`lib/detect.sh` + `lib/detect-rules.sh`）

hook 归因 fail-closed 时（用户直接跑 `codex`），状态栏上那个 pane 只能靠读屏补。

- 屏幕写 `@whistle_live`，hook 写 `@whistle`，**永不互相覆盖**。推导层优先用
  `@whistle` 的 `running` / `idle`，其次 `@whistle_live`，最后前台进程名。
  `gone` 是上一轮退出留下的墓碑，同一 pane 重新跑起 agent 时可被新的 live 覆盖。
  绝不把屏幕结论写进 `@whistle`。
- 只有 `@whistle_src` 为 `hook` / `migration` **且** `@whistle` 为
  `running` / `idle` 时才跳过该 pane；裸 `src` 或残留 `gone` 不能关掉读屏回退。
- 「前台进程叫什么」按 **argv[0] 的 basename** 认：软链/包装器下
  `#{pane_current_command}` 是目标二进制的名字。
- 防抖：`→ running` 立即生效，其余要连续两次；看到与已生效状态一致的分类要清掉
  pending 计数。有 agent 时 1 秒一轮，否则回 `@whistle_detect_interval`。
- `running → idle` 补一条 done：开关 on + 持续 ≥ `@whistle_detect_done_min` +
  `@whistle_notice` 为空，三条缺一不发，且只写通知通道。
- 读屏写的 `wait` 带 `@whistle_notice_src=detect`，屏幕回到 running/idle、pane 退出、
  开关关闭时由读屏自己收掉；别人写的通知不碰。写 `wait` 是**升级**（rank 4），
  只有已是 wait/error 才跳过 —— 「已有通知就不写」会挡住真实的权限请求。
- 写完走 `whistle_finish`（在 `lib/deliver.sh`，与 CLI 共用）：少了投递就只有徽章变，
  边框 / 瞬时提示 / 桌面通知全不发。守护要 source core + status-line + deliver。
- 只轮询**有规则表**的 agent（codex / claude）；`opencode` 进来就是每秒空转。
- 一轮只取一次 `ps` 快照，别逐 pane fork。
- ⚠️ macOS 的 `/bin/sh` 是 **bash 3.2**，解析器**不接受 `$(` 直接跟 `case`**
  （报 `syntax error near unexpected token ';;'`）。改完跑 `sh -n`。
- ⚠️ awk 判多字节只能用 `index()`：`"─" == "❯"` 在这个 locale 下为真，
  `[❯›]` 会按字节拆开；NBSP 只能写成字符串字面量 `"\302\240"` 再交给 `gsub`。

## 性能：写入热路径

一次状态写入的固定成本是**进程数**，不是窗口数（早先误判成 O(窗口数)）。80 次 tmux fork → 25 次：

- 配置快照必须**在 CLI 入口** `show -g` 后 `export`；在 `whistle_conf` 里惰性读没用 —— 调用点都是 `$(...)` 子 shell。
- 长驻进程（`lib/spin.sh` / `lib/detect.sh`）必须 `WHISTLE_CONF_NO_CACHE=1`，它们靠重读感知配置变化。
- `show -g` 会给 `#` 开头或含空格的值加引号，`show -gqv` 不会 → 快照必须剥引号，否则 `#[fg="#af5fff"]`。
- `whistle_sanitize` 有快路径（干净短串直接返回）；改消毒逻辑要两条路径一起改。
- `ensure_status_line` 用 `@whistle_mark_stamp` 跳过重建；新增影响渲染的配置项必须加进签名。
- 菜单调色板在循环前取一次（`whistle_menu_palette_load`）：条目只有 5 种状态 + 4 种 agent，别每项 fork 两次。
- 测试播种用「一次 tmux 链」而不是 N 次 CLI（`seed_pending_windows` 26 项从 37s → 4.4s）；但需要断言计数/窗口徽章的测试必须走真实写入。

## 测试

三层：`test/unit/`（不碰 tmux）→ `test/integration/`（`tmux -L` 隔离 server）→ `test/e2e/`（完整 CLI/hook 链路，`menu_popup.bats` 需要 `expect`）。

- 每个**用例**一个独立 socket `whistle-test-<pid>-<用例号>`，`-f /dev/null` 起 server，绝不读用户真实 tmux.conf（同文件复用路径会撞 TODO-21 的竞态）。
- **helper 里绝不要装 `trap ... EXIT`**（会覆盖 bats 的 trap，失败被吞成 `Executed N instead of expected M`）。清理只在 `teardown()`。
- **不要 `pkill bats`**：teardown 跑不到会留下隔离 server，它会让 tmux-continuum **静默关闭自动恢复/自动保存**。`make check` 末尾的 `check-no-stray-servers` 守着这条。
- helper 的 `opt` 读全局 option（`show -gqv`），`optw` 读全局 **window** option（`show -gwv`）；用错会静默读空、测试假绿。读某个窗口自己的 option 用 `wt show -wv -t "$w" <name>`。
- hook 走 `run-shell -b` 是异步的，断言前用 `wt_wait_until` 轮询，不要 sleep。
- `bin/tmux-whistle` 的 `cmd_menu` 与 `cmd_menu_args` 是两份几乎相同的循环（后者供测试断言 argv）；**改一边不改另一边 = 假绿**。
- **完整 `make check` 约 10 分钟**（714 项）。其中约 216 秒是「一个用例一个 tmux server」的固定开销（0.47s/项），写入路径已优化过，再快只能动隔离架构 —— 不建议。日常用 `make test-unit`（10s）或 `bats -f '<用例名>' <文件>` 跑局部。
- `menu_popup.bats` 用 `expect` 附着伪终端；非交互环境若 `TERM=dumb`，用
  `TERM=xterm-256color make check`，否则 9 条 popup 用例会假红。

## 风格

- 注释与用户可见文案一律中文，代码标识符英文。
- `shfmt` 分方言两次调用：`-ln=posix` 给 `bin/ lib/ hooks/ install.sh scripts/`，`-ln=bash` 给 `test/**/*.bash`。**`.bats` 既不是合法 bash 也不是 posix，必须排除**（靠 review 保证风格）。
- ShellCheck 用 `shell=sh`；`.shellcheckrc` 的 directive 不接受 `=` 两侧空格（报 SC1134）。
- 版本：`make check-version` 校验 SemVer + 阶段 + 构建戳与实际输出一致，版本常量必须恰好一个单引号赋值。发布规范见 `docs/versioning.md`。

## 注意

- `HANDOFF.md` 是本地易失的任务交接快照，已在 `.gitignore`，不属于仓库内容。
- `.claude/worktrees/` 与 `.superpowers/` 是本地残留/临时工作区，不要当代码来源或提交。
