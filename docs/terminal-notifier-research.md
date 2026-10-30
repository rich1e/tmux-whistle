# terminal-notifier 调研：能力与 tmux-whistle 交互价值

> 日期：2026-10-30
> 上游版本：terminal-notifier 3.1.0（2026-08-30 发布）
> 对照实现：tmux-whistle `8d2e4c5`
> 调研方式：上游 README、`AppDelegate.m`、release 信息，以及本机 3.1.0 的 `-help` / `-diagnose`

## 0. 结论摘要

tmux-whistle **已经接入基础 terminal-notifier**：`lib/deliver.sh` 会优先调用它发送桌面通知。
当前缺口不是「能不能弹窗」，而是通知仍然缺乏交互与生命周期管理：

- 所有 pane 共用固定 `-group tmux-whistle`，不同来源的通知会相互替换。
- 没有点击跳转；用户看到通知后，还要自己找 session、window、pane。
- tmux 内已读或清除后，macOS 通知中心里的对应项不会撤回。
- 后端存在但执行失败时不会继续降级，doctor 也没有检查真实授权状态。

最值得接入的四项能力是：

1. **`-execute` + `-activate`**：点击通知，唤起终端并回到产生通知的精确 pane。
2. **逐 pane `-group`**：同一 pane 的新状态替换旧状态，不同 pane 不再互相顶掉。
3. **`-remove`**：tmux 内已读、清除后，同步移除对应的 macOS 通知。
4. **`-diagnose`**：把「命令存在但通知没出现」变成可诊断问题。

`-action`、`-reply`、`-in` / `-at` 都有潜在用途，但会引入后台等待进程、额外状态对账或回复安全边界，不建议进入第一版。

---

## 1. terminal-notifier 是什么

terminal-notifier 是一个通过 macOS `UserNotifications` 框架发送系统通知的命令行工具。
通知必须归属于一个应用，因此它以 app bundle 形式提供，而不只是一个裸可执行文件。

```sh
brew install terminal-notifier

terminal-notifier \
  -title 'Build' \
  -message 'Finished in 42s' \
  -sound default
```

版本边界：

- 当前 stable 为 **3.1.0**；本机 Homebrew 安装的也是 3.1.0。
- v3 要求 **macOS 10.14+**。
- v3 使用公开的 `UNUserNotificationCenter`，替代已废弃的 `NSUserNotification`。
- v3.1 新增 `-in` / `-at` 定时投递。
- 网上基于 v1/v2 的示例不一定适用于 v3，尤其是 `-sender`、`-appIcon`、`-ignoreDnD`。

---

## 2. 功能盘点

### 2.1 通知内容

| 选项 | 能力 | 集成时的注意事项 |
|---|---|---|
| `-message VALUE` | 通知正文；也可从 stdin 读取 | 与 `-remove`、`-list` 三者至少提供一个 |
| `-title VALUE` | 标题；默认是 `Terminal` | macOS 11+ 还会显示发送应用名 |
| `-subtitle VALUE` | 标题与正文之间的副标题 | 适合放 window 名，区分同一 session 的多条通知 |
| `-sound NAME` | 播放 `/System/Library/Sounds` 中的声音 | `default` 是系统默认音；不应硬编码成所有状态都响 |
| `-contentImage PATH` | 在通知内附带本地 PNG/JPEG/GIF | v3 只接受本地文件，不支持 v2 的远程 URL |

**特殊转义规则**：选项值经 `NSUserDefaults` 读取，首字符是 `[`、`(`、`{`、引号等内容时，
可能被当作 property list 解析，导致值读不出来、通知不发送。需要在值前加一个反斜杠，
例如 `'\[ZOMG] Everything is on fire'`。v3 会对无法读取的值报错，不再完全静默。

### 2.2 点击通知正文

| 选项 | 行为 | 适用场景 |
|---|---|---|
| `-execute COMMAND` | 通过 `/bin/sh -c` 执行命令 | 调用 tmux-whistle CLI，跳回精确 pane |
| `-activate BUNDLE_ID` | 把指定 macOS 应用带到前台 | 唤起 iTerm2、Terminal 等终端 |
| `-open URL` | 打开网页、文件或自定义 URL scheme | CI 链接、deep link；不适合未注册 URI handler 的 tmux |

