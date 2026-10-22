# 功能待办

开发过程中发现的问题与已知限制。每条都记录了**现象、触发方式、原因**，
修掉之后挪到「已修复」留档 —— 这些多数属于「不报错、只是行为不对」的类型，
只有留档才不会在重构时重新踩回去。

状态：⬜ 待处理 · ✅ 已修复

## 待处理

### 功能缺陷

- [ ] **TODO-1** `jump` 不接受裸窗口名，但 `list` 显示的正是窗口名
- [ ] **TODO-2** 菜单超过 26 项时静默截断

### 文档缺陷

- [ ] **TODO-7** `--help` 说 `on | off` 是「当前 session 的开关」，实际是全局
- [ ] **TODO-8** `@whistle_detect_wait-re` / `done-re` 代码在读，但文档里没有

## 已修复

- [x] **TODO-3** 菜单第 10 项起没有快捷键
- [x] **TODO-4** `make fmt-check` 实际没有检查 bash 测试文件
- [x] **TODO-5** `@whistle_badge` 没有任何代码读
- [x] **TODO-6** `@whistle_self` 的行为与名字/文档相反
- [x] **TODO-9** `-t` 写在消息前面时会静默写到别的 pane
- [x] **TODO-10** `running` 被当成要打扰用户的状态扇出到所有 session
- [x] **TODO-11** `running` 没有清除路径，agent 退出后 `●` 永远亮着

---

## TODO-1 · `jump` 不接受裸窗口名

⬜ 待处理

**现象**：`tmux-whistle list` 的 WINDOW 列显示窗口名（如 `w2`），但直接
`tmux-whistle jump w2` 会报 `找不到 [w2]`。必须写成 `main:w2` 或 `jump 1`。

**触发**：

```sh
tmux-whistle jump w2          # rc=1，找不到 [w2]
tmux-whistle jump main:w2     # rc=0
tmux-whistle jump 1           # rc=0（裸 window_index 可以）
```

**原因**：`bin/tmux-whistle` 的 `cmd_jump` 只匹配三种形式：

```awk
$1 ":" $3 == t || $1 ":" $4 == t || $4 == t
```

即 `session:window_name`、`session:window_index`、裸 `window_index` ——
**没有「裸 window_name」这一支**。而 `list` 输出的第二列恰恰是 window_name，
用户自然会复制它去 jump。

**修复方向**：awk 里补 `$3 == t`。但窗口名不像 index 那样全 server 唯一
（不同 session 可以有同名窗口），所以要**先收集全部匹配、确认唯一后再动手**；
命中多个时应当报错并列出候选，而不是静默取第一个。

**相关代码**：`bin/tmux-whistle` 的 `cmd_jump`；`README.md` 的命令速查。

---

## TODO-2 · 菜单超过 26 项时静默截断

⬜ 待处理

**现象**：待处理项超过 26 个时，`prefix + W` 只显示前 26 个，
没有任何「还有 N 项」的提示。用户会以为就这么多。

**触发**：造 28 个待处理窗口，菜单只出 26 项（`--menu-args` 同样只有 26 组）。

**原因**：`cmd_menu` / `cmd_menu_args` 里的硬截断：

```sh
_i=$((_i + 1))
[ "$_i" -gt 26 ] && break
```

26 是 `display-menu` 单键快捷键的实际上限（9 个数字 + 17 个字母 `a`–`q`），
所以截断本身合理 —— 问题在于**截断是静默的**。

**修复方向**：截断时在菜单末尾追加一个不可选的提示项（名称以 `-` 开头即
灰色禁用），例如 `- 还有 2 项未显示，用 tmux-whistle list 查看`。
或者做分页。至少不要静默。

**备注**：`list` 与 `jump` 不受这个上限影响，能看到 / 到达全部项。

**相关代码**：`bin/tmux-whistle` 的 `cmd_menu` / `cmd_menu_args`。

---

## TODO-3 · 菜单第 10 项起没有快捷键

✅ 已修复（`bin/tmux-whistle` 的 `whistle_menu_key`）

**现象**：待处理项 ≥ 10 时，第 10 项及以后的行尾没有 `(快捷键)` 标记，
按任何键都选不中。**菜单本身正常弹出**，其余功能（徽章、🔔 计数、瞬时提示、
桌面通知、`list`、`jump`）完全不受影响。

