# Codex 多 pane 归因：长期修复方案

## 实施状态

✅ 已实现（2026-11-23）：

- `tmux-whistle-codex` / `tmux-whistle codex` 启动器，强制 `--no-daemon`
- `WHISTLE_CODEX_*` PaneBinding 与 Hook 端校验
- 默认 `@whistle_codex_pane_mode=strict`，缺失绑定时 fail closed
- `@whistle_codex_binding` pane 标记与 doctor 多 TUI 检测
- `@whistle_cx_running` / `@whistle_cx_idle` session 聚合
- Codex subagent `agent_id:expiry` 集合
- strict 升级时自动清理无 binding 的旧 raw Codex `running` / `idle` 假状态
- strict 下未上报的 Codex 不做进程 idle 推导，未知状态不伪装成空闲
- 多 pane、同 pane 多 session、多 subagent、wrapper、install、doctor 测试

仍属产品边界：

- Codex Desktop / VSCode 不在 tmux pane 内，没有 pane 级状态。
- 多个 TUI 同时 attach 同一 thread 时，不复制 pane 状态。
- 上游 Hook 若未来提供稳定 client identity，可移除 `--no-daemon` 约束。

## 1. 问题定义

Codex managed app-server daemon 按 `CODEX_HOME` 复用。daemon 的环境变量来自
“第一个启动它的 Codex TUI”，之后连接到同一 daemon 的其它 TUI 不会刷新
`TMUX_PANE`、`TMUX` 和工作目录快照。

旧实现 `hooks/codex.sh` 直接使用 Hook 进程继承的 `TMUX_PANE`。在单 TUI 场景中
它是正确的；在多 TUI 场景中，事件会统一写进第一个 pane。

实测现场：

```text
PID 44519  pane %1  第一个 Codex TUI
PID 44641  daemon   TMUX_PANE=%1
PID 87758  pane %9  第二个 Codex TUI，连接同一个 daemon
```

Hook 日志结果：

```text
TMUX_PANE=%1  374 条
TMUX_PANE=%9    0 条
```

实际 client 位于 `%9`，但 `%9` 没有任何 Codex activity；`%1` 错误显示
`running`。这不是 Hook 丢失，而是 daemon 把 client 身份抹平了。

Codex Hook 输入只有 `session_id`、`turn_id`、`cwd`、`transcript_path` 等字段，
没有可信的 pane/client 身份。因此仅修改 `hooks/codex.sh` 无法彻底修复。

## 2. 设计目标

1. 多个 Codex TUI 位于不同 tmux pane 时，各自独立上报 `running` / `idle` /
   `done` / `wait` / `error`。
2. 任一 pane 的状态变化不能写到另一个 pane。
3. 无法建立可信 pane 绑定时 **fail closed**：不写状态，并留下可诊断日志，
   不允许继续按 daemon 的陈旧 `TMUX_PANE` 猜。
4. 支持不同 `CODEX_HOME`；每个 Codex home 都必须单独安装和信任 Hook。
5. 不按 active pane、cwd、窗口标题或进程名猜 pane。
6. 保持状态栏渲染零 fork；新增归因逻辑只出现在 Hook 写入路径。

非目标：

- Codex Desktop / VSCode 扩展不在 tmux pane 内，暂不承诺 pane 级状态。
- 多个 TUI 同时 attach 同一个 thread 时，不保证为每个 TUI 复制同一状态；
  这需要 Codex 上游提供 client identity。

## 3. 核心方案：显式 PaneBinding

### 3.1 PaneBinding 契约

新增一个只由 pane 本地启动器设置的绑定：

```text
WHISTLE_CODEX_BINDING=v1
WHISTLE_CODEX_CLIENT=<pane_id>:<launcher_pid>:<started_at>
WHISTLE_CODEX_PANE=<pane_id>
WHISTLE_TMUX_SOCKET=<absolute socket path>
```

约束：

- `WHISTLE_CODEX_PANE` 必须与 tmux server 中真实存在的 pane id 完全一致。
- `WHISTLE_TMUX_SOCKET` 必须是当前 tmux server 的绝对 socket path。
- `hooks/codex.sh` 只信这个绑定，不再默认信任共享 daemon 的 `TMUX_PANE`。
- 绑定验证失败时不写任何 `@whistle*` option。

### 3.2 Pane 本地启动器

新增 `tmux-whistle-codex` 启动器，并同时提供 CLI 入口：

```sh
tmux-whistle codex [--] [codex args...]
```

启动器职责：

1. 校验当前在 tmux 内且有 `TMUX_PANE`、`TMUX`。
2. 读取并校验 `#{socket_path}`。
3. 设置上述 `WHISTLE_CODEX_*` 环境变量。
4. 检查当前 `CODEX_HOME`（缺省 `~/.codex`）已经安装 tmux-whistle Hook。
5. 经 CLI 写一次 `idle`。当前 Codex 可能到首个 prompt 才触发 `SessionStart`，
   而 strict 模式不会按进程猜状态；启动器不先写，刚打开的 TUI 不会出现在状态栏。
