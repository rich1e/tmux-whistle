# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目一句话

tmux 插件：让 agent（Claude Code 或任何脚本）把状态**推**给 tmux，跨 session 显示在状态栏上。
「我做完了」和「我在等你」由 agent 自己上报 —— tmux 层面不猜、不轮询。

## 开发命令

```sh
make help             # 列出全部目标
make deps             # 装 bats-core / shellcheck / shfmt（brew tap 不可用时回退官方二进制）
make lint             # ShellCheck（POSIX sh 档）
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
bats -f 'menu-args' test/integration/cli.bats      # 按用例名正则过滤
```

改代码 → `make fmt` → `make check` → 提交。当前 155 项测试（24 单测 + 131 集成/e2e）。

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
```

**状态存储约定**

| 作用域 | option | 性质 |
|---|---|---|
| pane | `@whistle` `@whistle_msg` `@whistle_at` `@whistle_src` | **真源**，只有这里能写 |
| window | `@whistle_win` `@whistle_win_msg` `@whistle_win_count` | 派生，由 `whistle_recompute_window` 重算 |
| global | `@whistle_pending` `@whistle_mark` `@whistle_status_right` `@whistle_pane_mark` | 派生 / format 串 |

**徽章必须是纯 tmux format，一个进程都不 fork。** 状态栏每 `status-interval` 重算一次，
写成 gpakosz 那种 shell function 就会每次刷新都 fork 一个 `sh -c`。整段徽章串存进 global
option `@whistle_mark`，用户配置里只写 `#{E:@whistle_mark}` 占位符 —— 改色只需重跑
publish，不用重载 tmux 配置。

**投递编排**在 `lib/deliver.sh` 的 `whistle_deliver`：它先调 `whistle_ensure_status_line`
（自愈，见下），再依次走边框、边框状态行、状态栏刷新、瞬时提示扇出、桌面通知。

## 不变量（改代码前必须知道）

**POSIX sh 约束**（目标 shell 是 macOS 的 `/bin/sh`）

- **没有局部变量**。函数里的临时变量会覆盖调用方的同名变量 —— 所有临时变量必须带命名空间
  前缀（`_ws` / `_l*` / `_p*` / `_c*` / `_d*`）。历史上这条静默覆盖过 session 名。
- 禁用 `[[ ]]`、数组、`local -n`、`mapfile`、`$'...'`。
- `$var` 后面紧跟中文/全角字符必须写 `${var}`，否则 bash 会把字节吞进变量名。

**tmux 调用**

- `tmux show` **必须带 `-v`**，否则读回的是 `名称 "值"` 整行，写回去会毁掉用户状态栏。
  global option 用 `show -gv`。
- **pane 与 window 不能用同名 user option** —— 会影子遮蔽：清掉 pane 的 `@whistle` 后
  查找回退到 window 的聚合值，pane 看起来"清不掉"。
- **`run-shell` 会阻塞 tmux 命令队列**，绝不能排在 `\;` 链中间。状态写入与聚合只用
  `set` / `setw` / `show` / `list-panes`。
- **`set-hook` 必须用命名 array key**（`after-select-window[whistle]`）。不带 key 会清空整个
  数组顶掉别的插件；用 `-a` 又会在重复 source 时越加越多。
- **`display-menu` 的第三参是 tmux 命令，不是 shell 命令**。要调外部程序必须包在
  `run-shell -b '...'` 里，否则 tmux 会把路径当命令名 → `Unknown command: <path>`。
- **socket 定位优先级**：`$WHISTLE_TMUX_SOCKET` > `$TMUX` > `$TMUX_SOCKET`。`$TMUX_SOCKET`
  会被子进程跨 server 继承，可能指向用户正在用的另一个 server；`$TMUX` 才是 tmux 按 server
  写好的权威值。加载时还要把 `#{socket_path}` 显式钉死传给 `scripts/setup.sh`。
- 嵌套 `#{?...}` 条件式的大括号必须配平（`whistle_mark_build` 是三层，结尾 `}}}`）。
  畸形 format 会被 tmux **静默渲染成空字符串**，不报错 —— 有配平单测守着。

**消息消毒**：任何进入 tmux format 的文本都要过 `whistle_sanitize` —— 剔掉 `# { } |`
与控制字符，截断 80 字符。否则 `#{` 会被二次展开、`}` 会截断条件式。

