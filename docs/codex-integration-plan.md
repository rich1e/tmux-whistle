# Codex 接入：事件映射与实现记录

> 目标：让 Codex CLI 与 Claude Code、OpenCode 并列成为 tmux-whistle 的一等推送源。
> 实测环境：Codex CLI `0.167.2`，tmux 3.8，macOS；接口依据 OpenAI 官方
> [Codex Hooks](https://developers.openai.com/codex/hooks)（2026-11-13 读取）。

## 1. 为什么用 hooks，不用 `notify`

Codex 的 `notify` 只在 `agent-turn-complete` 时调用外部程序，能覆盖「做完了」，
但覆盖不了「正在跑」「等你批准」「用户打断」「子 agent 还在跑」。
这些状态只能从生命周期 hooks 得到，所以本接入使用 `~/.codex/hooks.json`。

官方文档确认：

- hooks 从 `hooks.json` 或 `config.toml` 的 inline `[hooks]` 加载；
- 非 managed hook 必须先由用户审核并信任，信任绑定到 hook 当前哈希；
- CLI 里用 `/hooks` 审核、信任或禁用；
- 同一层同时存在 `hooks.json` 与 inline `[hooks]` 时会合并并警告。

## 2. 事件映射

| Codex hook | whistle 写入 | 说明 |
|---|---|---|
| `SessionStart`（`startup` / `resume` / `clear`） | 活动通道 `idle` | 会话活着，但停在提示符前等人 |
| `SessionStart`（`compact`） | 不写 | 轮中压缩，不能把正在转的 `▶` 掐掉 |
| `SessionStart`（`fork`） | 不写 | 可能是用户分支，也可能是后台摘要；不能覆盖父会话状态 |
| `UserPromptSubmit` | 活动通道 `running` + 清通知 | 真正的用户输入才开始干活；episodic-memory 摘要 marker 例外 |
| `PermissionRequest` | 通知通道 `wait` | 即时；优先用 `tool_input.description`，退回 `tool_input.command` / `tool_name` |
| `PostToolUse` | 只清 `wait` | 工具已真正运行，说明授权已解决；不改活动态 |
| `SubagentStart` | `--sub-agent-start` | 只写 `@whistle_sub`，活动态由推导层合成 |
| `SubagentStop` | `--sub-agent-stop` | **只清标记**，主 agent 通常还在跑 |
| `Stop` | 活动 `idle` + 通知 `done` | `last_assistant_message` 首行进徽章，全文进 body；内部会话跳过 |
| `Interrupt` | 活动 `idle` + 清 wait | 用户打断后不会有 `Stop`，必须在这里收尾 |
| `SessionEnd` | `--clear-pane`（活动 `gone`） | 保留未读通知；内部会话跳过并回收 quiet id |

`SessionStart(source=fork)` 本身无法区分用户 fork 与后台 ephemeral fork，所以不动状态。
episodic-memory 的摘要 prompt 以固定 marker 开头；hook 命中后把该 `session_id` 写入
pane option `@whistle_cx_quiet`，后续同一 session 的所有事件都跳过。这样后台摘要不会
覆盖父会话 activity、清掉未读通知、写 `gone` 或发送桌面通知。

刻意不订阅：

- `PreToolUse`：`UserPromptSubmit` 已把整轮点亮为 `running`；异步 PreToolUse 若晚于
  Stop 写入，会把已经结束的 pane 永久留成 `▶`。
- `PostModelRequest`：它按每次模型请求尝试触发，重试失败不代表整回合失败，容易误报。
  Codex 目前没有与 Claude `StopFailure` 等价、能稳定表达「最终失败」的事件。

## 3. 同步与异步

Codex hooks 默认同步；设置 `async: true` 后在后台运行。本接入只把 `PostToolUse`
设为异步：

- 它是高频事件；
- 它只清通知通道的 `wait`，不改「谁在干活」；
- 即使晚到，最多错过一次清理，不会留下永久 `running`。

其余事件同步，保证一个轮次内的写入顺序：

```text
SessionStart(idle) → UserPromptSubmit(running) → Stop(idle + done)
```

后台摘要的预期链路：

```text
SessionStart(fork, 不写) → UserPromptSubmit(marker, 记 quiet id) → Stop/SessionEnd(跳过)
```

`SessionEnd` / `Interrupt` 在 Codex 侧还有 1~3 秒超时限制，安装器给它们 2 秒，
其余 5 秒；hook 本身只做 tmux 写入，正常远低于超时。

## 4. 安装与信任

`lib/install-codex-hooks.sh`：

1. 读取 `~/.codex/hooks.json`（可用 `CODEX_HOOKS` 覆盖）；
2. 先备份；
3. 每个事件保留所有第三方条目，**追加**一个带 `tmux-whistle` marker 的 matcher 组；
4. 重复执行幂等；卸载只删除带 marker 的条目；
5. `lib/install-agent-hooks.sh` 同时调用 Claude 与 Codex 两个合并器。

**不能前插。** 实测 `~/.codex/config.toml` 的 `[hooks.state]` 用
`<hooks.json 路径>:<event>:<index>` 记录 `trusted_hash`。把我们的条目插到前面会让
已有第三方条目的 index 变化，信任随之失效。

安装完成后必须在 Codex 里输入 `/hooks` 审核新增条目。安装器不会修改
`config.toml` 的信任状态，doctor 也不会猜 Codex 的哈希格式。

## 5. 已知限制

- Codex 不在 tmux 里时没有 `TMUX_PANE`，hook 静默退出。
- 权限被拒绝且没有后续 `PostToolUse` / `Stop` / `Interrupt` 时，`wait` 可能留到下一次
  用户输入或退出事件。
- 子 agent 标记仍是单值 + TTL，不支持精确计数；多个子 agent 并发时只能表达
  「至少还有一个在跑」。过期兜底见 `@whistle_sub_ttl`。
- Codex 的 `SessionEnd` 可能延迟到会话空闲 30 分钟后才触发；正常退出或关闭会话时会运行。
- Codex API 错误没有稳定的一等失败事件，不自动写 `error`。
- 内部摘要识别依赖 episodic-memory 的稳定 prompt marker；对方改名后需要同步更新
  `hooks/codex.sh` 的 `_CX_INTERNAL_PROMPT_MARKER`。

## 6. 验证

- `test/e2e/codex_hook.bats`：事件映射、双通道正交、子 agent、权限等待、打断、退出、
  畸形 JSON、debug 日志。
- `test/integration/install_codex_hooks.bats`：第三方 hook 保留、追加顺序、幂等、
  卸载、dry-run、非法 JSON、聚合入口。
- `test/integration/doctor.bats`：逐事件列出订阅、async 漂移、路径漂移、inline hooks 冲突。

2026-11-13 另做了两次隔离真机验证（临时 `CODEX_HOME` + 独立 tmux server，
Codex `0.167.2`）：

```text
SessionStart startup  → idle
UserPromptSubmit      → running
Stop                  → idle + done("OK")
SessionEnd            → gone（done 保留）
```

- `codex exec --dangerously-bypass-hook-trust --ephemeral`：四个事件全部触发。
- 真实 TUI（默认共享 daemon，带 `--no-alt-screen`）：在 tmux pane 里同样拿到
  正确的 `TMUX_PANE=%1`，`SessionStart / UserPromptSubmit / Stop` 全部命中；
  退出后 `SessionEnd` 把活动态收成 `gone`，`done("OK")` 保留。

`hooks.log` 中所有事件都带 `agent=codex` 与正确 pane id，证明 Codex（含 TUI
daemon 路径）确实继承 pane 环境并调用了适配器。
