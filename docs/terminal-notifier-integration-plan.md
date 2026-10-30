# terminal-notifier 交互增强：技术开发方案与执行计划

> 日期：2026-10-30
> 状态：待实施；本文档本身不代表代码已完成
> 前置调研：[terminal-notifier-research.md](terminal-notifier-research.md)
> 目标版本：terminal-notifier 3.1+；保留旧版本与其它后端的基本降级能力

## 0. 目标与边界

### 0.1 目标

在现有桌面通知后端上完成一条可靠闭环：

```text
agent 上报 done / wait / error
  → macOS 显示带来源的通知
  → 用户点击
  → 唤起终端并跳到正确的 client / window / pane
  → 跳转成功后才已读
  → tmux 状态与 macOS 通知中心同步清理
```

同时做到：

- 同一 pane 的新通知替换旧通知，不同 pane 不互相覆盖。
- tmux 内 clear/read 能撤回对应的桌面通知。
- terminal-notifier 存在但失败时，仍能降级到 osascript / notify-send。
- doctor 能区分「命令存在」与「通知已授权」。

### 0.2 非目标

第一版不做：

- `-action` 动作按钮、`-reply` 文本回复；
- `-in` / `-at` 定时提醒或 snooze；
- 自定义 app bundle / 图标、通知截图；
- 事件历史、SQLite、Python TUI；
- 自动安装 terminal-notifier；
- 把 `--body` 的 400 字全文默认塞进横幅；
- 改变 `@whistle_os off` 的默认值。

### 0.3 必须保持的不变量

1. 活动通道 `@whistle` 与通知通道 `@whistle_notice` 正交；桌面已读只清通知通道。
2. 状态写入仍只有 core 这条链；hook 与 `run` 不直接调用 terminal-notifier。
3. `running` / `idle` 不发桌面通知。
4. POSIX sh：不用数组、`[[ ]]`、局部变量；临时变量带命名空间前缀。
5. `whistle_sanitize` 只用于 tmux format，不拿它代替 shell quoting。
6. 自动化测试只用隔离 socket，不读取或修改用户真实 tmux 配置，不发送真实桌面通知。
7. 不使用 `terminal-notifier -remove ALL`。

---

## 1. 总体设计

### 1.1 保留统一投递链

当前链路：

```text
whistle_finish
  → whistle_recompute_window / whistle_recompute_global
  → whistle_deliver <window> <有效态> <消息>
  → whistle_os_notify <window> <状态> <消息>
```

调整为：

```text
whistle_finish <pane> <写入通道>
  → whistle_deliver <window> <有效态> <消息> <pane>
  → whistle_os_notify <window> <状态> <消息> <pane>
```

`whistle_finish` 已经持有 `_ff_pane`，只需在两个 `whistle_deliver` 调用分支继续下传。
不要通过 `@whistle_win_pane` 反推来源：它代表窗口聚合赢家，不一定是本条通知的触发 pane。

建议签名：

```sh
whistle_deliver  <window> <state> <msg> <pane>
whistle_os_notify <window> <state> <msg> <pane>
```

内部调用点与相关测试同步更新。若为了兼容旧的直接函数调用保留第四参为空的能力，
空 pane 只能退化为普通通知，不能生成猜测目标的点击回调；生产路径必须总是传 pane。

### 1.2 桌面通知的数据结构

每条 terminal-notifier 通知需要以下信息：

| 数据 | 来源 | 用途 |
|---|---|---|
| session 名 | 由 window 查询 | `-title` |
| window 名 | 由 window 查询 | `-subtitle` |
| 状态与短消息 | 现有投递参数 | `-message` |
| pane ID | `whistle_finish` 下传 | group 与精确跳转 |
| socket 路径 | `#{socket_path}` | group 隔离与回调连接 |
| CLI 绝对路径 | `WHISTLE_SELF` | `-execute` |
| 可用于 tmux 的 PATH | 发送时环境 | 回调中的 CLI / tmux 定位 |
| 终端 bundle ID | 配置或环境检测 | `-activate` |

---

## 2. 通知身份与内容

### 2.1 group 规则

在 `lib/deliver.sh` 增加唯一构造函数，例如：

```sh
whistle_os_group <pane>
```

输出：

```text
tmux-whistle:<socket-path>:<pane-id>
```

示例：

```text
tmux-whistle:/tmp/tmux-501/default:%12
```

规则：

