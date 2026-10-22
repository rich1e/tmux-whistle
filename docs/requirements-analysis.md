## tmux plane 通知

在 Tmux 中，通常被称为 pane（面板），而不是 plane。如果你想在 Tmux 的某个面板中任务完成（或发生特定事件）时收到通知，有几种不同的实现方式。

1. 内置的面板监控功能（最推荐）

Tmux 自带了监控面板活动（Activity）或钟声（Bell）的功能。当后台面板有新输出时，状态栏会亮起提醒。
在 Tmux 中按下快捷键 Ctrl+b（默认前缀键），然后输入以下命令：
• 监控当前面板的活动： M-a 或输入命令 :setw monitor-activity on
• 监控当前面板的静默（无输出）： :setw monitor-silence 10（10秒无输出时通知，适合监控长时间运行的任务）
💡 效果： 当被监控的面板有变化时，状态栏（Status Bar）对应的窗口标签会高亮或变色。

2. 结合系统通知（最直观）

如果你希望任务结束时，Mac 或 Linux 桌面直接弹出一个系统级别的气泡通知，可以在你的命令后面用 && 或 ; 追加通知命令：

| 操作系统                    | 推荐命令      | 示例                                                                            |
| --------------------------- | ------------- |:------------------------------------------------------------------------------- |
| **macOS**                   | `osascript`   | `sleep 5 && osascript -e 'display notification "任务已完成" with title "Tmux"'` |
| **Linux (Ubuntu/Fedora等)** | `notify-send` | `sleep 5 && notify-send "Tmux" "任务已完成"`                                    |

1. 会声会色：终端响铃（最简单）

利用终端的蜂鸣声（Bell）来提醒你。你可以让 Tmux 在收到 Bell 信号时在状态栏显示通知。
1. 先在 Tmux 中开启钟声监控：
```bash
tmux set-window-option -g monitor-bell on
```
1. 在执行长命令时追加控制字符 \a（Bell）：
```bash
sleep 5; echo -e "\a"
```

如果你想让这些配置永久生效，可以把它们写入你的 ~/.tmux.conf 配置文件中：

```tmux
# 开启全局窗口活动监控
setw -g monitor-activity on
# 当有活动时，在状态栏弹出文本提示
set -g visual-activity on
```

你想实现的是状态栏高亮提醒，还是长任务结束时的桌面弹窗通知呢？告诉我你的具体使用场景（以及操作系统），我可以为你提供更精准的脚本！

## 开启了多个session,每个session都有agent在执行任务,希望了解任务执行的情况,例如:等待/执行完成。

为了监控多个 Tmux 会话（Session）中 Agent 任务的等待或执行完成状态，最有效的方法是编写一个轻量级的状态看板脚本。由于 Agent 运行在不同的会话中，直接肉眼观察非常低效。
你可以使用以下三种方案，从“全局概览”到“自动化弹窗”来管理你的 Agent：

### 方案一：一键查看所有 Session 状态（推荐 🛠️）

你可以在终端运行以下这行复合命令，它会遍历所有 Tmux 会话，并抓取每个会话当前活跃面板（Pane）的最后几行输出。你可以通过关键词（如 Success, Done, Waiting, Error）一眼看出 Agent 的状态：
```bash
tmux list-sessions -F '#S' | while read -r session; do 
  echo -e "\033[1;34m【Session: $session】\033[0m"; 
  tmux capture-pane -t "$session:" -p | tail -n 5; 
  echo "-----------------------------------"; 
done
```
请谨慎使用此类代码。
💡 进阶玩法： 把这段代码存为 watch_agents.sh，然后用 watch -n 5 --color ./watch_agents.sh 运行，就能每 5 秒自动刷新一次所有 Agent 的最新状态。

### 方案二：让 Agent 结束时主动修改 Session 名称 🏷️

如果你的 Agent 是通过 Shell 脚本启动的，可以让它在结束时自动重命名 Tmux Session。这样你只需输入 tmux ls 就能看到哪些完成了。
在你的 Agent 启动脚本中这样写：