上游源码确认：三者可以同时提供，点击后的顺序固定为：

```text
activate → execute → open
```

`-execute` 的重要限制：

- 是非交互 shell，**不会读取 dotfiles**。
- `PATH` 可能比终端里小，所以 CLI、socket 与 PATH 都必须显式处理。
- 不能只传 CLI 绝对路径就假定安全：CLI 内部的 `tmux` 仍按 PATH 查找。
- terminal-notifier 会同步等待命令结束；stdout/stderr 进系统日志，而不是调用方 stdout。
- 点击动作是否成功可在 Console.app 或 `log show` 中检查。

### 2.3 分组、替换、撤回与查询

| 选项 | 行为 | 对 tmux-whistle 的意义 |
|---|---|---|
| `-group ID` | 同组只保留一条，新通知替换旧通知 | 用「socket + pane」作为 ID，可让状态更新自然覆盖旧提醒 |
| `-remove ID` | 删除该组已送达通知，也取消该组待投递通知 | tmux 内已读后同步清理通知中心 |
| `-remove ALL` | 删除这个 app 发出的全部通知 | **不应使用**，可能误删其它脚本的 terminal-notifier 通知 |
| `-list ID` | 列出某组已送达通知 | 辅助诊断 |
| `-list ALL` | 列出全部已送达通知 | 可做遗留项排查，不必进入正常运行路径 |
| `-list PENDING` | 列出尚未触发的定时通知 | 只有采用定时功能后才需要 |

实现细节：group ID 同时用作通知请求 identifier；再次投递同组通知前，会移除旧的已送达和待发送请求。
`-remove` 按 `userInfo` 中的 group ID 精确匹配；没有匹配项时也返回成功，因此撤回操作是幂等的。

### 2.4 动作按钮与文本回复

`-action` 和 `-reply` 让通知变成交互式问答：

```sh
answer=$(terminal-notifier \
  -message 'Deploy to production?' \
  -action 'Yes,No' \
  -timeout 30)
```

可能输出：

| 输出 | 含义 |
|---|---|
| 按钮标题 | 用户点击了该动作 |
| 用户输入文本 | `-reply` 收到回复 |
| `@ACTIONCLICKED` | 点击正文而非按钮 |
| `@CLOSED` | 通知被关闭 |
| `@TIMEOUT` | 等待超时，退出码 6 |

这类调用与即时通知不同：**terminal-notifier 进程会一直存活到用户响应或超时**。
无人值守脚本必须提供 `-timeout`，否则可能永久等待。它们也不能与 `-in` / `-at` 组合，
因为定时注册后进程立即退出，没有进程继续接收答案。

### 2.5 定时投递

| 选项 | 示例 | 行为 |
|---|---|---|
| `-in DURATION` | `-in 30s`、`-in 5m` | 延时投递 |
| `-at TIME` | `-at 09:15`、`-at '2026-09-01 02:00'` | 在指定本地时间投递 |

通知交给 macOS 持有，调用进程退出后仍会触发。若需要取消，应在创建时提供 `-group`，
之后用 `-remove <group>`；无 group 的定时通知只能 `-remove ALL` 取消，因此不适合 whistle。

### 2.6 诊断与退出码

`-diagnose` 检查：

- 通知授权状态；
- 是否允许横幅/提醒、声音、通知中心和锁屏显示；
- 当前提醒样式与预览设置；
- Notification Center 是否运行；
- Scheduled Summary 是否暂缓投递。

本机 3.1.0 的诊断结果为「authorized / No problems found」，但本次调研**没有发送或点击真实通知**，
所以点击链路仍需要后续人工 GUI 验收。

主要退出码：

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 用法错误 |
| 2 | 参数无效或值无法读取 |
| 3 | 未获通知授权 |
| 4 | 通知服务连接超时，常见于无 GUI 登录会话 |
| 5 | 通知服务拒绝请求，或点击动作失败 |
| 6 | `-action` / `-reply` 等待超时 |