- socket 使用 tmux 自己报告的 `#{socket_path}`，不要从可能跨 server 继承的环境变量猜测。
- pane 使用稳定 ID `%N`，不使用可能重名的 window/session 名。
- group 不必哈希；它只作为 argv 传递，socket 中的 `/`、空格不影响 terminal-notifier。
- 发送与撤回必须调用同一个构造函数，禁止两处各拼一份。

效果：

- 同 pane 新通知替换旧通知，与 whistle「当前态」模型一致。
- 不同 pane 通知并存。
- 多 tmux server 不会因 `%N` 相同而互相删除。

### 2.2 内容映射

保持现有阅读顺序，只补 window 上下文：

| terminal-notifier | 内容 |
|---|---|
| `-title` | `tmux · <session>` |
| `-subtitle` | `<window-name>` |
| `-message` | `完成/等待/错误: <短消息>` |
| `-group` | socket + pane 的唯一身份 |

第一版继续使用短消息，长 `@whistle_notice_body` 仍保存在 tmux 中。
macOS 横幅本身会截断长文本，把 400 字塞进去不等于提供可靠的详情界面。

### 2.3 terminal-notifier 参数转义

增加后端专用值处理函数，不复用 `whistle_sanitize`：

- 对需要经 `NSUserDefaults` 读取的字符串，处理首字符为 `[`、`(`、`{`、引号等情况。
- 采用上游支持的「前导反斜杠」规则，并确保最终显示值不多出反斜杠。
- 至少覆盖 title、subtitle、message、group、execute、activate 的构造结果。

测试必须包含以 `[` 开头的 window 名或消息，防止通知静默消失。

---

## 3. 点击跳转设计

### 3.1 `-execute` 命令构造

回调调用内部子命令：

```sh
tmux-whistle --desktop-jump %12
```

但写入 `-execute` 的完整命令必须包含环境，例如：

```sh
PATH='<发送时可用于 tmux 的 PATH>' \
WHISTLE_TMUX_SOCKET='<socket-path>' \
'<WHISTLE_SELF 绝对路径>' --desktop-jump '%12'
```

要求：

1. `WHISTLE_SELF` 使用 CLI 已计算的绝对路径，不依赖回调时 PATH 查找 tmux-whistle。
2. PATH 要包含发送时解析到的 `tmux` 所在目录；仅传 CLI 绝对路径不够。
3. socket 显式写入 `WHISTLE_TMUX_SOCKET`，保证连接原 server，而不是默认 server。
4. pane ID 直接保存，不在回调时读取窗口代表 pane。
5. CLI 路径、socket、PATH 分别做 POSIX single-quote；不能拼未经转义的 session 名或消息。
6. 构造与测试使用 argv，不把用户文本再交给一层未控制的 `eval`。

POSIX sh 没有数组；构造 terminal-notifier 参数时可用函数内的 `set --` 累积 argv，
先保存原有位置参数，再执行 `terminal-notifier "$@"`。

### 3.2 `-activate` 与终端识别

新增用户配置：

```text
@whistle_os_app    默认空
```

含义：点击通知时要激活的 macOS 应用 bundle ID，例如：

```tmux
set -g @whistle_os_app 'com.googlecode.iterm2'
# 或
set -g @whistle_os_app 'com.apple.Terminal'
```

选择顺序：

1. 非空 `@whistle_os_app`；
2. 可靠的进程环境 bundle 信息；
3. 对明确识别的 `$TERM_PROGRAM` 做小型映射；
4. 无法识别则省略 `-activate`。

不要把未知值猜成 iTerm2。省略 activate 只意味着「不主动唤起应用」，不影响严格跳转的已读判据。
上游源码保证同时提供时先 activate、后 execute。

限制：activate 只能保证应用到前台；macOS 终端有多个窗口/标签时，精确聚焦某个 OS 标签取决于终端应用本身。
本方案承诺的是 tmux client/window/pane 正确，不额外承诺所有终端的 OS 标签聚焦。

### 3.3 内部 `--desktop-jump` 的严格语义

新增内部分派：

```text
--desktop-jump <pane>
```

不要把现有 `cmd_jump` 原样拿来用：它忽略 `switch-client` 错误后仍 clear，也没有桌面回调所需的 client 选择。

建议把可测试的核心逻辑抽成函数，由 CLI 分派调用：

