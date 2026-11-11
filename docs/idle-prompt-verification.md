# idle_prompt 接入：现象、根因与验证记录

2026-11-11 · 关联 [TODO-19](./todo.md) · 实现提交 `a37ab1e`

本文记录一次完整的问题闭环：用户报「agent 在正文里问了一句，却没收到提醒」，
到根因定位、先验证后实现、再到真机回归。留档的目的是让下一次遇到
「某个通知类型到底会不会发」时，不必从头再猜一遍。

---

## 1. 现象

`work` 会话第二格（pane `%42`）里的 agent 在回合最后一句问：

> 需要我把启动方式固化下来（比如加 `.npmrc` 或 `dev:legacy` 脚本）吗？

同一轮里它起了两个后台 shell（`Bash(sleep 45; tail -20 …)`）。状态栏当时是：

```
▶ 运行中 [work]: claude.exe 后台: 2 个任务 · 格2
```

**没有任何 `◔`，也没有 `◆`** —— 用户完全收不到「它在等你答话」这件事。

## 2. 根因：三层各自断一次

| 环节 | 本该产生提醒的信号 | 实际发生 |
|---|---|---|
| 回合结束 `Stop` | 助手最后一句是提问 | `background_tasks` 非空 → 活动写 `running`，**通知通道一个字不写**（TODO-18 的设计） |
| 通知事件 | `Notification{idle_prompt}` | **matcher 里没有它**，hook 根本没被 spawn |
| 工具事件 | `AskUserQuestion`（精确的「他在问」） | 这个 agent 是在正文里用散文提问，**没有任何工具调用** |

关键点：`idle_prompt` 是唯一能表达「回合结束了、你一直没回」的信号，而它当时被
`lib/install-hooks.sh` 的 `NOTIFY_MATCHER` 挡在门外。

## 3. 方案

把 `idle_prompt` 映射成 `wait`，**但必须带两道守卫** —— 它每个回合结束 60 秒后都会发，
包括正常做完的那一轮：

- **通知通道为空**才写。已有 `◆` 就说明这一轮说过了；覆盖它会把「做完了」改写成
  「在等你」（rank `wait 4 > done 3`）。
- **活动态是 `running`** 才写。用户读掉 `◆` 之后活动是 `idle`，那是假空档。

徽章显示「等你回复」，英文原文（`Claude is waiting for your input`）进
`@whistle_notice_body`。

**为什么不做 `AskUserQuestion` 那条路**：实测中它已经通过 `permission_prompt`
产生了 `◔`（见 §4 的意外收获），选项 2 只多出「立即 vs +60 秒」，代价却是要新订阅
`PostToolUse` 并维护一盏需要清除的通知。故未采用。

## 4. 先验证再动手：探针实验

文档只说 `idle_prompt` 在「no background agent」时发。后台 **shell** 算不算
background agent，决定了整个方案是否成立 —— 所以在改代码前先用探针证明。

探针是**一次性**的：一个 `probe.sh` 加一份 `settings.json`，用
`claude --settings <file>` 只对那个会话生效，**不碰用户全局配置**。

```sh
# settings.json 订阅 Stop 与 Notification(idle_prompt)，都指向 probe.sh
# probe.sh 把 event / ntype / bg 数 / TMUX_PANE / 原始 payload 追加到 idle.log
```

实验步骤：新会话里让 agent「后台跑 `sleep 180`、不要等它、回合结束时用正文问我」，
发完切到别的 tmux 窗口，等 90 秒。

原始日志（`pane=%43`）：

```
2026-11-11 13:58:29  event=Stop  bg=1  pane=%43
  {"background_tasks":[{"type":"shell","status":"running","command":"sleep 180"}],
   "last_assistant_message":"…这轮到此为止。\n\n启动方式要不要固化？A 还是 B？"}

2026-11-11 13:59:29  event=Notification  ntype=idle_prompt  pane=%43
  {"message":"Claude is waiting for your input","notification_type":"idle_prompt"}
```

**结论**：

- 后台 shell 仍 `running` 时，`idle_prompt` **照样发**，延迟整 60 秒；
- 文档里的 "background agent" 指 background **subagent**，不含后台 shell；
- 后台 subagent 在飞时不发 —— 那条路仍是盲区（用户 2026-11-11 明确暂不处理）。

**意外收获**：同一次实验里 agent 选择了 `AskUserQuestion` 工具，pane 当时是
`activity=running` + `notice=wait`（`notice_msg=Claude needs your permission`），
来源是 `permission_prompt`。这说明「工具提问」本来就有提醒，选项 2 的价值很低。