### 2.7 不应再依赖的旧能力

| 选项 | v3 状态 | 原因 |
|---|---|---|
| `-sender` | 已移除，只保留兼容警告 | 新框架读取真实签名身份，不能运行时伪装 bundle ID |
| `-appIcon` | 已移除 | 没有按通知覆盖图标的公开 API |
| `-ignoreDnD` | 通常无效 | time-sensitive 能力需要 Apple 授予 entitlement，发布二进制没有 |

自定义图标需要构建独立 app bundle；这还会产生独立的通知权限条目，不适合作为 whistle 第一阶段工作。

---

## 3. tmux-whistle 当前实现

### 3.1 调用链

```text
hooks/claude-code.sh / tmux-whistle run / 手写 done|wait|error
  → cmd_notice / cmd_set
  → whistle_notice_set                 写通知通道真源
  → whistle_finish                     重算并统一投递
  → whistle_deliver
  → whistle_os_notify
  → terminal-notifier / osascript / notify-send
```

桌面后端位于 `lib/deliver.sh:230`，优先级为：

```text
terminal-notifier → osascript → notify-send
```

当前 terminal-notifier 参数只有：

```sh
terminal-notifier \
  -title "$_title" \
  -message "$_body" \
  -group tmux-whistle
```

`@whistle_os` 默认是 `off`；只有 `done` / `wait` / `error` 会发桌面通知，
`running` / `idle` 只走状态展示，不主动打扰用户。这个行为应保留。

### 3.2 主要差距

| 现状 | 影响 |
|---|---|
| 固定 group 为 `tmux-whistle` | 所有 pane 的通知共享替换身份，无法并存或逐条撤回 |
| `whistle_finish` 有精确 pane，但投递时只传 window | 后端无法生成精确跳转回调 |
| 标题只有 session，正文只有状态与短消息 | 多条通知时缺少 window 上下文 |
| 没有 `-execute` / `-activate` | 点击不能回到现场，也不能保证终端应用到前台 |
| clear/read 只清 tmux 通知通道 | macOS 中留下可点击但已过期的通知 |
| `jump` 忽略 `switch-client` 错误后仍清通知 | 不能直接复用为桌面回调，否则可能「没跳到却已读」 |
| 后端执行失败只写 debug 日志 | 已安装但未授权时，不会继续尝试 osascript / notify-send |
| doctor 只检查 `command -v` | 「命令存在」被误当成「通知可用」 |
| `--body` 没有传给桌面通知 | 长正文仍只能在 tmux option 中手查 |

其中，精确 pane 不能通过事后读取 `@whistle_win_pane` 补回来：它只是窗口聚合时的代表 pane，
不一定是本次桌面通知的来源。

---

## 4. 哪些能力最能提升交互体验

### 4.1 第一优先级：点击通知回到现场

组合 `-activate` 与 `-execute`：

```text
用户点击通知
  → 唤起终端应用
  → CLI 使用通知中保存的 socket 连接正确 tmux server
  → 选择最近活动的 attached client
  → switch-client → select-window → select-pane
  → 全部成功后，才把通知标为已读
```

这把当前的「我告诉你某处有事」升级为「点一下就到处理位置」。
关键不是命令能不能执行，而是**任何一步失败都不能清除通知**，否则用户会失去唯一线索。

### 4.2 第一优先级：逐 pane 替换与已读撤回

建议 group 身份包含 socket 与 pane，例如：

```text
tmux-whistle:/tmp/tmux-501/default:%12
```

这样可以得到一致的生命周期：

- 同一个 pane 从 `done` 变成 `wait`：新桌面通知替换旧的，与 whistle 当前态模型一致。
- 不同 pane 各有一条通知：不再互相覆盖。
- 在 tmux 内切窗已读、执行 clear：对应桌面通知同步消失。
- 点击桌面通知完成跳转：跳转后的已读路径也会撤回它。

socket 必须进入 group，因为不同 tmux server 都可能存在 `%12`。

### 4.3 第一优先级：可诊断与可降级

