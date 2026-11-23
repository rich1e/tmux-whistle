# 为什么 Codex 需要 `tmux-whistle-codex`

## 结论

根因是 Codex 当前进程模型带来的技术限制；`tmux-whistle-codex` 是将该限制
转化为可靠 pane 归因的架构方案，而不是单纯为了统一三个 Agent 的接入方式。

## Codex 的特殊性

Codex 的 managed app-server daemon 按 `CODEX_HOME` 复用。daemon 的环境变量
来自“第一个启动它的 TUI”，之后连接同一 daemon 的其他 TUI 不会刷新
`TMUX_PANE`、`TMUX` 等启动快照。

同时，Codex Hook payload 只有 `session_id`、`turn_id`、`cwd`、
`transcript_path` 等字段，没有可信的 pane/client identity。因此多个 TUI
共用 daemon 时，后启动的 TUI 事件会被写到第一个 TUI 的 pane：

```text
TUI A 在 %1
TUI B 在 %9
两者共用 daemon，daemon 环境里是 TMUX_PANE=%1
B 的 Hook 事件也会写到 %1
```

这不是 Hook 丢失，而是共享 daemon 抹平了 client 身份。仅修改
`hooks/codex.sh` 无法恢复 B 的真实 pane；按 cwd、active pane、窗口标题或
进程名猜归属，又会在多 TUI 和异步事件场景下误报。

## 三个 Agent 的差异

| Agent | 可信 pane 来源 | 是否需特殊启动命令 |
|---|---|---|
| Claude Code | Hook 在 pane 本地进程树中执行，继承正确的 `TMUX_PANE` | 否 |
| OpenCode | TUI 插件运行在 TUI 进程中，主动把 `TMUX_PANE` 传给 Hook；共享 server 的旧环境被绕过 | 否 |
| Codex | managed daemon 复用后的环境是启动快照，Hook payload 又没有 client identity | 默认 `strict` 下需要 |

所以并不是“Codex 不会上报”，而是**上报后无法确定它属于哪个 TUI/pane**。

## 启动器的职责

`tmux-whistle-codex` 在启动 Codex 前完成以下工作：

1. 捕获并校验当前 `TMUX_PANE` 与 tmux socket，注入 `WHISTLE_CODEX_*`
   PaneBinding。
2. 强制追加 `--no-daemon`，防止 Codex 复用已有 daemon 的旧环境。
3. 建立绑定后先写一次 `idle`，保证 strict 模式下的新 TUI 能立即出现在状态栏。

最终执行：

```sh
exec codex --no-daemon "$@"
```

其中：

- PaneBinding 提供可信的 pane 归属。
- `--no-daemon` 保证 Codex client、session runtime 和 Hook 子进程处于同一个
  pane 本地进程树，绑定不会被共享 daemon 的启动快照覆盖。
- 启动时写入 `idle` 是因为当前 Codex 可能到首个 prompt 才触发
  `SessionStart`；strict 模式又不会按进程名猜状态。

## 是否绝对必须

特殊启动器针对的是**可靠的多 pane 归因**，并非 Codex 的每个运行场景都只能
通过这种方式工作：

- 把 `@whistle_codex_pane_mode` 设为 `legacy`（或迁移期的 `auto`）后，可以
  直接运行 `codex`，继续信任继承的 `TMUX_PANE`。
- 但共享 daemon 或后续 TUI 复用旧环境时，状态会静默写到错误的 pane。
- 默认 `strict` 因此选择 fail closed：没有可信 PaneBinding 就不写状态。
  宁可不显示，也不能把状态显示到错误的 pane。
- 也可以全局关闭 Codex daemon auto-start，但这会影响该 `CODEX_HOME` 下的
  所有 Codex；且 `strict` 仍要求 PaneBinding，需要配合其他模式使用。

## 未来是否可以去掉启动器

如果 Codex 上游能在 Hook payload 中提供稳定的 `client_id`、
`client_session_id` 或 TUI/pane binding metadata，`hooks/codex.sh` 就可以直接
恢复事件归属，届时无需强制 `--no-daemon`，也不必要求用户通过
`tmux-whistle-codex` 启动。