**触发**：任意 10 个以上窗口处于待处理状态，按 `prefix + W`。

**原因**：两个 bug 叠加，症状相同：

1. 位置算成了 `$1 - 10` —— 第 10 项得到 `0`，而 BSD `cut` 不接受 `0`
2. 算术展开后面多写了一个 `)` —— `cut` 实际收到的是 `"0)"` 而不是 `"0"`

两者都让 `cut` 报错。stderr 被 `2>/dev/null` 吞掉，key 变成空串；而
**空 key 在 `display-menu` 里是合法的**（man page: *"second the key shortcut
(or empty for none)"*），表示「无快捷键」。所以 tmux 不报错、菜单照常渲染、
只是那一项不能用键选中。

验证方式：给真实 client 渲染一个 key 分别为 `1` / `10` / `a` / `C-a` 的菜单，
可见输出里 `AAA (1)`、`CCC (a)`、`(C-a)` 都有括号，而 key=`10` 的那项
**连括号都没画** —— tmux 根本没把它当快捷键（`10` 不是合法键名）。

**修复**：位置改为 `$1 - 9`（第 10 项落在字母表第 1 位，第 26 项是 `q`），
并把位置单独算进变量，避开「三层 `$()` 里再塞算术」这种少个括号看不出来的写法。
`make fmt` 不会碰这种错误，`make lint` 也不会 —— 只有断言能抓。

**回归测试**：`test/integration/cli.bats` 三条 ——
第 9/10/11 项分别是 `9`/`a`/`b`；满 26 项时键位全部非空且互不相同；
超过 26 项时截断到 26。第二条同时锁住「非空」，只断言数量的话 26 个空 key 也能过。

---

## TODO-4 · `make fmt-check` 实际没有检查 bash 测试文件

✅ 已修复（`Makefile` 的 `fmt-check`）

**现象**：`make fmt-check` 对 `test/**/*.bash` 没有真正做检查，
即使文件确实未格式化也照常返回通过。

**触发**：向 `test/test_helper/whistle.bash` 追加一段未格式化的代码，
`make fmt-check` 仍 `rc=0`。

**原因**：`fmt-check` 把 `BASH_SH` 和 `POSIX_SH` 放进**同一次** shfmt 调用、
统一用 `-ln=posix`，与 `fmt` 的 `-ln=bash` 对不上。`whistle.bash` 用了 bash 数组，
posix 方言解析失败 → shfmt 报错到 stderr、stdout 为空 → 脚本据此判定
「没有未格式化文件」放行。

后果有两层：bash 测试文件从来没被格式检查过；而且就算真没格式化也检测不出来
（解析先失败了）。

**修复**：按 `make fmt` 的做法拆成两次调用，各用对应方言。

**验证**：追加未格式化代码后，旧版 `rc=0` 通过，新版 `rc=2` 并列出文件名。

---

## TODO-5 · `@whistle_badge` 没有任何代码读

✅ 已修复（`lib/status-line.sh` 的 `whistle_mark_build`）

**现象**：README 配置表写着 `@whistle_badge off` = 关掉窗口徽章，但设成 `off`
之后徽章照常出现。

**触发**：

```sh
tmux set -g @whistle_badge off
tmux-whistle done 'x'          # 徽章仍然注入
tmux show -gwv window-status-format
# → X#{E:@whistle_mark}▌        哨兵仍在
```

**原因**：全仓搜 `whistle_badge` 只有两处命中 —— `lib/core.sh` 的默认值表，
和 `bin/tmux-whistle` 的 usage 字符串。**没有任何代码读它**，
`whistle_conf '@whistle_badge'` 从未被调用。

对照其余渠道：`@whistle_border` / `@whistle_border_status` / `@whistle_display` /
`@whistle_os` 都在 `lib/deliver.sh` 的对应函数里有开关判断，唯独徽章漏了。

**修复方向**：在 `whistle_format_patch`（或 `whistle_deliver`）里加开关判断。
注意语义有两种，取哪种要定清楚：

- **不注入**：`@whistle_badge off` 时不往 `window-status-format` 插哨兵
  （若已注入则回滚移除）
