# Codex 屏幕 fixtures

这些文件是从真实 Codex TUI 抓取的文本快照，用来校验读屏规则，不能用手写
界面替代。

## 采集环境

- Codex CLI：`0.171.0`
- 日期：`2026-11-26`
- 平台：macOS
- 隔离 tmux server，固定 `120x40` / `80x24`
- 临时 `CODEX_HOME` 与工作目录，不使用用户 session、hooks 或项目配置
- 使用 `tmux capture-pane -p -J`，保留被终端宽度折行的逻辑行

采集时使用了两个无害提示：

```text
Reply with exactly OK. Do not run tools.
Run exactly this shell command and wait for approval if required: ...
```

权限提示出现后直接按 `Esc` 取消，未执行命令。所有临时路径替换为
`$FIXTURE_ROOT` / `$FIXTURE_TMP` / `$FIXTURE_OUT`，行尾空白已去掉。

## 文件

| fixture | 期望分类 | 关键真实信号 |
|---|---|---|
| `codex-0.171.0-idle-120x40.txt` | `idle` | `› Ask Codex to do anything` |
| `codex-0.171.0-idle-80x24.txt` | `idle` | 窄屏下的同一占位文案 |
| `codex-0.171.0-idle-after-turn-120x40.txt` | `idle` | 助手回复后仍有同一占位文案 |
| `codex-0.171.0-running-120x40.txt` | `running` | `• Working (0s • esc to interrupt)` |
| `codex-0.171.0-permission-wait-120x40.txt` | `wait` | `Press enter to confirm or esc to cancel` |
| `codex-0.171.0-trust-wait-120x40.txt` | `wait` | `Trust this folder?` + `enter continue · esc back` |
| `codex-0.171.0-scroll-freeze-80x24.txt` | `freeze` | `enter/esc latest` + `↓ Back to bottom · esc` |
| `codex-0.171.0-transcript-scroll-freeze-120x40.txt` | `freeze` | transcript 滚动后的 `↓ Back to bottom · esc` |

`manifest.tsv` 是机器可读的期望表，后续分类器测试应直接消费它。

## 对原计划的验证结果

按计划中的 Codex 规则执行，8 个 fixture 只有 running 通过：

| fixture | 原计划结果 | 原因 |
|---|---|---|
| 三个 idle 样本 | 空 | 真实提示行带占位文案，不是空的 `›` |
| permission wait | 空 | 全屏没有 `─{3,}` 分隔线，`after_rule` 为空 |
| trust wait | 空 | 真实文案是 `Trust this folder?`，不是原计划固定句 |
| 两个 freeze 样本 | 空 | 真实文案是 `Back to bottom` / `enter/esc latest` |
| running | `running` | 计时器和 `esc to interrupt` 仍匹配 |

结论：`after_rule` 不能作为 Codex wait 的唯一入口；idle、wait、freeze 规则都
需要用这些 fixture 重写。规则应优先匹配当前版本，再保留明确标注的旧版兼容
分支，不能继续沿用未验证的手写样例。

## 重新采集

1. 预先准备一份只包含测试 provider 配置的临时 `CODEX_HOME`，再启动隔离 tmux：

   ```sh
   FIXTURE_HOME=/tmp/codex-fixture-home
   FIXTURE_WORK=/tmp/codex-fixture-work

   tmux -L whistle-codex-fixture -f /dev/null \
     new-session -d -s cap -n codex -x 120 -y 40 \
     "env CODEX_HOME='$FIXTURE_HOME' codex --no-daemon -C '$FIXTURE_WORK' -a on-request -s read-only"
   ```

2. 正常空闲时抓取 idle。
3. 输入无工具提示，在 `Working` 出现时抓取 running，结束后抓取 idle-after-turn。
4. 要求执行一个需要审批的写命令，在 `Press enter to confirm or esc to cancel`
   出现时抓取 permission-wait，随后按 `Esc` 取消。
5. 在临时 Git 仓库中启动 Codex，抓取 `Trust this folder?` 页面。
6. 按 `Ctrl-T` 打开 transcript，再按 `PageUp`，抓取 scroll-freeze。
7. 统一执行：

   ```sh
   tmux -L whistle-codex-fixture capture-pane -p -J -t cap:0.0
   ```

8. 替换临时路径、去掉行尾空白，并人工确认没有 token、用户名或业务内容。

固定宽度只能减少偶然差异，不能消除 Codex 版本变化。升级 Codex 后应新增版本化
fixture，而不是覆盖旧 fixture 后假装兼容。