## 5. 实现与测试

- `hooks/claude-code.sh`：`whistle_notify_state` 增加 `idle_prompt` → `wait`；
  Notification 分支加守卫与文案；新增 `_hk_notice()` 读通知通道。
- `lib/install-hooks.sh`：`NOTIFY_MATCHER` 增加 `idle_prompt`。
- `test/e2e/claude_hook.bats` 新增 3 条：补 `wait` / 不覆盖已有 `◆` / 非 `running` 不写。
- `test/integration/install_hooks.bats`：matcher 断言加 `idle_prompt`。

守卫的有效性做过**变异验证**：删掉那两行 `exit 0`，第 2、3 条用例立刻变红
（`◆` 被改写成 `◔`、假空档被误判成等待）。`make check` exit 0。

## 6. 真机回归

装完 hook、重启会话后重跑主场景，采样器每 2 秒抓一次 pane 状态
（`act=#{@whistle} notice=#{@whistle_notice} msg=#{@whistle_notice_msg}`），
与 hook 日志交叉对照。

**第一轮（主场景）**

| 时间 | hook 事件 | 采样到的状态 |
|---|---|---|
| 16:43:20 | `UserPromptSubmit` | `act=running` |
| 16:43:28 | `Stop` bg=1 | `running`，`notice=` 空 ← 空档形成 |
| **16:44:29** | **`idle_prompt`（+61s）** | **`notice=wait`，`msg=等你回复`** |
| 16:44:41 | （切进 pane，读侧 hook） | `notice` 清空 |

**第二轮（复现）**

| 时间 | hook 事件 | 采样到的状态 |
|---|---|---|
| 16:44:50 | `Stop` bg=1 | `notice=` 空 |
| **16:45:50** | **`idle_prompt`（+60s）** | **`notice=wait`，`msg=等你回复`** |
| 16:46:04 | （切进 pane） | `notice` 清空 |

**闭环（后台结束）**

| 时间 | hook 事件 | 采样到的状态 |
|---|---|---|
| 16:46:26 | `UserPromptSubmit` = `<task-notification>` | `running`，**跳过已读**（符合设计） |
| 16:46:29 | `Stop`（bg 已空） | `act=idle` + `notice=done`「后台任务 `b08vqit59` 已结束…」 |
| 16:46:44 | （切进 pane） | `notice` 清空 |

四个转换全部符合预期：**`Stop` 留空档 → +60 秒出 `◔` → 一读即清 → 后台结束回 `◆`**。

## 7. 已知边界

1. **后台 subagent 在飞时不发 `idle_prompt`** —— 「主回合结束 + 子 agent 还在跑 +
   正文提问」仍是盲区（用户明确暂不处理）。
2. **60 秒延迟是固有的**，`idle_prompt` 的语义就是「回完 60 秒你还没打字」。
3. **`◔` 会盖住 pane 徽章上的 `▶`**（rank `wait 4 > running 2`）。只要后台任务在飞，
   每个回合结束后 60 秒都会出现 `◔`，直到后台结束、Claude 被叫醒跑完那一轮才变 `◆`。
   汇总段仍是双通道分开计数（`▶N` 数活动、`◔N` 数通知）。
4. **它不读文案**：插件建模的是「回合结束了、你一直没回」，不是「它问了什么」。
   所以 agent 没真的问出问题，`◔` 照样会来。

## 8. 如何再验一次

```sh
tmux set -g @whistle_debug on          # hook 事件日志：${TMPDIR}/tmux-whistle-hooks.log
```

在**重启后**的会话里发：

```text
在后台跑 sleep 180（run_in_background: true），不要等它结束。
这一轮不要调用 AskUserQuestion 或任何交互式提问工具，也不要做需要我授权的事。
直接在回复正文的最后一句用普通文字问我：「启动方式要不要固化？A 还是 B？」
问完立刻结束这一轮，不要等我。
```

发完立刻切走，**60 秒内别在那个会话里打字**（打字会让 `idle_prompt` 不发）。
边跑边看：

```sh
while :; do
  date '+%H:%M:%S'
  tmux list-panes -a -F '#{pane_id}|#{@whistle}|#{@whistle_notice}|#{@whistle_notice_msg}' \
    | awk -F'|' '$2!=""||$3!=""||$4!=""'
  sleep 2
done
```

期望：`Stop` 那一行之后约 60 秒，出现 `notice=wait` + `等你回复`；切进那个 pane 后消失。

测完 `tmux set -g @whistle_debug off`。