- **注入但渲染为空**：`whistle_mark_build` 在值为 `off` 时生成一个恒为空的
  format，这样状态栏格式保持原样、不需要事后回滚

后者更简单也更符合「幂等注入」的设计，倾向选它。

**回归测试**：设 `off` 后 `whistle_deliver` 跑一遍，断言
`window-status-format` 里哨兵要么不存在、要么渲染为空；再设回 `on` 断言徽章恢复。

**已修**：选了「注入但渲染为空」—— `whistle_mark_build` 在 `@whistle_badge off`
时直接返回空串。哨兵照常注入、渲染为空，`window-status-format` 的其余内容不受影响，
也不需要事后回滚（回滚会和 `whistle_ensure_status_line` 的自愈逻辑打架）。

**回归测试**（`test/integration/badge.bats` 3 条）：`off` 时不渲染徽章但格式保持；
从 `off` 改回 `on` 后徽章恢复；`off` 不影响 `status-right` 的全局计数
（后两条是防「修过头」——徽章和计数是两个独立信号）。

**相关代码**：`lib/status-line.sh` 的 `whistle_format_patch` / `whistle_mark_build`。

---

## TODO-6 · `@whistle_self` 的行为与名字相反

✅ 已修复（`lib/deliver.sh` 的 `whistle_display_fanout`）
· 语义：`on` = 提示自己所在的 session，`off` = 不提示

**现象**：文档与选项名都说「是否**也**提示自己所在的 session」，默认 `off`，
但实际行为是反的。实测（打桩记录 `display-message` 的目标）：

```
@whistle_self=off （默认） →  origin + other    ← 自己**也**收到了
@whistle_self=on           →  origin            ← 反而收窄成只提示自己
```

也就是说：默认配置下你**总是**在自己的 session 看到瞬时提示；
而打开这个选项反而**不再通知其它 session**。

**触发**：任意状态下让一个 session 内的 agent 报状态，然后看发起方 session
有没有弹出 `display-message`。

**原因**：`lib/deliver.sh` 的 `whistle_display_fanout` 里，
发往 origin 的那一条是**无条件**执行的，只有后续的扇出循环才看 `@whistle_self`：

```sh
whistle_tmux display-message -t "$_origin" "$_body"   # ← 无条件，永远发
[ "$(whistle_conf '@whistle_self')" = on ] && return 0 # ← on：不再扇出
for _s in $(... list-clients ...); do
  [ "$_s" = "$_origin" ] && continue                  # ← off：扇出给其它 session
done
```

按选项名与文档，`self` 应该只管 **origin 那一条**；现在的代码把它接到了
「是否继续扇出」上，于是 on/off 的效果正好与字面意思相反。

**修复方向**：把开关移到 origin 那一条上，扇出循环改为无条件执行 ——

**已修**：按上面的方案实现了，并把重复的 `display-message` 调用抽成
`whistle_display_to`（origin 与扇出两条路径共用，`-d` 的时长判断只写一次）：

```sh
# 发往 origin 的那条由 @whistle_self 决定
if [ "$(whistle_conf '@whistle_self')" = on ]; then
  whistle_display_to "$_origin" "$_body"
fi
# 扇出给其它 attached session，与 self 无关
for _s in $(... list-clients ...); do
  [ "$_s" = "$_origin" ] && continue
  whistle_display_to "$_s" "$_body"
done
```

**行为变更**：默认行为已变 —— 改前默认会提示自己所在 session，改后默认不再提示。
这是往「不打扰自己」的预期靠拢，但对已有用户是可见变化。README 的调优一节已补一张
表说明四种组合，并提示单 session 用户需要开 `@whistle_self on`。

**回归测试**（`test/integration/deliver.bats` 3 条）：`off` 时不提示 origin；
`on` 时提示 origin；同一 session 的多个 client 只收一次。

原用例只断言了 `status == 0`，**完全没有断言目标 session** —— 这就是它能长期
藏着的原因。新的用例打桩 `whistle_tmux` 记录 `display-message` 的 `-t` 参数。