```text
1. 验证目标 pane 存在；不存在则失败。
2. 查询目标 pane 的 window ID 与 session。
3. 在点击时列出 attached clients，选择 client_activity 最新者。
4. 没有 attached client：失败，保留通知。
5. switch-client -c <client> -t <session>。
6. select-window -t <window>。
7. select-pane -t <pane>。
8. 5～7 全部成功后，才执行现有 clear + border release + refresh。
9. 任一步失败：非零退出，输出原因，不清通知。
```

client 在**点击时**选择，而不是发送通知时固化：用户可能在通知到达后切换或新附着 client。
使用 shell 的 `&&` / 显式错误分支保证短路；不要用会继续执行的 tmux `;` 链。

跳转成功后复用现有 clear 路径，意味着「进入该窗口 = 该窗口通知已读」，与当前菜单/jump 语义一致。
如果窗口内有多个 pane 通知，它们会一起已读，并分别触发精确 group 撤回；不引入第二套已读规则。

现有用户命令 `jump <窗口>` 第一版可保持原行为，避免把桌面回调改造扩大成用户语法变更。
其「失败仍 clear」问题可另开修复任务，不让本方案依赖它。

---

## 4. 已读与桌面撤回

### 4.1 唯一挂载点

在 `lib/deliver.sh` 增加：

```sh
whistle_os_forget <pane>
```

行为：

- 能定位 terminal-notifier 时，执行 `terminal-notifier -remove "$(whistle_os_group "$pane")"`。
- 没有匹配通知也视为成功，保持幂等。
- 工具不存在则跳过；执行失败写 debug 日志。
- 不把撤回失败返回成状态清除失败，也不回滚已读。

挂载到 `lib/core.sh` 的 `whistle_state_clear`：只有 tmux 通知通道清除成功后，才调用撤回钩子。
因为 core 可以独立加载、且 source 顺序先于 deliver，调用时使用函数存在性 guard：

```text
若 whistle_os_forget 已定义 → 调用
否则                         → 跳过
```

这样覆盖所有现有路径：

- `whistle_clear_window`；
- `whistle_clear_all`；
- `whistle_read_window` 经 clear window；
- `whistle_read_pane`；
- 桌面跳转成功后的 clear。

不逐个在 CLI、focus hook、菜单里另写撤回，避免新增入口时漏掉。

### 4.2 与 `@whistle_os` 的关系

撤回不受 `@whistle_os on` 门控。典型场景：

```text
通知已送达 → 用户关掉 @whistle_os → 在 tmux 内已读
```

此时仍应撤回旧桌面通知。开关只阻止新通知，不应让旧通知永久残留。

### 4.3 双通道安全

撤回钩子放在通知通道 `whistle_state_clear`，绝不放进 `whistle_activity_clear`。
测试必须断言：已读后 `@whistle` 的 running/idle 保持原值，只有 `@whistle_notice*` 被清除。

---

## 5. 后端降级与 doctor

### 5.1 发送失败继续降级

当前逻辑是「找到 terminal-notifier 就不再考虑其它后端」。改为按执行结果判断：

```text
若 terminal-notifier 存在：
  执行成功 → 返回
  执行失败 → 记录日志，继续
若 osascript 存在：
  执行成功 → 返回
  执行失败 → 记录日志，继续
若 notify-send 存在：
  执行并记录结果
否则：
  记录没有可用后端
```

保持 fire-and-forget：桌面通道失败不影响 agent 状态写入和 `run` 的退出码。
osascript / notify-send 没有本方案的精确跳转与 group 撤回能力，文档中明确它们是基本提醒降级。

### 5.2 doctor

terminal-notifier 3.x 可用时：

- 执行 `terminal-notifier -diagnose`；
- 展示授权、提醒样式、Focus/Scheduled Summary 等诊断结果；
- 未授权时给出系统设置路径；
- 不再只输出「terminal-notifier 可用」。

旧版本：

- 不支持 `-diagnose` 时提示升级；
- 不把「选项不存在」误判成「通知未授权」；
- 基本发送能力可继续保留。

doctor 的 PATH 与 Claude Code hook 的 PATH 可能不同。文档需要说明 doctor 通过不代表 hook 环境一定相同，
回调与 hook 失败仍可查看 whistle debug 日志和 terminal-notifier 系统日志。

### 5.3 安装与使用文档

后续修改 `install.sh`、`README.md` 和 CLI help：