| 阶段              | 脚本代码示例                                          | 效果                          |
| ----------------- | ----------------------------------------------------- | ----------------------------- |
| **1. 任务开始时** | `tmux rename-session -t "$TMUX_PANE" "agent_running"` | 会话名变为 `agent_running`    |
| **2. 运行 Agent** | `python run_agent.py`                                 | 执行你的 AI 或自动化任务      |
| **3. 成功结束时** | `tmux rename-session -t "$TMUX_PANE" "agent_done"`    | 会话名自动变为 `agent_done`   |
| **4. 失败结束时** | `tmux rename-session -t "$TMUX_PANE" "agent_failed"`  | 会话名自动变为 `agent_failed` |

### 方案三：利用 Tmux 状态栏（Status Bar）实时提示 🚦

如果你正在其中一个 Session 里工作，想知道其他 Session 的 Agent 有没有输出更新，可以利用 Tmux 的全局活动监控。
把以下配置加入你的 ~/.tmux.conf 中：
```
tmux
# 开启全局窗口活动监控
setw -g monitor-activity on

# 当非当前会话/窗口有输出变化时，在状态栏的最下面弹出一行文本提示
set -g visual-activity on

# 状态栏高亮显示有变动的会话标签
set -g window-status-activity-style fg=yellow,bg=black,bold
```

配置完成后，在 Tmux 中按下 Ctrl + b 然后输入 :source-file ~/.tmux.conf 生效。一旦其他 Session 的 Agent 完成任务打印出日志，你的状态栏就会闪烁或高亮提醒。
请问你的 Agent 任务通常是通过 Python 脚本运行，还是 Shell 脚本运行？如果能告诉我任务结束时控制台通常会打印什么结束关键词（例如 "Finished" 或 "Waiting..."），我可以帮你写一个完全自动化的监控面板脚本。

## 以上方案能监听运行在plane里面的agent运行状态吗?

可以的，完全能监听到。
在 Tmux 的底层逻辑中，Pane（面板）才是真正执行任务、输出日志的实体。Session（会话）和 Window（窗口）只是容器。
上文提到的方案完全是基于 Pane 的状态来实现的。为了让你更踏实，这里为你梳理以上方案是如何在跨 Session、跨 Pane 的情况下精准拿到 Agent 状态的：

🔍 方案底层是如何监听 Pane 的？

| 方案                   | 它对 Pane 的监听原理                                                                                                                           | 适用场景                                                                             |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| **方案一：日志抓取**   | 使用 `tmux capture-pane` 命令。它会直接克隆目标 Pane 屏幕上的历史文本。只要你的 Agent 输出过 `Done` 或 `Waiting`，就能被捕获。                 | **最实用。** 适合不破坏现有 Agent 脚本，想全局一眼看清所有 Pane 进度的场景。         |
| **方案二：改名标记**   | 当 Agent 运行在某个 Pane 时，环境变量 `$TMUX_PANE` 会自动记录当前 Pane 的 ID（例如 `%1`）。脚本通过这个 ID 就能反向修改它所属的 Session 名字。 | **最直观。** 适合长耗时任务，你只需要输入 `tmux ls` 就能看到哪个会话的 Pane 跑完了。 |
| **方案三：状态栏高亮** | `monitor-activity` 监听的是**所有未激活 Pane 的 stdout（标准输出）流**。一旦某个 Pane 里的 Agent 从“静止”变成“打印新日志”，就会触发高亮。      | **最实时。** 适合你在看 A 面板时，想知道 B 面板的 Agent 是不是突然弹出了新状态。     |


💡 针对多 Session、多 Pane 的【终极监控脚本】

如果你的每个 Session 里都切分了多个 Pane（比如 Pane 0 在等待，Pane 1 在执行），可以用下面这个升级版脚本。它会穿透到每一个具体的 Pane，打印出具体是哪个 Session 的哪个 Pane 正在输出什么：
```bash
# 复制并直接在终端运行这段代码（也可以保存为 monitor.sh 配合 watch 命令使用）
tmux list-panes -a -F '#S:#W.#P' | while read -r pane_target; do
  echo -e "\033[1;35m【目标 Pane -> $pane_target】\033[0m"
  # 抓取该 Pane 屏幕的最后 3 行
  tmux capture-pane -t "$pane_target" -p | tail -n 3
  echo "------------------------------------------------"
done
```
参数解释： tmux list-panes -a 中的 -a 代表 All（所有）。它会强行横扫你后台开启的所有 Session、所有 Window 里的每一个 Pane，绝对不会漏掉任何一个正在运行的 Agent。