`-diagnose` 能直接回答「为什么看不到通知」，适合接入 `tmux-whistle doctor`。
同时，terminal-notifier 执行失败应继续尝试 osascript / notify-send，而不是因为命令存在就停止降级。
这不会改变 whistle 的状态写入，只改善桌面通道的可靠性。

### 4.4 低成本增强：结构化内容与提示音

- `-subtitle` 放 window 名，标题继续放 session，正文继续放状态与短消息。
- `-sound` 可后续做成配置：`wait` / `error` 有声音，`done` 默认安静。
- 不建议第一版默认加声音，避免把现有视觉提醒突然变成听觉打扰。

---

## 5. 暂缓或不建议采用的能力

| 能力 | 判断 | 原因 |
|---|---|---|
| `-action` | 暂缓 | 「查看」已被正文点击覆盖；「稍后」需要状态与定时对账，且要有后台等待进程 |
| `-reply` | 不建议作为 agent 回复通道 | 没有安全可靠的回送协议；不能向可能已经复用或切换的 pane 盲发按键 |
| `-in` / `-at` | 暂缓 | 需要持久化定时身份，处理已读后取消、server 重启与过期通知 |
| `-open` | 不用于 pane 跳转 | tmux 没有现成 URI handler；额外注册 scheme 比直接 execute 更复杂 |
| `-list` | 仅作诊断 | 正常撤回只需精确 group，不必维护另一份通知索引 |
| `-contentImage` | 暂不需要 | 截图有文件管理与隐私成本，对状态提醒收益有限 |
| 自定义 app 图标 | 暂不需要 | 需要独立 bundle、签名/分发与单独授权 |
| `-ignoreDnD` | 不采用 | v3 发布构建通常没有对应 entitlement，不能承诺绕过 Focus |

---

## 6. 集成约束与风险清单

1. **回调环境**：必须显式携带 socket、CLI 绝对路径，以及能定位 `tmux` 的确定性 PATH。
2. **Shell quoting**：`whistle_sanitize` 是 tmux format 消毒，不是 shell 转义；execute 字符串要单独处理。
3. **参数转义**：window 名、消息等以特殊字符开头时，要遵守 `NSUserDefaults` 的前导反斜杠规则。
4. **精确来源**：pane 必须从 `whistle_finish` 传入，不能从窗口聚合结果猜测。
5. **client 选择**：桌面回调没有当前 tty/client，要在点击时选择 attached client，并处理无 client。
6. **已读时机**：只有目标存在且所有跳转步骤成功，才能走 clear/read。
7. **双通道不变量**：撤回桌面通知只跟随通知通道清除，绝不动 `@whistle` 活动通道。
8. **撤回范围**：只按 whistle 自己的精确 group 删除，禁止 `-remove ALL`。
9. **终端聚焦边界**：`-activate` 只能保证应用到前台；多终端窗口/标签的精确聚焦是终端应用能力，不能对 tmux 跳转成功混为一谈。
10. **版本差异**：`-diagnose` 只用于 3.x；旧版本不支持诊断不能误报成未授权。

---

## 7. 推荐落地范围

第一版只做一条完整、可验证的闭环：

> **逐 pane 通知 → 点击唤起终端并精确跳转 → 成功后已读 → 桌面通知同步撤回。**

同时补齐后端失败降级与 doctor 诊断。保持 `@whistle_os off` 默认值、统一投递链、
osascript / notify-send 降级和 POSIX sh 技术栈不变。

具体文件级设计、任务顺序与验收矩阵见
[terminal-notifier-integration-plan.md](terminal-notifier-integration-plan.md)。

## 8. 来源

- [terminal-notifier 仓库与 README](https://github.com/julienXX/terminal-notifier)
- [3.1.0 release](https://github.com/julienXX/terminal-notifier/releases/tag/3.1.0)
- [上游 AppDelegate.m](https://github.com/julienXX/terminal-notifier/blob/master/Terminal%20Notifier/AppDelegate.m)
- 本机 `terminal-notifier -version`、`-help`、`-diagnose`（3.1.0）