**自愈机制不要删**：`whistle_ensure_status_line()`（在 `lib/deliver.sh` 的
`whistle_deliver` 开头调用）是唯一不依赖加载顺序的补丁时机。oh-my-tmux 在 source 完
`tmux.conf.local` **之后**才重算主题并重设 `status-right` / `window-status-format`，
会覆盖早先打的补丁；固定延迟是竞态。

**绝不覆盖别人的东西**：`lib/install-hooks.sh` 往 `~/.claude/settings.json` 合并时只增删
带 `tmux-whistle` marker 的条目，用户已有的 hook 原样保留；改前先备份。

## 测试约定

三层，越往下越慢：

| 层 | 目录 | 依赖 | 目标 |
|---|---|---|---|
| L1 | `test/unit/` | 无（不碰 tmux） | `whistle_sanitize` / `whistle_rank` / `whistle_aggregate` / mark 构建 |
| L2 | `test/integration/` | `tmux -L` 隔离 server | 渲染、注入幂等、边框可还原、hooks |
| L3 | `test/e2e/` | 隔离 server + 构造的 hook JSON | `bin/tmux-whistle` 与 `hooks/claude-code.sh` 完整链路 |

`lib/core.sh` 里 `whistle_sanitize` / `whistle_rank` / `whistle_aggregate` 三个函数
**不得出现任何 tmux 调用** —— 这是 L1 单测能脱离 tmux 跑的前提，写代码时要守住。

helper（`test/test_helper/whistle.bash`）的约定：

- 每个测试文件一个独立 socket（`tmux -L whistle-test-$$`），用 `-f /dev/null` 起 server，
  绝不读用户真实的 `tmux.conf`。
- **绝不在 helper 里装 `trap ... EXIT`** —— 会覆盖 bats 自己的 trap，静默吞掉测试失败
  （表现是 `Executed N instead of expected M`，而不是 `not ok`）。清理交给 `teardown()`。
- `teardown` 必须 kill-server **并显式删掉 socket 文件**（`kill-server` 不总会 unlink，
  反复跑会攒出几百个残留）。
- `display -pF` 不解析 `#[...]` 样式，断言前要剥掉（helper 的 `wt_render_windows` 已处理）。
- hook 走 `run-shell -b` 是异步的，断言前用 `wt_wait_until` 轮询，别 sleep 一下就假定好了。

## 风格

- 注释与用户可见文案一律中文；代码标识符英文。
- `shfmt` 按方言分两次调用（`-ln=posix` 给 `bin/ lib/ hooks/ install.sh`，`-ln=bash` 给
  `test/**/*.bash`）。**`.bats` 不是合法 bash，shfmt 解析不了**，格式化与格式检查都排除，
  这些文件靠 review 保证风格。
- ShellCheck 用 `shell=sh` 定向 POSIX 检查 —— `[[ ]]` 之类会直接报错，这是 KP-14 的兜底。
- `.shellcheckrc` 的 directive 不接受 `=` 两侧的空格（带空格会报 SC1134）。

## 安装布局与入口链路

入口链路：`tmux-whistle.tmux`（tpm 把 `*.tmux` 当**可执行文件**跑，不是 source）
→ `.tmux-whistle.conf`（bind `prefix + W` + `run-shell -b -d 0.5` 调 setup）
→ `scripts/setup.sh`（发布 mark、幂等 patch、注册读侧 hooks、清理残留边框）。

- 本地安装落在 `~/.local/share/tmux-whistle`（符号链接到仓库），**不放进
  `~/.config/tmux/plugins/`** —— tpm 的 `clean_plugins` 会删掉没有 `@plugin` 声明的目录。
- CLI 符号链接到 `~/.local/bin/tmux-whistle`；`bin/tmux-whistle` 自己循环解析符号链接再定位
  `lib/`（macOS 的 `readlink` 没有 `-f`）。
- `install.sh` 只往 `tmux.conf.local` 追加一段带 marker 的块，卸载用 `--uninstall`。
- 读侧 tmux hooks 只负责「已读 = 焦点进入」与聚合重算；**推送侧不碰 tmux hooks** ——
  tmux 没有能表达"agent 做完了"的事件。

## 延伸资料

- 设计文档（含时序图、API 映射、16 个技术点、实施记录与踩过的坑）：
  `/Users/rich1e/.claude/plans/tmux-tmux-session-session-agent-a-partitioned-wadler.md`
- 需求来源：`docs/requirements-analysis.md`
- 使用说明：`README.md`