- terminal-notifier 是可选依赖，不自动安装；
- 推荐 3.1+，v3 要求 macOS 10.14+；
- 说明 `@whistle_os`、新增 `@whistle_os_app`；
- 说明点击跳转、逐 pane 替换、已读撤回与降级边界；
- 安装后的授权提示按实际可用后端输出，不再无条件只讲 Script Editor。

---

## 6. 任务执行计划

统一原则：每个阶段先补能复现缺口的测试，再实现；不要一次性把「发送、跳转、已读、撤回」写成不可定位的大改动。

### T1：通知身份、参数传递与可靠发送

**目标**：不改跳转行为，先建立正确的桌面通知数据基础。

修改：

- `bin/tmux-whistle`：`whistle_finish` 下传精确 pane。
- `lib/deliver.sh`：扩展 deliver/os_notify 参数；增加 group、socket、terminal-notifier 值转义与 shell quote helper。
- `lib/deliver.sh`：发送按执行结果降级。
- `test/integration/deliver.bats`：fake terminal-notifier / osascript / notify-send 记录 argv 与退出码。

验收：

- 两个 pane 得到不同 group；同 pane 重复发送使用同一 group。
- group 含 socket，回调不含猜测的 `@whistle_win_pane`。
- subtitle 含 window，特殊首字符不会导致值丢失。
- terminal-notifier 假失败后会调用 osascript，再失败可调用 notify-send。
- running/idle 不发桌面通知。

### T2：严格桌面跳转与终端激活

**目标**：点击回调能定位精确 pane，且失败不会误已读。

修改：

- `bin/tmux-whistle`：新增内部 `--desktop-jump` 分派与可测试核心函数。
- `lib/deliver.sh`：构造 execute/activate 参数。
- `lib/core.sh`：`WHISTLE_DEFAULTS` 登记 `@whistle_os_app` 默认值。
- `test/integration/cli.bats` 与投递测试：覆盖 client 选择、严格错误路径与 argv。

验收：

- 回调包含 CLI 绝对路径、socket、确定性 PATH 与来源 pane。
- 无 client、死 pane、switch/select 任一失败时通知仍在。
- 只有完整成功路径才 clear，并正确释放边框/刷新。
- 未识别终端时不传 activate，不猜 bundle ID。

### T3：clear/read 同步撤回

**目标**：tmux 内已读与 macOS 通知中心一致。

修改：

- `lib/deliver.sh`：实现 `whistle_os_forget`。
- `lib/core.sh`：`whistle_state_clear` 成功后调用 guarded 撤回钩子。
- `test/integration/deliver.bats`、相关 clear/read 测试。

验收：

- window clear、clear all、window focus read、pane read 都调用精确 `-remove`。
- 同一 window 多 pane 已读时逐 group 撤回，不调用 ALL。
- `@whistle_os off` 后仍能撤回旧通知。
- 活动通道 running/idle 不变。
- core 独立加载时没有 deliver 函数也不报错。

### T4：doctor、安装提示与使用文档

**目标**：让用户能开启、授权、诊断并理解真实行为。

修改：

- `bin/tmux-whistle`：doctor 与 help。
- `install.sh`：按后端输出授权提示。
- `README.md`：安装、配置、点击、撤回、降级和故障排查。

验收：

- 3.x doctor 使用 `-diagnose`，未授权有明确提示。
- 旧版本不会把不支持诊断误报成未授权。
- 文档中的命令、option 名与实现一致。
- 没有宣称 activate 能精确聚焦所有终端的 OS 标签。

### T5：全量回归与人工 GUI 验收

**目标**：同时证明自动化逻辑与真实 macOS 点击链路。

执行：

1. `make fmt`。
2. `make check`，确认 lint、fmt-check、单元/集成/e2e 全绿。
3. 确认没有其它 bats 并发；`check-no-stray-servers` 必须通过。
4. 按第 8 节进行人工 GUI 验收。
5. 清理隔离 server、socket 与测试通知。

---

## 7. 自动化测试矩阵