写这批用例时踩到一个坑，值得单独记：**打桩函数里捕获的变量不能用 `local`**。
`whistle_tmux` 是在 helper 里定义的，但调用它的是测试体 —— helper 早已返回，
`local` 变量随之失效，打桩于是**安静地返回空**。第一版用例就是这么假绿的：
`self=on` 的断言通过了，但根本没验证到 origin 以外的目标。
「打桩没生效」这种失败模式不会报错，只会让你以为自己测过了。

**相关代码**：`lib/deliver.sh` 的 `whistle_display_fanout`。

---

## TODO-7 · `--help` 说 `on | off` 是「当前 session 的开关」

⬜ 待处理

**现象**：`tmux-whistle --help` 输出

```
$WHISTLE_PROG on | off             当前 session 的开关
```

但实现是 `set -g`，即**全局**开关。任何 session 里执行都会影响整个 server。

**触发**：在 session A 执行 `tmux-whistle off`，然后到 session B 置状态 ——
B 也被关掉了。

**原因**：`bin/tmux-whistle` 的 `cmd_toggle`：

```sh
whistle_tmux set -g @whistle_enabled "$_v"
```

`-g` 就是 global。另外 `whistle_conf` 用 `show -gqv` 读取，**所有**
`@whistle_*` 配置都只认全局值 —— 即使手动 `set -w` 设了 session 级配置也不会生效。

**修复方向**：最小改动是把 usage 文字改成「全局开关」，与 README 一致。
（README 命令速查里写的已经是「总开关」，只有 CLI 帮助是错的。）

若确实想要 per-session 开关，那是另一件事：需要 `cmd_toggle` 改成 `set`（session
作用域）、`whistle_conf` 改成 `show -qv` 并按 pane→window→session→global 顺序回退。
范围明显更大，不建议顺手做。

**相关代码**：`bin/tmux-whistle` 的 `whistle_usage` / `cmd_toggle`。

---

## TODO-8 · `@whistle_detect_wait-re` / `done-re` 未文档化

⬜ 待处理

**现象**：兜底检测的两个正则选项代码在读，但 `README.md` 和默认值表里都查不到，
用户无从得知可以自定义。

**触发**：

```sh
tmux set -g '@whistle_detect_wait-re' '需要输入|请选择'
# 能生效，但没有任何文档提到这两个选项叫什么
```

**原因**：`lib/detect.sh` 读这两个值：

```sh
whistle_conf '@whistle_detect_wait-re' 2> /dev/null \
  || printf 'esc to interrupt|Do you want to|❯ 1\\. Yes|waiting for your input'
```

而 `lib/core.sh` 的 `WHISTLE_DEFAULTS` 表里没有它们，README 的配置表也没有。
它们还有两处小问题：

1. **兜底逻辑其实走不到 `||`**。`whistle_conf` 在选项不在默认值表时打印空串但
   **返回 0**，所以 `|| printf '...'` 那条兜底分支永远不会执行。真正兜底的是
   调用方里的 `[ -n "$_wait_re" ] || _wait_re=$(whistle_detect_default_wait_re)`。
2. **命名不一致**：其它选项全是下划线（`@whistle_detect_interval`），
   只有这两个是连字符（`@whistle_detect_wait-re`）。tmux 的 option 名允许连字符，
   但和邻居不一致容易让人以为写错了。

**修复方向**：补进 `WHISTLE_DEFAULTS` 与 README 配置表；顺手把命名统一成
`@whistle_detect_wait_re` / `@whistle_detect_done_re`（若改名，需要兼容旧的
连字符写法，否则已有配置会静默失效 —— 加一条「旧名仍被识别」的读取即可）。

兜底那段 `|| printf` 是死代码，也可以一并清掉。

**相关代码**：`lib/detect.sh` 的 `whistle_detect_default_*`；`lib/core.sh` 的
`WHISTLE_DEFAULTS`。

---

## TODO-9 · `-t` 写在消息前面时会静默写到别的 pane

✅ 已修复（`bin/tmux-whistle` 的 `cmd_set`）

**现象**：参数顺序敏感 —— 消息必须写在 `-t` 前面。写成 git 那种习惯
（选项在前、消息在后）时，**不报错，只是把状态写到别的 pane 上**，消息还被
污染成 `-t %1 我要去 w2`。

**触发**（在 w1 里执行，目标是 w2）：