6. 执行：

```sh
exec codex --no-daemon "$@"
```

`--no-daemon` 是硬约束。它保证 Codex client、session runtime 和 Hook 子进程
处于同一个 pane 本地进程树，`WHISTLE_CODEX_PANE` 不会再次被共享 daemon 的
启动快照覆盖。

启动器不覆盖系统的 `codex` 命令，也不私自修改用户 shell 配置。安装器只创建
`tmux-whistle-codex` 软链并打印可选 alias：

```sh
alias codex='tmux-whistle-codex'
```

如果用户不使用启动器继续直接运行 `codex`，多 pane 模式进入 legacy 行为；
`doctor` 必须明确告警。

### 3.3 Hook pane 解析顺序

`hooks/codex.sh` 新增唯一 resolver：

```text
1. WHISTLE_CODEX_BINDING=v1 + WHISTLE_CODEX_PANE + WHISTLE_TMUX_SOCKET
   → 校验 socket、pane 存活、pane id 一致
2. legacy：TMUX_PANE
   → 仅 @whistle_codex_pane_mode=legacy 时允许
3. 否则 fail closed
```

最终版本默认：

```tmux
set -g @whistle_codex_pane_mode strict
```

迁移期可临时使用 `legacy`，但每次写入都要记录：

```text
pane_source=legacy
binding=missing
```

永远禁止的 fallback：

- active pane
- `pane_current_path` / cwd
- pane title
- 前台进程名
- daemon PID 的 cwd

这些信号在多 TUI、同 cwd、异步 Stop 和后台 turn 场景下都会误判。

### 3.4 多 CODEX_HOME

启动器读取：

```sh
codex_home=${CODEX_HOME:-$HOME/.codex}
```

并检查：

```text
$codex_home/hooks.json 中存在 tmux-whistle marker
```

`install-codex-hooks` 增加显式参数：

```sh
tmux-whistle install-codex-hooks --hooks "$CODEX_HOME/hooks.json"
```

`doctor` 显示当前生效的 `CODEX_HOME` 和 Hook 路径。不同 home 不会互相继承 Hook。

## 4. 同一 pane 内多 session 的聚合

pane binding 修好后，多个 TUI pane 已经可以独立上报。但同一 pane 仍可能有：

- 主 thread 与 side thread
- 多个并发 subagent
- fork / resume 产生的短生命周期 session

当前 pane 只有一个 `@whistle`，后到的 Stop 会把先到 session 的 `running` 覆盖掉。
长期方案增加 pane 内 session 集合：

```text
@whistle_cx_running=<session_id>[:<expiry>] ...
@whistle_cx_sub_ids=<agent_id>:<expiry> ...
```

规则：

- 任一 session 处于 running → pane activity 为 `running`。
- 所有 session 都结束 → 才允许回落 `idle` / `gone`。
- `Stop` 只移除自己的 session，不直接覆盖整个 pane。
- `SessionEnd` 精确移除自己的 session。
- TTL 清理崩溃或丢事件留下的 stale id。
- 现有 `@whistle_sub` 单值标记升级为 subagent id 集合，和 OpenCode 的
  `@whistle_oc_shell` 使用同一思路。

通知通道保持现有语义：完成事件仍写 pane 的通知槽；多 session 同时完成时，
按 rank + 时间选择当前展示项。

## 5. 安装器与 Doctor

### 5.1 安装器

`install.sh` / `install-codex-hooks` 新增：

- 安装 `tmux-whistle-codex` 到 `~/.local/bin` 或仓库 bin 目录。
- 打印在 tmux 内推荐的启动方式。
- 检测 `daemon_auto_start=true`，提示共享 daemon 会破坏 pane 归因。
- 可选参数 `--codex-no-daemon`：
  - 对指定 `CODEX_HOME` 执行
    `codex features disable daemon_auto_start`。
  - 这是不使用 wrapper 时的替代方案，但会影响该 home 的所有 Codex TUI，
    必须显式选择。

### 5.2 Doctor

新增 Codex pane attribution 检查项：

- `CODEX_HOME` 与 Hook 路径是否存在。
- `daemon_auto_start` 是否为 true。
- 是否存在多个 Codex TUI 进程。
- 是否存在一个 daemon 被多个 TUI 客户端连接。
- 多个 TUI pane 中是否存在缺失 `WHISTLE_CODEX_PANE` 的进程。

任一高风险条件命中时 doctor 报错，而不是只给提醒：

```text
✗ 多个 Codex TUI 共用一个 daemon，pane 归因不可靠
  修复：使用 tmux-whistle-codex 重新启动这些 TUI
```

## 6. 迁移与兼容

### 阶段 1：可观测性

- 增加 binding resolver。
- 保留 `legacy` fallback。
- Hook 日志新增：
  - `binding=present|missing`
  - `pane_source=binding|legacy|none`
  - `client_id`
- doctor 能识别当前共享 daemon 场景。

### 阶段 2：启动器与多 pane 测试