| 维度 | 用例 | 预期 |
|---|---|---|
| 开关 | `@whistle_os off` | 不调用任何发送后端 |
| 状态 | running / idle | 不发桌面通知，不影响徽章与活动通道 |
| group | 同 pane 两次、不同 pane、不同 socket | 同 pane 身份稳定；其余互不冲突 |
| 内容 | 空消息、Unicode、`[` 开头、引号、反斜杠 | argv 正确，通知值不丢失 |
| execute | 路径/ socket 含空格或单引号 | shell 解析后仍是原始 argv |
| activate | 显式配置、可识别环境、未知环境 | 正确 bundle / 自动值 / 省略 |
| 降级 | 命令不存在、执行失败、未授权退出码 | 按顺序降级，状态写入不受影响 |
| 跳转 | pane 不存在 | 非零，通知保留 |
| 跳转 | 无 attached client | 非零，通知保留 |
| 跳转 | switch/window/pane 任一步失败 | 非零，通知保留 |
| 跳转 | 多 client | 选择点击时最近活动 client |
| 已读 | window/all/pane/focus/桌面跳转 | 只清通知通道，精确撤回 |
| 撤回 | `@whistle_os` 已关闭 | 旧桌面通知仍撤回 |
| 撤回 | 无匹配 group / 工具不存在 | 幂等跳过，不让 clear 失败 |
| doctor | 3.x 已授权 / 未授权 / 旧版本 | 输出与实际状态一致 |

fake 后端只验证 argv、退出码和状态副作用；bats 不应向真实 macOS 桌面弹通知。

---

## 8. 人工端到端验收

### 8.1 前置条件

- terminal-notifier 3.1+ 已安装，`-diagnose` 显示 authorized。
- 使用隔离 tmux server 与测试 socket，不改用户主配置。
- 在一个 attached 终端 client 中操作；另准备第二个 client 验证多 client 选择。
- 记录测试 server socket、测试通知 group，验收后精确清理。

### 8.2 主流程

1. 开 `@whistle_os on`，在两个 pane 分别上报 `done` 与 `wait`。
2. 确认两条通知并存，window subtitle 正确；同 pane 再上报时只替换自己的通知。
3. 点击其中一条：
   - 终端应用被激活（已配置或可识别时）；
   - 正确的 client、window、pane 被选中；
   - 该窗口通知通道已读；
   - running/idle 活动通道保持；
   - 对应桌面通知消失。
4. 对另一组在 tmux 内分别用 `clear` 与切窗已读，确认 macOS 通知同步撤回。
5. 无 attached client 时点击：应失败且不清通知；重新附着后可再次点击。
6. 删除目标 pane 后点击旧通知：应失败且不能把其它 pane 的通知清掉。
7. 模拟 terminal-notifier 发送失败，确认 osascript 降级可用且状态写入正常。
8. 检查 doctor、debug 日志与 terminal-notifier 系统日志。

### 8.3 清理

- kill 隔离 server，并显式检查 socket 文件是否删除。
- 只按测试 group 撤回通知，不用 `-remove ALL`。
- 确认 `pgrep`/doctor 不显示遗留的 `whistle-test-*` server，避免影响 tmux-continuum。

---

## 9. 完成定义（Definition of Done）

只有全部满足才能宣布功能完成：

- [ ] T1～T4 的功能与测试均已合入。
- [ ] `make check` 全绿，ShellCheck / shfmt 通过。
- [ ] 没有残留隔离 tmux server。
- [ ] 两个 pane 的通知不再互相替换。
- [ ] 人工点击已验证精确跳转与成功后已读。
- [ ] 无 client、死 pane、切换失败均已验证不会误清。
- [ ] tmux clear/read 与 macOS 通知中心同步。
- [ ] 活动通道在全部已读路径中保持不变。
- [ ] doctor、README、安装提示与实际行为一致。

若只完成 fake 后端与 bats，不得宣称「点击通知已验证」；真实 GUI 验收是独立门槛。

---

## 10. 关键文件索引

| 文件 | 责任 |
|---|---|
| `bin/tmux-whistle` | `whistle_finish` 参数传递、内部桌面跳转分派、doctor/help |
| `lib/deliver.sh` | group、参数构造、execute/activate、后端降级、桌面撤回 |
| `lib/core.sh` | 配置默认值；通知通道清除后的 guarded 撤回钩子 |
| `lib/status-line.sh` | 现有 window/pane 已读入口，验证其汇聚行为不变 |
| `test/integration/deliver.bats` | 后端 argv、降级、撤回与双通道断言 |
| `test/integration/cli.bats` | 桌面跳转成功/失败语义 |
| `test/e2e/claude_hook.bats` | hook 到桌面后端的来源 pane 与不重复投递 |
| `install.sh` / `README.md` | 可选安装、授权、配置与故障排查 |