```sh
tmux-whistle done '我要去 w2' -t %1     # ✓ 落到 w2
tmux-whistle done -t %1 '我要去 w2'     # ✗ 落到 w1，消息变成 "-t %1 我要去 w2"
```

实测两种顺序的结果：

```
正确顺序 → w2|done|我要去 w2
自然顺序 → w1|done|-t %1 我要去 w2
```

**原因**：`cmd_set` 把 `$2` 直接当消息，没看它是不是选项：

```sh
_state="$1"
_msg="${2:-}"          # ← $2 是 -t 也照收
shift 2 2> /dev/null || shift $#
```

于是 `-t` 被吃进消息，后面的 `%1` 又被 `*) _msg="$_msg $1"` 拼进去，
`_target` 始终为空 → 落到 `$TMUX_PANE` 上。

同一个原因还让 `tmux-whistle running -t %3`（不带消息）完全不可用 ——
这是最别扭的一处，因为 `running` 恰恰是最常省略消息的状态。

**为什么一直没被发现**：README 只示范了「消息在前」的写法，测试也只覆盖了
那一种。而错误形态是「写到了另一个 pane」，不是「命令失败」—— 在单 pane
场景下甚至看不出异样。

**修复**：`cmd_set` 改成统一的参数循环，`$1` 只取状态，其余全部解析：

- `-t` / `--target` 收下一个参数
- `--dry-run` 置标志，解析完再打印（顺带能看到解析后的真实目标）
- `--` 之后一律当消息（让以 `-` 开头的消息可表达）
- 其余逐词拼消息；未知的 `-*` 报错

dispatch 相应简化为 `cmd_set "$@"`。

**回归测试**（`test/integration/cli.bats` 7 条）：`-t` 在前能落到目标 pane、
两种顺序结果一致、无消息也能带 `-t`、无引号多词仍拼成一句、`--` 之后不被当
选项、未知选项报错、`--dry-run` 顺序无关且不落盘。旧代码上 7 条红了 6 条
（第 4 条是防「修过头」的护栏，两边都过）。

**相关代码**：`bin/tmux-whistle` 的 `cmd_set` 与分派处。

---

## TODO-10 · `running` 被当成要打扰用户的状态扇出到所有 session

✅ 已修复（`lib/deliver.sh` 的 `whistle_deliver`）

**现象**：你每敲一次 prompt（`UserPromptSubmit`）或新开会话（`SessionStart`），
**其它所有 attached session 的状态栏都会弹一条 `[sess] running`**；开了
`@whistle_os` 还会同时弹一条桌面通知。

**触发**：在某个 session 里发一条 prompt，看别的 session。

**原因**：`whistle_deliver` 对**所有**状态无条件调用 `whistle_display_fanout`
与 `whistle_os_notify`：

```sh
whistle_border_paint "$1" "$2"   # 内部按状态取色，running 得到空色 → 不动
whistle_refresh_sessions "$1"
whistle_display_fanout "$1" "$2" "$3"   # ← 无条件
whistle_os_notify "$1" "$2" "$3"        # ← 无条件
```

徽章通道早就为 running 做了屏蔽（`whistle_mark_build` 里原本没有 running 分支），
另外两个渠道漏了。而 running 恰恰是**频率最高**的状态 —— 每个 turn 都来一次。

**修复**：用 `whistle_is_notified`（即 `WHISTLE_NOTIFIED_STATES`）把「打扰型渠道」
门控起来。running 仍然更新状态、刷新状态栏，只是不发瞬时提示、不弹桌面通知：

```sh
if whistle_is_notified "$2"; then
  whistle_display_fanout "$1" "$2" "$3"
  whistle_os_notify "$1" "$2" "$3"
fi
```

**回归测试**（`test/integration/deliver.bats` 3 条）：running 不产生任何
`display-message` 扇出；running 不改边框；`done` 仍然扇出（防「修过头」）。

**相关代码**：`lib/deliver.sh` 的 `whistle_deliver`。

---

## TODO-11 · `running` 没有清除路径，agent 退出后 `●` 永远亮着

✅ 已修复（`hooks/claude-code.sh` 的 `SessionEnd` + `bin/tmux-whistle --clear-pane`）