- 安装 `tmux-whistle-codex`。
- 两 pane 真实 Codex 验收通过。
- `doctor` 对 raw `codex` 多 TUI 告警。

### 阶段 3：默认 strict

- `@whistle_codex_pane_mode` 默认改为 `strict`。
- 缺失 binding 时 Hook 不再写状态。
- 保留显式 `legacy` 一个版本用于回滚。

### 阶段 4：pane 内 session / subagent 聚合

- 引入 running session 集合。
- 引入 subagent id 集合。
- 完成并发 session 和并发 subagent 回归测试。

### 阶段 5：上游能力

向 Codex 上游争取稳定字段：

```text
client_id
client_session_id
tui/pane binding metadata
```

若 Hook 输入能携带稳定 client identity，则可重新支持 shared daemon，而不再要求
每个 TUI `--no-daemon`。这属于上游改进，不阻塞本插件的长期方案。

## 7. 测试矩阵

### 7.1 Wrapper

- tmux 内启动时注入正确的 `WHISTLE_CODEX_PANE`、socket、client id。
- tmux 内启动时立即写 `idle`，不依赖延迟的 `SessionStart`。
- 自动添加且不重复添加 `--no-daemon`。
- Hook 未安装到当前 `CODEX_HOME` 时给出明确错误。
- tmux 外运行不注入 pane binding。
- 参数、信号和退出码原样透传。

### 7.2 Hook resolver

- `WHISTLE_CODEX_PANE=%9`、`TMUX_PANE=%1` 时写 `%9`。
- binding 指到不存在 pane 时不写任何状态。
- binding socket 不匹配时不写任何状态。
- strict 模式缺失 binding 时不写状态，日志可见。
- legacy 模式保留旧行为。
- binding 与 `@whistle_cx_quiet` 组合工作。

### 7.3 多 pane 集成

在同一个隔离 tmux server 中创建两个 pane：

```text
%a: Codex session A
%b: Codex session B
```

- A、B 同时 Submit → 两边都是 `running`。
- A Stop → A 为 `done + idle`，B 仍为 `running`。
- B Stop → B 为 `done + idle`。
- 在 A/B 之间切换 client 不改变状态归属。
- 后台 Stop 到达时 active pane 不同，也不改变状态归属。

### 7.4 多 session / 多 subagent

- 同一 pane 两个 session 都 running → pane running。
- 只结束一个 → pane 仍 running。
- 两个都结束 → pane done/idle。
- 两个 subagent 同时存在 → 停一个仍 running。
- summary fork 仍整段静默。

### 7.5 多 CODEX_HOME

- default home 和自定义 `CODEX_HOME` 分别安装后可独立上报。
- 其中一个 home 未安装 Hook 时，wrapper 错误信息点名对应路径。

### 7.6 Doctor

- 单 TUI + 独立 daemon → 绿。
- 多 TUI 共享 daemon → 红。
- 多 TUI 使用 wrapper 且 `--no-daemon` → 绿。
- raw `codex` 在 tmux 多 pane 运行 → 告警并给出修复命令。

### 7.7 真机验收

1. 在 `%1`、`%9` 分别运行 `tmux-whistle-codex`。
2. 两个 TUI 同时发起任务，状态栏同时显示两个 `▶`。
3. 结束其中一个，只有对应 pane 变成 `◆`。
4. 检查 Hook 日志：

```text
WHISTLE_CODEX_PANE=%1 TMUX_PANE=%1
WHISTLE_CODEX_PANE=%9 TMUX_PANE=%9
```

5. 切换 tmux client 到其它窗口后等待后台 Stop，状态仍写回原 pane。
6. 运行 `tmux-whistle doctor`，确认没有 pane binding 告警。

## 8. 验收标准

必须同时满足：

- 两个以上 Codex TUI 在不同 pane 并发运行时，activity 与通知互不串台。
- 共享 daemon 且无 binding 时绝不产生错误 pane 状态。
- Codex Desktop / VSCode 被明确标记为不支持，而不是伪造 pane 状态。
- 多个 `CODEX_HOME` 的 Hook 安装状态可诊断。
- 内部 summary fork 不产生通知。
- 并发 subagent 不会因先结束一个就提前回落 idle。
- 现有单 pane / 单 Codex 用户体验不回归。
- `make check` 全绿，并新增真实多 TUI 手工验收记录。

## 9. 风险与取舍

- `--no-daemon` 会增加每个 TUI 的启动成本和常驻内存，换取可靠的 pane 身份。
- 包装器要求用户改变启动习惯；不改变时只能使用 legacy 模式并接受告警。
- 全局关闭 `daemon_auto_start` 更省事，但会影响同一 `CODEX_HOME` 下所有 Codex
  TUI，必须由用户显式选择。
- Codex 上游修改 app-server 或 daemon 结构时，wrapper 需要同步验证
  `--no-daemon` 和 feature flag。
- 未在 tmux 内启动的 Codex 不提供 pane 级检测，这是产品边界，不是可猜测项。