**现象**：窗口跑过一次 Claude Code 之后就一直显示 `●`，哪怕 agent 早就退出了。
running 变成徽章之前这个洞不影响观感（它本来不显示），一旦可见就成了永久残留。

**触发**：在某个 pane 里跑一次 Claude Code（`SessionStart` 置 running），退出，
窗口仍然亮 `●`。

**原因**：`running` 没有任何清除路径 ——

- `whistle_clear_window` / `whistle_clear_all` 都带 `whistle_is_notified` 过滤，
  只清 `WHISTLE_NOTIFIED_STATES`（done/wait/error），running 被跳过；
- 已读钩子（`after-select-window` / `after-select-pane`）同理；
- 没有订阅 `SessionEnd` —— agent 退出这件事插件根本不知道。

`running` 只会在下一次 `SessionStart` / `UserPromptSubmit` 时被重新覆盖，
所以「退出后一直亮」是稳定复现的。

**修复**：

1. 订阅 `SessionEnd`（`lib/install-hooks.sh` 的 `EVENTS`），hook 里调
   `tmux-whistle --clear-pane "$TMUX_PANE"`。
2. `lib/core.sh` 新增 `whistle_clear_pane_state <pane> <state>`：**只在当前值
   恰好等于目标状态时才清**，清完重算 window 与全局计数，并返回 window id。
3. CLI 的 `--clear-pane` 在窗口被清空时释放边框，然后刷新状态栏。

**只清 running**：done/wait/error 是待处理通知，agent 退出不代表你已经看过，
那几条要留到你切进去处理。所以 `--clear-pane` 对 done 是空操作。

**SessionEnd 是唯一的例外，不能用 async**：Claude Code 退出会带走后台子进程，
异步的清除可能跑到一半就被杀，留下一个永远灭不掉的 `●`。官方给 SessionEnd
1.5 秒预算，而这个操作只有几十毫秒，同步不会拖慢退出。`our_entry()` 里为此
单独判断了事件名。

**回归测试**：`test/e2e/claude_hook.bats` 3 条（SessionEnd 清 running；
done 原样保留；重复触发幂等）、`test/integration/cli.bats` 2 条
（`--clear-pane` 只清 running；清完窗口聚合回落）、
`test/integration/install_hooks.bats` 扩成六个事件并断言 SessionEnd 不带 async。

**相关代码**：`hooks/claude-code.sh`、`lib/core.sh`、`bin/tmux-whistle`、
`lib/install-hooks.sh`。

---

## 本轮新增（2026-10-22）

三条功能，不是缺陷：

1. **`error` 接上自动来源** —— 订阅 Claude Code 的 `StopFailure` 事件
   （回合因 API 错误结束时**替代** `Stop` 触发，两者互斥）。消息取
   `last_assistant_message`（该字段在这个事件里就是渲染出来的错误文本，
   如 `API Error: Rate limit reached`），缺失时回落到错误类型名。
2. **`running` 显示 `●`** —— 新增 `@whistle_icon_running` / `@whistle_color_running`，
   徽章条件式从三层变四层。它仍不计入 `🔔N`、不算待处理。
3. **`prefix + W` 列出所有 agent** —— 新增 `whistle_agent_windows()`（按 window 去重、
   取 rank 最高的一行）。待处理项带编号可跳转，running 项以 `-` 开头
   （`display-menu` 的 disabled 语义：tmux 绘制时会剥掉那个 `-` 并置暗，选中与
   鼠标路径都会跳过），没有快捷键。
4. **`running` 有了灭灯信号** —— 订阅 `SessionEnd`，agent 退出时清掉该 pane 的 running
   （见 TODO-11）。
5. **status-right 增加四态汇总** —— `●1 ✓1 ◷0 ✗0`。`whistle_count_states`（纯函数）
   从同一份 `list-panes` 输出算四态分布，写入 `@whistle_count_*`；汇总段与 `🔔N`
   共用同一个注入点（`@whistle_status_right`），所以自愈仍然只有一个入口。
   四个格子固定出现（含 0），状态栏宽度不跳动；全零时整段隐藏。

---

## 相关

- 开发与测试约定：[development.md](development.md)
- 使用者文档：[../README.md](../README.md)
