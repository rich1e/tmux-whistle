# 功能待办

开发过程中发现的问题与已知限制。每条都记录了**现象、触发方式、原因**，
修掉之后挪到「已修复」留档 —— 这些多数属于「不报错、只是行为不对」的类型，
只有留档才不会在重构时重新踩回去。

状态：⬜ 待处理 · ✅ 已修复

## 待处理

### 功能缺陷

（暂无）

### 缺失能力

- [ ] **TODO-18** 后台 Bash（`run_in_background`）在跑时状态栏看不见
- [ ] **TODO-19** `notification_type` 的 `plan_approval` / `idle_prompt` 未处理

### 文档缺陷

- [ ] **TODO-8** `@whistle_detect_wait-re` / `done-re` 代码在读，但文档里没有

## 已修复

- [x] **TODO-17** 后台/子 agent 在跑时，徽章显示「空闲」（活动与通知挤在一个状态槽里）
- [x] **TODO-20** 测试残留的隔离 tmux server 会静默关掉 tmux-continuum 的自动恢复/自动保存
- [x] **TODO-3** 菜单第 10 项起没有快捷键
- [x] **TODO-4** `make fmt-check` 实际没有检查 bash 测试文件
- [x] **TODO-5** `@whistle_badge` 没有任何代码读
- [x] **TODO-6** `@whistle_self` 的行为与名字/文档相反
- [x] **TODO-9** `-t` 写在消息前面时会静默写到别的 pane
- [x] **TODO-10** `running` 被当成要打扰用户的状态扇出到所有 session
- [x] **TODO-1** `jump` 不接受裸窗口名，但 `list` 显示的正是窗口名
- [x] **TODO-2** 菜单超过 26 项时静默截断
- [x] **TODO-7** `--help` 说 `on | off` 是「当前 session 的开关」，实际是全局
- [x] **TODO-11** `running` 没有清除路径，agent 退出后 `▶` 永远亮着
- [x] **TODO-12** 跳转只到窗口，分屏时落不到真正报状态的那个 pane
- [x] **TODO-13** 没有命令包装器，成功/失败要手写 `&&` / `||` 兜
- [x] **TODO-14** 消息被截断到 80 字后**永久丢失**，无处可查
- [x] **TODO-15** `SessionStart` 被当成 running，恢复会话后满屏假 `▶`
- [x] **TODO-16** 没有「空闲」状态，恢复会话后空着的 agent 无处显示

---

## TODO-1 · `jump` 不接受裸窗口名

✅ 已修复（`bin/tmux-whistle` 的 `cmd_jump`）

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

**已修**：加了裸窗口名那一支，四种写法都认：

```awk
$1 ":" $3 == t || $1 ":" $4 == t || $3 == t || $4 == t
```

**顺带修掉了同一处的第二个问题**：原来 `exit` 让它**静默取 `list-windows`
里的第一个**。裸序号 `0` 在每个 session 里都存在，裸窗口名也可能重名 ——
你会被静默送到另一个 session，看见一个干净窗口，根本想不起来
「哦原来该跳的是另一个」。**跳错窗口比报错难查得多。**

现在撞名会报错并列出候选：

```
$ tmux-whistle jump api
tmux-whistle: [api] 匹配到 2 个窗口，请写 session:window：
  main:api
  other:api
```

候选一律显示 `session:窗口名`（而不是序号），用户能直接粘回来用。
一个窗口最多命中一支 —— 窗口名不可能等于序号，所以不会重复计数。

⚠️ **这是一处行为变更**：原来 `jump 0` 在多个 session 有 0 号窗时会静默跳到
第一个，现在报错。依赖旧行为的脚本会开始失败，但那是在纠正一个错误行为。

**顺带接上 Task 1 的 `@whistle_win_pane`**：jump 现在会选中报状态的那一格。
**必须先判 pane 存活**再 `select-pane` —— 对着已死的 pane 会报错，
而 tmux 的 `;` 命令链遇错即停，后面的 `whistle_clear_window` 就不执行，
状态永远清不掉。这正是「菜单开着的时候那一格被关掉」的场景，
用 `display-message -p -t <pane> '#{pane_id}'` 取得到才 select。

**回归测试**（`test/integration/cli.bats` 7 条）：裸窗口名能跳；裸窗口名撞名
报错且**两边都不动**；裸序号撞名报错；裸窗口名找不到报错；`session:窗口`
写法在撞名时不受影响；`@whistle_win_pane` 指向死 pane 时仍能清掉窗口；
`@whistle_win_pane` 为空时跳过 select。

写测试时踩到一个坑：**tmux 给新 session 的首个窗口起的是当前 shell 的名字**
（zsh / bash / 取决于环境），不是 session 名。断言里写死它会随开发机变化 ——
第一版就写成了 `other:other`，在 tmux 3.8 上拿到的是 `other:zsh`。
测试里的窗口名一律显式给（`new-session -d -s other -n svc`）。

`make check` 221 项全绿。

---

## TODO-2 · 菜单超过 26 项时静默截断

✅ 已修复（`bin/tmux-whistle` 的 `whistle_menu_overflow` + `cmd_menu` / `cmd_menu_args`）

**现象**：待处理项超过 26 个时，`prefix + n` 只显示前 26 个，
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

**已修**：两个循环都从「到上限就 `break`」改成「**一直计数**，只在 ≤ 上限时累积」，
放不下就在末尾追加一条灰字提示项：

```
- 还有 2 项未显示，用 tmux-whistle list 查看
''
"display-message ''"
```

提示项的三个字段都有讲究：

- **名字以 `-` 开头** —— tmux 的 disabled 语义（绘制时剥掉那个 `-` 并置暗，
  选中与鼠标路径都跳过）
- **快捷键必须为空** —— 非空的话用户按那个键会选中一条不可跳转的项，
  行为上退化成「点了没反应」，比原来的静默截断更难查。这条单独有用例守着
- **命令是空转** —— 真的执行不了任何事

**顺带修掉了 running 那段的同类截断**（上限 10，原来也是静默 `break`）。
只修待处理那一半更糟 —— 用户会以为「菜单修好了」，结果换个场景照旧骗人。
两段各自计数、各自出提示（最多两条灰字），互不干扰。

**没有做分页**，这是有意的取舍：`list` 本身无限项，提示项把用户指过去就够了。
分页会让 `display-menu` 的**单键直达**优势（按一个键就到那个窗口）消失 ——
那才是这个菜单的核心价值。

`cmd_menu` 与 `cmd_menu_args` 是两份几乎相同的循环，后者只为让测试能在
无 attached client 的情况下断言 argv。**只改一边 = 测试变假绿**，
所以两边的计数与提示逻辑逐行对应，改动时必须一起改。

**回归测试**（`test/integration/cli.bats` 6 条）：超 26 项时第 27 组是灰字提示
且 26 个可跳转名额一个不少；提示项快捷键为空；5 项与恰好 26 项时都不加提示（边界）；
running 超 10 项出提示；两段的提示分开计数；提示项不占用可跳转名额。

写 `seed_running_windows` 时踩到一个坑：照抄 `seed_pending_windows` 的循环，
从 `i=2` 开始建窗口 —— 后者能这么写是因为 `wt_start` 已经建好了 `w1` 顶掉 i=1，
而我用的是自己的 `r*` 命名，`r1` 压根不存在，于是 running 项永远只有 12 个、
提示项不触发。**照抄带隐含前提的代码时，先确认那个前提在新的上下文里还成立。**

`make check` 227 项全绿。

---

## TODO-3 · 菜单第 10 项起没有快捷键

✅ 已修复（`bin/tmux-whistle` 的 `whistle_menu_key`）

**现象**：待处理项 ≥ 10 时，第 10 项及以后的行尾没有 `(快捷键)` 标记，
按任何键都选不中。**菜单本身正常弹出**，其余功能（徽章、⚑ 计数、瞬时提示、
桌面通知、`list`、`jump`）完全不受影响。

**触发**：任意 10 个以上窗口处于待处理状态，按 `prefix + n`。

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

**已修**：走的是最小改动 —— `whistle_usage` 里那句改成「总开关」。
**没有**做 per-session 开关，那仍然是另一件事（要改 `whistle_conf` 的回退链，
范围明显更大）。

顺带把同一段 usage 里过时的 `jump <n|sess:win>` 改成
`jump <窗口|序号|sess:win>`，跟 TODO-1 的四种写法对齐。

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

## TODO-11 · `running` 没有清除路径，agent 退出后 `▶` 永远亮着

✅ 已修复（`hooks/claude-code.sh` 的 `SessionEnd` + `bin/tmux-whistle --clear-pane`）

**现象**：窗口跑过一次 Claude Code 之后就一直显示 `▶`，哪怕 agent 早就退出了。
running 变成徽章之前这个洞不影响观感（它本来不显示），一旦可见就成了永久残留。

**触发**：在某个 pane 里跑一次 Claude Code（`SessionStart` 置 running），退出，
窗口仍然亮 `▶`。

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
异步的清除可能跑到一半就被杀，留下一个永远灭不掉的 `▶`。官方给 SessionEnd
1.5 秒预算，而这个操作只有几十毫秒，同步不会拖慢退出。`our_entry()` 里为此
单独判断了事件名。

**回归测试**：`test/e2e/claude_hook.bats` 3 条（SessionEnd 清 running；
done 原样保留；重复触发幂等）、`test/integration/cli.bats` 2 条
（`--clear-pane` 只清 running；清完窗口聚合回落）、
`test/integration/install_hooks.bats` 扩成六个事件并断言 SessionEnd 不带 async。

**相关代码**：`hooks/claude-code.sh`、`lib/core.sh`、`bin/tmux-whistle`、
`lib/install-hooks.sh`。

---

## TODO-12 · 跳转只到窗口，分屏时落不到真正报状态的那个 pane

✅ 已修复（`lib/core.sh` 的 `whistle_aggregate` / `whistle_recompute_window` /
`whistle_agent_windows` + `bin/tmux-whistle` 的 `cmd_menu` / `cmd_menu_args`）

**现象**：一个窗口切成多格（pane）时，`prefix + n` 选中一项只会切到那个**窗口**，
窗口里落在哪一格不保证 —— 常常不是正在等你的那一格。

**触发**：

```sh
tmux-whistle done "等我批准"     # ① 在 pane A 报状态
tmux split-window                # ② 把窗口切成两格，焦点在 pane B
prefix + n                       # ③ 选那一项
# → 落在 pane B（焦点所在的那格），要自己再点回 pane A
```

**原因**：窗口级聚合没记 pane 身份，菜单命令里也没有 `select-pane`。

```sh
# lib/core.sh 的 whistle_recompute_window —— 只写三个派生值
setw @whistle_win "$_state" \; setw @whistle_win_msg "$_msg" \; setw @whistle_win_count "$_count"
```

`whistle_aggregate` 读进来的第一列就是 `#{pane_id}`（变量名 `_pane_id`），
但它只在 case 里用来过滤合法行，**读完就丢掉了** —— 输出仍是三列，没有 pane。
`whistle_agent_windows` 的 format 里也压根没有 pane 列，所以菜单无从知道该选哪一格：

```sh
-F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{@whistle}|#{@whistle_msg}'
```

最后落到菜单执行的 tmux 命令串上（`bin/tmux-whistle` 的 `cmd_menu`）：

```
switch-client -t $s ; select-window -t $wid ; run-shell -b '... clear -t $wid'
```

有 `select-window`，没有 `select-pane`。

**为什么一直没被发现**：单 pane 窗口里 `select-window` 和 `select-pane` 效果一样。
而且 `whistle_list_lines` 的输出里**是有** pane id 的（第三列），信息在读侧存在、
只是没被路由到跳转命令上。

`@whistle_border_status` 那个选项本质上是这个缺陷的权宜之计 ——
把每个 pane 的符号画到顶部，好让你**用眼睛找**。它占掉每格顶部一整行，且默认关。

**修复方向**：

1. `whistle_aggregate` 的输出增加第 4 列 pane id（放**末尾**，这样
   `whistle_recompute_global` 的 `cut -d'|' -f3` 取待处理数不用改），
   顺便更新 `test/unit/core.bats` 对输出格式的断言；
2. `whistle_recompute_window` 多写一个 `@whistle_win_pane`；
3. `whistle_agent_windows` 的 format 加 pane 列，`cmd_menu` / `cmd_menu_args`
   按位置读出新的一列，命令串里补 `select-pane -t $pane`；
4. ~~`whistle_state_clear` 必须一并清 `@whistle_win_pane` —— 否则窗口清空后
   会残留一个已失效的 pane id。~~ **这条当初判断错了，见下方「已修」第 3 点：
   它是派生值，由重算覆盖即可，`whistle_state_clear` 不必碰它。**

**风险点**：pane 在菜单弹出之后、命令执行之前被关掉时，`select-pane` 会报错，
而 tmux 的 `;` 命令链遇错即停，后面的 `clear` 不会执行 → 状态永远清不掉。
窗口无 pane 时聚合输出空 pane（`list-panes` 无输出 → 四列全空），
`@whistle_win_pane` 自愈为空，这一侧不用额外兜。

**相关代码**：`lib/core.sh` 的 `whistle_aggregate` / `whistle_recompute_window` /
`whistle_state_clear`；`bin/tmux-whistle` 的 `cmd_menu` / `cmd_menu_args` / `cmd_jump`；
`test/unit/core.bats`、`test/integration/cli.bats`。

**开发计划**：[plans/2026-10-23-notify-absorption.md](superpowers/plans/2026-10-23-notify-absorption.md) 的 Task 1。

**已修**：

1. `whistle_aggregate` 的输出从三列变四列，**pane id 放末位**。
   放末位不是随意的 —— `whistle_recompute_global` 用 `cut -d'|' -f3` 取待处理数，
   放中间那里就得跟着改。
2. `whistle_recompute_window` 多写一个 `@whistle_win_pane`。
   窗口内没有 pane 时 `list-panes` 无输出 → 四列全空 → 该 option 被写成空串，
   **自愈**，不需要额外兜底。
3. `whistle_agent_windows` 的 format 加 pane 列（插在第 5 位），
   `cmd_menu` / `cmd_menu_args` 的两处循环同步读出新列，命令串补 `select-pane`。

**为什么 pane 必须由 `whistle_aggregate` 产出、不能另扫一遍算**：
「窗口显示哪个状态」和「pane id 是谁」必须来自同一次判断。
两次扫描各自选 rank 最高的 pane，一旦它们选到不同的 pane，
菜单就会跳到「别的格子上那个同样高优先级」的 pane。代价是 `test/unit/core.bats`
里 12 处三列断言要同步改成四列。

**一个原本担心、结果不需要改的地方**：`whistle_state_clear` **不必**清
`@whistle_win_pane` —— 它是 window 级派生值，调用方随后会跑
`whistle_recompute_window` 覆盖掉。反倒在这里多清一遍，会在窗口已不存在时报错。
结论已写进该函数注释。

**pane 已死时命令链不能被打断（评审后补的）**：pane 在菜单弹出之后、命令执行之前
被关掉时，裸的 `select-pane` 会报错，而 tmux 的 `;` 命令链遇错即停 —— 后面的
`clear` 不执行，状态永远清不掉。若那一项正好是当前窗口，`select-window` 是 no-op、
`after-select-window` 也不触发，徽章就一直亮着。

修法：菜单项不再在命令链里裸调 `select-pane`，改成把 pane 交给异步的
`clear --select <pane>`，由 `whistle_select_pane_if_alive` 先判存活再选。
`jump` 走同一个 helper。这样「先清、后选」，select 失败也不影响清除结果。

最早只给 `jump` 加了守卫、菜单没加 —— 复核对拍（隔离 server + `source-file`
走 tmux 自己的解析器）复现了 `can't find pane: %999` 之后 `@whistle_win` 仍是
`done`。教训：**同一个 hazard 在两个调用点，只修一处等于没修**。

**回归测试**：`test/unit/core.bats` 12 处断言改为四列 + 4 条新用例
（第 4 列是胜出 pane、等级相同取先出现者、无人胜出时为空串、多加一列不改变 pending 语义）；
`test/integration/state.bats` 3 条（窗口态记住 pane id、清掉后回落为空、
`agent_windows` 每行带 pane id）。合计 214 项全绿。

**附带收益**：`@whistle_border_status` 从「分屏时的权宜之计」变回真正的锦上添花 ——
它不再是「唯一能看出是哪个 pane 在等你」的手段。

---

## TODO-13 · 没有命令包装器，成功/失败要手写 `&&` / `||`

✅ 已修复（`bin/tmux-whistle` 的 `cmd_run` + `test/integration/run.bats`）

**现象**：想让一个普通命令跑完自动亮徽章，只能手写：

```sh
pnpm test && tmux-whistle done "测试过了" || tmux-whistle error "测试失败"
```

漏掉后半截 → 失败时徽章不亮；`&&` / `||` 写反 → 状态正好相反。**两种都不报错**，
只是徽章不对。而且拿不到「跑了多久」。

**触发**：README「场景二」给的就是这个写法，等于把易错的组合逻辑交给每个用户。

**原因**：CLI 只有 `<状态> [消息]` 一个入口，插件不负责执行命令，
自然也就不知道退出码和耗时。

**修复方向**：新增 `run` 子命令。

```sh
tmux-whistle run [-- 标签] -- 命令 参数...
```

开始时置 `running`，执行完按退出码置 `done`（0）或 `error`（非 0），
消息里带上耗时（`4m32s`）。**不要用 `exec`** —— 那样 shell 进程被替换掉，
拿不到退出码；直接跑 `"$@"` 再读 `$?` 即可，不需要 trap。

**边界**：包装器只认退出码，不解析输出；退出码 130（Ctrl-C）按 error 处理。

但「子命令自己吃到 SIGINT」与「用户按 Ctrl-C」是两件事：后者把信号发给**整个前台
进程组**，不装 handler 的话包装器会在读到 `$?` 之前就死掉，状态永远停在 `running`
—— 而 `running` 不计入 pending、⚑ 不亮，非 Claude Code 的进程更没有 SessionEnd
兜底。所以 `cmd_run` 开头装了 `trap ':' INT`。
**必须用 `:` 而不是 `''`**：被 trap 的信号在子进程里复位成默认动作，子命令照样
能被 Ctrl-C 打断；被 ignore 的会连子命令一起忽略，用户就再也停不掉自己启动的构建。

**相关代码**：`bin/tmux-whistle` 的 `cmd_run` 与分派处；`README.md` 的「场景二」。

**开发计划**：[plans/2026-10-23-notify-absorption.md](superpowers/plans/2026-10-23-notify-absorption.md) 的 Task 4。

**已修**：

```sh
tmux-whistle run -- npm test          # 按退出码落状态，消息带耗时
tmux-whistle run '测试' -- npm test   # 自定义标签
```

三条语义写进了测试：

- **退出码透传**：`run -- sh -c 'exit 7'` 自身也返回 7。否则
  `make && tmux-whistle run -- …` 在失败时会返回 0，CI 照样绿。
- **只认退出码，不解析输出**：一个退出码 0 的命令是不是「真的完成了」，
  包装器判断不了。这是显式包装器的边界，不是缺陷。
- **参数原样传递**：`"$@"` 直接跑，不 eval、不 word splitting，
  用户引号怎么写就怎么传。

**顺带把编排抽成 `whistle_finish`**（重算 + 投递），`cmd_set` 与 `cmd_run` 共用 ——
复制两份必然分叉。加 `run` 时最怕的就是两条路径的投递行为悄悄对不上。

**踩到的坑：`$_rc，` 少写了花括号。** 这正是 CLAUDE.md 里写明的红线 ——
「`$var` 后面紧跟中文/全角字符必须写 `${var}`」。实测症状很绕：

```
tr: Illegal byte sequence
消息被截成「sh 失败（退出码」，退出码的 7 整个消失
```

`bash` 把全角逗号（`ef bc 8c`）的第一个字节吞进变量名，剩下 `bc 8c` 是非法 UTF-8，
`tr` 直接报错退出，管道只吐出前半段。同样的字面量走老路径（`done`）却是好的 ——
所以第一反应完全指错了方向（我先去查 `tr` 的字符类、又去查 locale）。
**真到现场直接 `od -c` 看字节，比顺着猜快得多。**
已在该行加注释，并用一条 grep 扫了全仓确认没有第二处。

**回归测试**（`test/integration/run.bats` 13 条，全新文件）：0 → done、
非 0 → error 且消息带退出码、终态顶掉 running、自定义标签、无标签时用命令名、
带耗时、命令输出透传、参数不做 word splitting、缺 `--` 与 `--` 后无命令都报错
且**不写任何状态**、`-t` 指向别的 pane、成功计入待处理、窗口徽章同步。

写测试时另有一处：helper 里**没有 `assert_ne`**（只有 `assert_eq` /
`assert_contains` / `assert_not_contains`），我第一版用了它，
三条用例因为「函数不存在」而红 —— 症状和功能缺失一模一样。

`make check` 240 项全绿。

---

## TODO-14 · 消息被截断到 80 字后永久丢失

✅ 已修复（`lib/core.sh` 的 `whistle_sanitize` / `whistle_state_set` /
`whistle_state_clear` + `bin/tmux-whistle` 的 `cmd_set` + `hooks/claude-code.sh`）

**现象**：消息最长 80 字符，超了直接砍断，**砍掉的部分没有任何地方能再找到**。
agent 一轮下来常是几百字的总结，徽章位置只有一行宽，只能看到开头一句。

**触发**：任何一个 `last_assistant_message` 超过 80 字的回合。

**原因**：`whistle_sanitize` 单字段截断，且**只有一个字段**：

```sh
WHISTLE_MSG_MAX=80
whistle_sanitize() { ... | cut -c "1-$WHISTLE_MSG_MAX" | ... }
```

`@whistle_msg` 同时承担「徽章上显示什么」和「全部内容」两个职责，
而徽章的宽度约束是真的 —— 问题在于**没有第二处存放完整内容**。

**修复方向**：短标题与长正文分开存，**不改任何 tmux format**。

- `--title` → 写进 `@whistle_msg`（用户自己给短标题，仍受 80 字保护）
- `--body` → 写进 `@whistle_body`（新上限 400 字）
- 只给 `--body` 不给 `--title` 时，`@whistle_msg` 取正文前 80 字 —— **完全保持现状**
- `whistle_state_clear` 必须一并清 `@whistle_body`，否则会留残值

**为什么不改徽章 format**：本来可以让徽章优先渲染 `@whistle_title`，但那要在
`whistle_mark_build` 已经是四层的条件式里再套一层 `#{?#{@whistle_title},...}` ——
而嵌套 `#{?...}` 的大括号配平正是本项目最贵的坑之一（配错一格 tmux **静默渲染成空串**）。
收益（标题可控）不值这个风险，不做。

**当前价值有限、要说清楚**：正文存下来后，**要等事件历史（`notify-design-review.md`
的 B-1）做完才有界面能看它**。现在它就是「存了不丢、暂不可见」。
但顺手让 hook 传 `--body` 是有意义的 —— 完整回复从此被留下来，而不是被砍掉就消失。

**相关代码**：`lib/core.sh` 的 `whistle_state_set` / `whistle_state_clear` /
`WHISTLE_MSG_MAX`；`bin/tmux-whistle` 的 `cmd_set`；`hooks/claude-code.sh`。

**开发计划**：[plans/2026-10-23-notify-absorption.md](superpowers/plans/2026-10-23-notify-absorption.md) 的 Task 5。

**已修**：加了 `@whistle_body`（上限 400），**一个 tmux format 都没改**。

```sh
tmux-whistle done --title '重构完成' --body '完整回复…'
```

- `whistle_sanitize` 加了可选的第二参作为长度上限，不传则仍用 `WHISTLE_MSG_MAX`
  —— **所有既有调用点逐字不变**（`test/unit/core.bats` 13 条 sanitize 用例全绿即证据）
- `whistle_state_set` 增加第 4 个位置参数 `[body]`，写进同一条 `\;` 链
  （链是一进程，多写一个 option **不增加 fork**）
- 空值也写 —— 否则上一轮的正文会留在 pane 上，变成「这次没写正文，
  却显示着上次的」。`whistle_state_clear` 一并 unset
- `hooks/claude-code.sh` 的 `Stop` / `StopFailure` 现在把**完整回复**作为
  `--body` 传下去（改动前 `head -n 1` 之后那部分无处可寻）

徽章上显示什么的优先级：`--title` > 位置消息 > `--body` 前 80 字。
都不给就为空 —— 与改动前一致。让 `--body` 能顶上来是因为：只写 `--body`
时若消息留空，徽章会是空白，而内容明明就在手上。

**为什么不给徽章加 `@whistle_title`**：那要在 `whistle_mark_build` 已经是四层的
条件式里再套一层 `#{?#{@whistle_title},...}`，而嵌套 `#{?...}` 的大括号配平
是本项目最贵的坑 —— 配错一格 tmux **静默渲染成空字符串**，不报错。
收益（标题可控）不值这个风险。

**⚠️ 已知限制，说在前面**：`@whistle_body` **存了，但目前没有界面能看它**。
要等事件历史（[设计方案评审](notify-design-review.md) 的 B-1 / 阶段 3）落地
才有 UI。现在的收益是「不再丢失」而不是「随时可查」——
用 `tmux show -pqv -t %<pane> @whistle_body` 能手工看到。

**回归测试**：`test/integration/cli.bats` 7 条（分开存、只给 body 时 msg 取前 80 字、
都不给时与改动前一致、超过 400 字按上限截断、format 注入串被消毒、
清除时一并清掉、换行折叠成空格）；`test/e2e/claude_hook.bats` 4 条
（完整回复进 body、缺消息时 body 为空、下一轮对话开始时清掉残值、
`SessionEnd` 不动上一轮的 done 与它的正文）。

写 e2e 时第一版假设「SessionEnd 会清掉正文」—— **错的**：`SessionEnd` 只清
`running`，而那时状态已经是 `done`（TODO-11 的设计：agent 退出不代表你已经看过）。
改成两个真正有意义的场景：下一轮 `UserPromptSubmit` 时正文是否被清掉（会），
以及 `SessionEnd` 是否误伤上一轮的正文（不会）。

`make check` 251 项全绿。

---

## TODO-15 · `SessionStart` 被当成 running，恢复会话后满屏假 `▶`

✅ 已修复（`hooks/claude-code.sh` 的 `SessionStart` 分支）

**现象**：配上 tmux-resurrect 的 `@resurrect-processes '"claude->claude --continue"'`
之后，关掉 tmux 再打开，状态栏立刻显示 `▶3` —— 三个 agent 都「在跑」。
实际上它们只是刚被拉起来，**都在提示符前面等着**，一个都没在干活。

**触发**：`@continuum-restore on` + 上面那条 `@resurrect-processes`，
tmux server 重启后自动恢复三个 Claude Code 会话。更简单的复现：
在 pane 里敲一次 `claude`、什么都不输入，状态栏也亮 `▶`。

**原因**：hook 里 `SessionStart` 与 `UserPromptSubmit` 共用一个分支，都映射成
`running`：

```sh
SessionStart | UserPromptSubmit)
  _state=running   # ← 注释写的是「用户开始交互」，但 SessionStart 不是交互
```

`SessionStart` 只说明**进程起来了**（`source` = `startup` / `resume` /
`clear` / `compact` / `fork`），不说明 agent 在干活。而 `running` 一旦点亮，
没有任何超时或轮询会把它熄掉 —— 只能等下一次 `UserPromptSubmit` / `Stop`。
（`▶` 不计入 `⚑N`、不发瞬时提示，所以除了状态栏那一格，没有任何地方会暴露它是假的。）

**修复**：

- `running` 只由 `UserPromptSubmit` 点亮 —— 那才是「用户刚让 agent 干活」。
- `SessionStart` 改为**清**：复用 `--clear-pane`（与 `SessionEnd` 同一条路径），
  只清 `running`，`done`/`wait`/`error` 留着等你处理。
  顺带自愈「上一个 agent 被 SIGKILL / 崩溃、没发 `SessionEnd`」的永久 `▶` ——
  新进程起来了 ⇒ 旧的没了。
- **`source=compact` 例外，原样退出**：压缩发生在**轮中**，那一轮还没结束、
  agent 确实还在干活；这时清掉会把正在转的 `▶` 掐掉。

**回归测试**（`test/e2e/claude_hook.bats` 5 条）：`startup` / `resume` 不点亮、
`resume` 时窗口聚合也是空、有残留 `running` 时被清掉（含窗口聚合）、
不动 `done`、`compact` 不动 `running`。

**相关代码**：`hooks/claude-code.sh` 的 `SessionStart` 分支；
`bin/tmux-whistle` 的 `--clear-pane`；`lib/core.sh` 的 `whistle_clear_pane_state`。

> 后续演进：`SessionStart` 改为写 `idle`（不再只是"清"），见 TODO-16。

---

## TODO-16 · 没有「空闲」状态，恢复会话后空着的 agent 无处显示

✅ 已修复（新增 `idle` 状态）

**现象**：`claude --continue` 恢复出来的、以及刚敲 `claude` 还没输入的那些 agent，
在 tmux-whistle 眼里**不存在** —— 窗口徽章空白、菜单里没有这一项、状态栏汇总也不计数。
想知道「到底有几个 agent 活着」，只能靠 `ps`。

**触发**：`@continuum-restore on` + `@resurrect-processes '"claude->claude --continue"'`，
重启 tmux 后恢复三个会话；或者手动在一个 pane 里敲一次 `claude`、什么都不输入。

**原因**：状态集里只有 `running / done / wait / error`，没有「进程在、但没在干活」这一档。
TODO-15 把 `SessionStart` 从 `running` 改掉之后，这类 agent 就变成了「没有任何状态」——
诚实，但信息也丢了。

**修复**：新增 `idle` 状态。

- `SessionStart`（`source=compact` 除外）→ `idle`；`UserPromptSubmit` → `running`；
  `SessionEnd` 同时清 `running` 与 `idle`（`WHISTLE_TRANSIENT_STATES`）。
- **`idle` 顶不掉待处理通知**：守卫在 `whistle_state_set`（唯一写入点），不在 hook 里。
- `whistle_rank`：error 5 > wait 4 > done 3 > running 2 > idle 1 > 空 0 ——
  idle 必须低于 running（同窗口有在跑的就显示 ▶），又必须高过 0（整个窗口都空闲时
  徽章才显示 ◉，否则赢不过初始值）。
- 渲染：窗口徽章与 pane 边框状态行各加一层（五层嵌套、结尾 `}}}}}`）；
  status-right 汇总从四格变五格 `▶N ◉N ◆N ◔N ⚠N`，**显示判据同时看
  running / idle / pending** —— 漏掉 idle 的话「三个全空闲」会被判成没活动而隐藏，
  而那正是恢复 tmux 后最想看到的一格。
- 菜单：running 从借用的 `◉` 改回 `▶`，新增 idle 用 `◉`。两处语义终于一致
  （早先同一个字符在状态栏表示「空闲」、在菜单表示「在跑」）。
- idle 不计入 `⚑N`、不染边框、不发瞬时提示与桌面通知、不进 `list`。

**后续（同日追加）：按进程发现空闲**

第一版只让 hook 在 `SessionStart` 报 idle，结果计数还是不准：

- **存量 agent**：功能落地之前启动的那些 agent，它们的 `SessionStart` 走的是老分支
  （只清不写），插件从头到尾不知道它们存在 → `◉ 0`，而实际有 3 个在等。
- **读完通知之后**：一轮做完、你把 `done` 读掉，那一格被清空 —— agent 还活着，
  却不再计入 `◉`。计数会再次掉回 0。

解法：加一层「有效状态」推导（`whistle_resolve_idle_panes`，纯函数）——
**没上报状态、但前台跑着 agent 进程的 pane 算 idle**。判据是 tmux 自己的事实
（这个 pane 的前台跑着谁），不是从屏幕文字里猜提示符；「哪些进程算 agent」由用户配
（`@whistle_agent_cmds`，默认 `claude claude.exe`）。推导放在纯函数之前，
窗口徽章、全局计数、菜单三处因此口径一致。

**已知限制**：比对的是 `pane_current_command`（**进程名**，不是命令行）。原生二进制
装出来的 `claude` 匹配得上；跑在 node 上的 `claude` 那边看到的是 `node`，得自己把
`node` 加进清单 —— 但不能只填 `node`，跑 node 的 pane 不止 agent 这一个。

同时引入 `gone` 状态（只有 `SessionEnd` 会写）：钩子跑的时候 agent 进程**还没退出**，
`pane_current_command` 仍是 claude —— 那时若把状态清空，紧接着的重算会又把它认成
空闲，留下一盏灭不掉的 `◉`。写成 `gone` 就绕开了（`gone` 的 rank 是 0：徽章不显示、
计数不涨、菜单不列）。

**回归测试**：rank 的相对关系、count_states 五段、aggregate 里 idle 能胜出但输给
running、汇总「只有 idle 时也显示」、菜单 `▶ 运行中` / `◉ 空闲`、
e2e 的 SessionStart→idle / 不顶掉 done 与 wait / SessionEnd 清 idle。

**相关代码**：`lib/core.sh`（状态常量、rank、count_states、`whistle_state_set` 的
idle 守卫、`whistle_clear_pane_transient`）、`lib/status-line.sh`（两处徽章 + 汇总）、
`bin/tmux-whistle`（菜单图标/颜色/标签、`cmd_forget_transient`）、
`hooks/claude-code.sh`。

---

## 本轮新增（2026-10-22）

三条功能，不是缺陷：

1. **`error` 接上自动来源** —— 订阅 Claude Code 的 `StopFailure` 事件
   （回合因 API 错误结束时**替代** `Stop` 触发，两者互斥）。消息取
   `last_assistant_message`（该字段在这个事件里就是渲染出来的错误文本，
   如 `API Error: Rate limit reached`），缺失时回落到错误类型名。
2. **`running` 显示徽章** —— 新增 `@whistle_icon_running` / `@whistle_color_running`，
   徽章条件式从三层变四层。它仍不计入 `⚑N`、不算待处理。
   <br>_（2026-10-23 改动：默认图标由 `●` 换成绿色 `▶`，默认色由 `#5f87af` 换成 `#00af00`。）_
3. **`prefix + n` 列出所有 agent** —— 新增 `whistle_agent_windows()`（按 window 去重、
   取 rank 最高的一行）。待处理项带编号可跳转。
   <br>_（2026-10-23 修正：running 项最初是 `-` 开头的 disabled 条目，只能看不能点。
   现在它与待处理项共用同一套 1–26 键位，都能跳，用绿色 `▶` 前缀区分。见下方「已修」。）_
4. **`running` 有了灭灯信号** —— 订阅 `SessionEnd`，agent 退出时清掉该 pane 的 running
   （见 TODO-11）。
5. **status-right 增加四态汇总** —— `▶1 ✓1 ◔0 ✗0`。`whistle_count_states`（纯函数）
   从同一份 `list-panes` 输出算四态分布，写入 `@whistle_count_*`；汇总段与 `⚑N`
   共用同一个注入点（`@whistle_status_right`），所以自愈仍然只有一个入口。
   四个格子固定出现（含 0），状态栏宽度不跳动；全零时整段隐藏。

---

## 开发计划 · 通知能力增强（第一批）

来源：[设计方案评审](notify-design-review.md) 的 A 档 —— 五条都能当场改、当场验，
且**不引入任何新依赖、不新增 UI 层**。B 档（事件历史、两态分离）不在本批，
它需要新目录与写权限，属于另一批。

计划正文：[plans/2026-10-23-notify-absorption.md](superpowers/plans/2026-10-23-notify-absorption.md)

| Task | 功能 | 对应 TODO | 状态 |
|---|---|---|---|
| 1 | 跳转精确到 pane | TODO-12 | ✅ 已完成 |
| 2 | `jump` 接受裸窗口名 + 撞名不静默 | TODO-1 | ✅ 已完成 |
| 3 | 菜单截断不再静默 | TODO-2 | ✅ 已完成 |
| 4 | `run --` 命令包装器 | TODO-13 | ✅ 已完成 |
| 5 | 标题 / 正文分离 | TODO-14 | ✅ 已完成 |

**执行约定**：

- 每个 Task 走 TDD：先写失败断言 → 跑一遍确认它真的红 → 最小实现 → `make check` 全绿
- **每个 Task 完成后立刻把对应 TODO 从「待处理」挪到「已修复」并补实施记录**，
  再提交 —— 不攒到最后一起改文档
- 提交粒度 = 一个 Task 一个 commit

**为什么串行、不并行**：这五条**两两之间都共用文件** —— 1 与 2 都改 `cmd_jump`，
1 与 3 都改 `cmd_menu`，1 与 5 都改 `lib/core.sh`，五条都要往
`test/integration/cli.bats` 追加用例，并且都要跑全量 `make check`。
并发改同一文件会冲突，`make check` 的红绿也会互相污染（一个 Task 失败会让
另外几个的验证失去意义）。总量约 70 行 + 测试，串行的代价远小于协调成本。

---

## 相关

- 设计方案评审：[notify-design-review.md](notify-design-review.md)
- 开发与测试约定：[development.md](development.md)
- 使用者文档：[../README.md](../README.md)

---

## TODO-17 · 后台/子 agent 在跑时，徽章显示「空闲」

✅ 已修复（活动通道与通知通道拆成正交两条）

**现象**：Claude Code 界面里 agent 明明在跑（`Zesting… (10m 21s)`），tmux 状态栏却是
`▶ 0 ◉ 3 ◆ 0 ◔ 0 ⚠ 0` —— 三个 claude pane 全被判成 `idle`。**全程零报错、零日志。**

**原因**：每个 pane 只有**一个**状态槽 `@whistle`，而「agent 在不在干活」与
「有没有事等你」是两件**正交**的事。单槽模型下，任何一个事件到达都会把另一个顶掉。
完整的降级链（每一环都能在代码里指到具体行）：

1. `UserPromptSubmit` → `@whistle = running`（▶）。
2. Claude Code 发 `Notification`（如后台事件完成）→ hook 把它映射成 `done` →
   **无条件写 `@whistle`，把 `running` 顶掉**。`whistle_state_set` 里唯一的守卫
   只挡「`idle` 不顶掉待处理通知」，**对 `running` 毫无保护**。
3. 用户切进窗口 → `after-select-window[whistle]` → `whistle_read_window`
   → 待处理态被清 → **整格被清空**（`whistle_clear_window` 清的是 `@whistle` 本身）。
4. 紧接着的重算 → `whistle_resolve_idle_panes`：状态为空 + 前台进程是 `claude`
   → **推导出 `idle`** → ◉。
5. 主 agent 还在干活，但**没有任何事件会再把 `running` 点回来**（`UserPromptSubmit`
   只在用户提交新 prompt 时才触发）→ 徽章一直显示「空闲」。

`Stop` 与 `SessionStart`（非 compact）也都能覆盖 `running`，同一个洞；plan mode 下
批准计划后 agent 继续跑、但没有新的 `UserPromptSubmit`，走的是同一条路。

**修复**：拆成两条正交通道。

- **活动通道** `@whistle` ∈ `running | idle | gone` —— 这个 pane 里有没有 agent 在干活。
- **通知通道** `@whistle_notice` ∈ `done | wait | error` —— 有没有事等你。
- **有效态** = 两者按 rank 取高者（`error 5 > wait 4 > done 3 > running 2 > idle 1`），
  写进 pane 级派生值 `@whistle_eff` / window 级 `@whistle_win`。
- 汇总的 `▶/◉` 数活动通道、`◆/◔/⚠` 数通知通道，**两组互不排斥**。
- **已读路径只清通知通道**，绝不动活动通道 —— 这是本次的关键语义修正：
  `whistle_clear_window` / `whistle_clear_all` / `whistle_read_window` /
  `whistle_read_pane` 现在都只碰 `@whistle_notice*`。
- `Notification(agent_needs_input)` / `agent_completed` 是**子 agent** 的事件，
  只写通知通道，**不再碰活动通道**。
- 订阅 `PreToolUse`（任何工具 → 活动 `running`，覆盖 plan 批准后续跑）与
  `SubagentStop`；`PreToolUse` 且 `tool_name` ∈ `Agent`/`Task` 时点亮子 agent 标记。
- **子 agent 标记存的是过期时间戳**（`@whistle_sub = now + @whistle_sub_ttl`），
  过期由推导层按时间戳判断（无需写回）；`lib/spin.sh` 的推进器每
  `@whistle_recompute_every` 帧触发一次全局重算，让过期真正落地 ——
  这是防「标记泄漏 → 永久亮 ▶」的安全阀，挂在推进器上是因为它
  **只在 `count_running > 0` 时活着**，恰好就是需要自愈的场景。

**⚠️ 渲染侧的红线**：两处徽章的 format **层数与结尾大括号一个都没变**。
多通道的合成在**写 option 时**就做完了（`@whistle_eff` / `@whistle_win`），
format 只读一个现成的值 —— 往 `#{?...}` 里再叠一层去合成，配错一格 tmux 会
**静默渲染成空字符串**，是这个项目最贵的坑。

**回归测试**（关键几条）：
- 主 agent `running` 时收到 `Notification(agent_completed)` → 活动仍是 `running`，
  通知通道是 `done`。
- `running` 状态下走已读路径 → 活动**仍是 `running`**，不被降级成 `idle`。
- `PreToolUse(Agent)` 点亮活动与子 agent 标记；`Notification(agent_completed)` 清标记。
- 子 agent 标记过期 → 活动回落 `idle`（TTL 自愈）。
- 汇总里同一个 pane 同时计入 `count_running` 与 `count_done`（两组不互斥）。

**顺带修掉的两处测试基础设施隐患**（不是功能缺陷）：
- `@test` 体末尾写裸 `return 0` 会被 ShellCheck 当成**文件作用域**的 return，
  把它后面所有 `@test` 标成「不可达」（SC2317）。改成 `if` 块。
- `for ... in ... done ...` 里出现字面量 `done` 会触发 SC1010，必须加引号。

**相关代码**：`lib/core.sh`（状态常量、`whistle_effective_state`、推导层列契约、
双写入点、已读路径、`@whistle_eff` 派生）、`hooks/claude-code.sh`（事件映射）、
`lib/install-hooks.sh`（订阅 6→8 个事件）、`lib/status-line.sh`（pane 徽章读
`@whistle_eff`）、`bin/tmux-whistle`（CLI 分流 + 4 个内部子命令）、`lib/spin.sh`。

---

## TODO-20 · 测试残留的隔离 tmux server 会静默关掉 tmux-continuum

✅ 已加固（`wt_reap_stale_sockets` + `make check-no-stray-servers` + doctor 新段落）

**现象**：`tmux kill-server` 之后重新进 tmux，**之前的会话一个都没恢复**。
状态栏、菜单、日志全都正常，**看不出任何异常**。存档文件其实完好。

**触发**：本机同时有第二个 tmux server 在跑。2026-10-29 那次的现场是
`tmux -L whistle-test-115 -f /dev/null new-session ...` —— 一个**测试遗留的隔离
server**，已经挂了 15 小时。

**原因**：tmux-continuum 的自动恢复与自动保存都以「本机只有一个 tmux server」
为前提，两处各有一道门：

```sh
# continuum_restore.sh
if auto_restore_enabled && ! another_tmux_server_running_on_startup; then ... restore ...
# continuum.tmux（自动保存的唯一入口）
if ! another_tmux_server_running; then add_resurrect_save_interpolation; fi
```

判据是 `ps -u <uid> -o command | grep '^tmux'` 数进程。**只要还有第二个 server，
就既不恢复也不保存**（设计意图：怕两个环境互相覆盖存档），而且**完全静默**。

同一个门也解释了另一个观察：存档在 10-27 14:54 之后**整整两天没再产生过**
（`status-right` 里已经看不到 `#(continuum_save.sh)` 这个插值了 —— 它只在插件
加载时注入，被跳过一次就一直不在）。

**为什么测试会留下它**：`teardown` 负责 `kill-server` + 删 socket，但**进程被
外部杀掉时 teardown 根本不会跑**。开发时为了停掉卡住的测试用 `pkill` 杀 bats，
隔离 server 就活了下来。

**加固**：

1. `test/test_helper/whistle.bash` 新增 `wt_reap_stale_sockets`，`wt_start` 先清掉
   「owner 已死」的残留 socket（每个进程只跑一次，避免每个测试都 fork）。
2. `make check` 末尾新增 `check-no-stray-servers`：跑完断言没有
   `whistle-test-*` 活着，否则**报错并列出 pid**。
   ⚠️ 判据必须锚定 `ps` 行首的 pid 之后紧跟 `tmux` —— 只 grep
   `'tmux -L whistle-test-'` 会把**执行检查的那条 shell 命令行**也匹配上（假阳性，
   实测踩到）。
3. `tmux-whistle doctor` 新增「多个 tmux server」段：判据与 continuum 逐字一致
   （除当前 server 外的 tmux 进程数 > 当前 client 数），命中时明说
   「continuum 的自动恢复与自动保存已被静默关闭」。

**恢复办法（存档还在时）**：

```sh
ln -sfn <那一份>.txt ~/.local/share/tmux/resurrect/last
~/.config/tmux/plugins/tmux-resurrect/scripts/restore.sh
# 自动保存的插值要重新注入（它只在插件加载时加）：
~/.config/tmux/plugins/tmux-continuum/continuum.tmux
```

⚠️ 存档目录是 `${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect`，
**不是** `~/.tmux/resurrect` —— 排查时别找错地方。

---

## TODO-18 · 后台 Bash（`run_in_background`）在跑时状态栏看不见

⬜ 待处理

**现象**：`Bash(run_in_background: true)` 起的命令（这个项目里典型是几分钟的
`xcodebuild test`）还在跑，状态栏却显示 `◆` 或 `◉` —— 看起来就像「在跑却显示空闲」。

**触发**：让 Claude Code 用后台 Bash 跑一条几分钟的命令，在主 agent 那一轮结束之后
看状态栏。

**原因**：插件只认 Claude Code 的 hook 事件，而**后台 Bash 不产生任何本插件订阅的
事件**。TODO-17 修好的是「后台/子 **agent**」的可见性（`PreToolUse` 的
`Agent`/`Task` 调用能点亮 `▶`），后台 **Bash** 仍然看不见。

**为什么单独列出来**：2026-10-28 那次「后台在跑、徽章显示空闲」的现场取证
（见下方诊断记录）显示，那个会话里**从来没有 `run_in_background: true` 的
`Agent`/`Task` 调用**，所有后台调用都是 `Bash(xcodebuild test)` —— 也就是说，
用户看到的那个「还在跑的东西」很可能属于本条目，而不是 TODO-17。

**调查线索**：Claude Code v2.1.304 的 hook schema 里还有这些**未订阅**的事件 ——
`SubagentStart`、`TaskCreated` / `TaskCompleted`（后台任务生命周期）、`TeammateIdle`。
`run_in_background` 是 `tool_input` 里的**嵌套字段**，而 `whistle_json_get` 只取
顶层扁平字符串，取嵌套值需要额外实现（jq / python3 分支已有，扩展取值路径即可）。

**修复方向**：先开 `@whistle_debug on`，跑一次后台 `xcodebuild`，从
`${TMPDIR:-/tmp}/tmux-whistle-hooks.log` 里确认**那一刻到底来了哪些事件**，
再按事实接线 —— **不要凭事件名猜语义**。

---

## TODO-19 · `notification_type` 的 `plan_approval` / `idle_prompt` 未处理

⬜ 待处理

**现象**：`plan_approval`（等你批准计划）目前被忽略，plan mode 下 agent 确实在等人，
但状态栏不会有任何「等待」提示。`idle_prompt` 也被忽略。

**原因**：`hooks/claude-code.sh` 的 `whistle_notify_state` 只覆盖
`permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` /
`agent_needs_input` / `agent_completed`。而 v2.1.304 的二进制里还存在
`plan_approval` 与 `idle_prompt` 两个字面量 —— 注意 `notification_type` 在 schema 里
是**裸字符串（不是枚举）**，所以这个集合天然开放，漏掉的类型会静默落到 `''`。

**修复方向**：`plan_approval` 很可能应映射成 `wait`（agent 真的卡在等人），
但要先确认它在运行时确实会发。`idle_prompt` **语义未确认，不要凭名字猜** ——
先看日志里它出现的时机。

**相关代码**：`hooks/claude-code.sh` 的 `whistle_notify_state`。

---

## TODO-21 · 测试偶发「server 还活着却连不上」，并留下清不掉的隔离 server

⬜ 待处理（2026-11-02 记录，**只复现过一次，原因尚未证实**）

**现象**：全量 `make check` 时 `test/integration/cli.bats` 第 102 项在**造数据阶段**失败：
`seed_running_windows` 里的 `wt display` 报
`no server running on /private/tmp/tmux-502/whistle-test-73779`。
同一份代码上一轮这个用例是通过的，单独复跑 `cli.bats` 也是 96/96 全过。
随后 `make check-no-stray-servers` 报出一个残留进程
`55417 tmux -L whistle-test-73779` —— socket 名与失败用例相同。

**已确认的事实**（只有这些，别往外推）：

- 失败发生在 cli.bats 自己的隔离 server 上，不在断言里，在 `new-window` 之后的查询里。
- 失败之后有一个同 socket 名的 server 进程存活，`kill-server` 清不掉它，只能 `kill <pid>`。
- 清理该进程后再跑全量：479 项全绿、无残留 server。

**推断（未证实）**：socket 文件在 server 存活期间被删过。两个可疑入口都在
`test/test_helper/whistle.bash`：`wt_stop` 在 `kill-server` 之后**立刻** `rm -f` socket，
不等 server 真退出，而同一文件内所有测试共用同一个 socket 名（`whistle-test-$$`），
旧 server 退出时若再 unlink 一次同路径，会把新 server 的 socket 一起带走；
`wt_reap_stale_sockets` 在 `tmux ls` 失败时也直接删 socket，server 只是暂时没响应就会误删。

**修复方向**：每个测试用独立 socket 名（在 `wt_start` 里叠加 `$BATS_TEST_NUMBER` 之类后缀），
并且只在确认 server 已退出后才删 socket 文件。改之前先复现，别凭推断动手。

**为什么要重视**：残留 server 会触发 TODO-20 —— tmux-continuum 因此静默关闭自动保存与恢复。

---

## 诊断记录：Claude Code hook 在「后台 agent」场景下的实际行为

> 2026-10-28 · 为「hook 事件追踪日志」（`hooks/claude-code.sh` 的 `whistle_hook_log`）做的查证。
> 每条结论都标了证据强度：**已确认** / **未能确认**。没查到的地方就写没查到，不猜。

### a) 用户报告的那个会话里到底发生了什么

**「后台 agent 在跑」这个前提，未能确认。** 查证过程与结果如下。

数据源：`~/.claude/projects/-Users-rich1e-workspace-code-dayfold/` 下 2026-10-26 之后的
6 个会话（另一个目录 `-...-dayfold-dayfold` 最新只到 10-22，不在范围内）。

| 会话 | 最后修改 | 行数 | `Agent` 调用 | `run_in_background=true` |
|---|---|---|---|---|
| `2b6204cb` | 10-28 17:53 | 1119 | Explore×3 + Plan×1，**全前台** | 无 |
| `093a0763` | 10-28 17:18 | 9 | 无 | 无 |
| `4538337e` | 10-28 16:36 | 7640 | Explore×1 + general-purpose×3，**全前台** | **Bash ×45** |
| `df1b2730` | 10-28 16:35 | 4122 | Explore×4，**全前台** | 无 |
| `64fd50cb` | 10-28 11:28 | 3999 | 无 | **Bash ×9** |
| `d61deea9` | 10-26 14:51 | 1687 | Explore×3 + general-purpose×3，**全前台** | 无 |

- **已确认：没有任何会话用 `run_in_background: true` 起过 `Agent` / `Task`。**
  所有 `run_in_background=true` 的调用都是 `Bash`，内容是
  `xcodebuild test -project dayfold.xcodeproj ...`（单次几分钟）。
- **已确认：没有命名 teammate。** 所有 `Agent` 调用的 `input.name` 都是空；
  `2b6204cb` 里 `ListAgents` 调过 3 次，但会话里没有 teammate 活动。
- **已确认：结束时都不在 plan mode。** 两个大会话都调用过 `ExitPlanMode`，但最后一条
  `permission-mode` 是 `auto`、最后一条 `mode` 是 `normal`。
- **主 agent 当时在跑还是已交付**：
  - `2b6204cb`（最近的那个）：最后一条 assistant 内容块是 `tool_use`，transcript 末尾是
    `tool_result` 紧跟一条 `api-request` —— **主 agent 还在一轮里**。
  - `4538337e`：最后一条 assistant 内容块是 `text`（**已交付**），但此前起过 45 次
    后台 `xcodebuild`。

**推断（未能直接验证）**：用户看到的「后台还在跑」很可能是**后台 Bash（xcodebuild）**，
不是后台 agent。插件只认 hook 事件，**完全看不见后台 Bash** —— 主 agent 一轮结束
（`Stop`）后徽章就落 `done` / `idle`，而后台 `xcodebuild` 仍在跑。这与「有东西在跑、
状态栏却显示空闲」的现象吻合。

> 为什么**未能确认**：transcript 不记录 hook 是否触发、也不记录后台进程存活，
> 无法确认截屏那一刻后台 `xcodebuild` 是否仍在运行。

### b) hook 事件与 `notification_type` 的取值集合

查证对象：本机 Claude Code **v2.1.304**
（`~/.nvm/versions/node/v22.21.1/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`）。
该版本发的是 **271MB 原生二进制、没有 JS 源码可读**，结论全部来自 `strings` 提取的
schema 字面量 —— 所以「存在哪些取值」可靠，「运行时实际会发哪些」不一定。

**已确认：`hook_event_name` 共 33 个取值**（schema 里 `T("<名字>")` 的全集）：

```
PreToolUse  PostToolUse  PostToolUseFailure  Notification
PermissionRequest  PermissionDenied  Elicitation  ElicitationResult
SessionStart  SessionEnd  Setup  Stop  StopFailure
UserPromptSubmit  UserPromptExpansion  SubagentStart  SubagentStop
TaskCreated  TaskCompleted  TeammateIdle  PreCompact  PostCompact
ConfigChange  CwdChanged  DirectoryAdded  FileChanged  InstructionsLoaded
MessageDisplay  PreModelSwitch  PostModelSwitch  PostToolBatch
WorktreeCreate  WorktreeRemove
```

与「后台 / 子 agent 可见性」直接相关、而插件**目前都没订阅**的四个：

- `TeammateIdle` —— teammate（agent team）空闲。正是「agent teams 显示空闲」对应的钩子。
- `SubagentStart` / `SubagentStop` —— 子 agent 起停。
- `TaskCreated` / `TaskCompleted` —— 后台任务生命周期。

> 所以「主 agent 已交付、子/后台 agent 还在跑」这类场景，**当前在插件眼里完全不可见**。
> 这对后续任务（子 agent 可见性）是直接依据。

**已确认：`notification_type` 不是枚举，schema 里是裸字符串**：

```
notification_type:o()        // o() = string，无取值约束
```

含义：插件 `whistle_notify_state` 的 case 列表**天然是开放集合**，遇到没覆盖的类型会
静默落到 `''`（不写状态）。这正是必须有事件日志的原因 —— 否则「发了个新类型但没处理」
永远查不到。

**二进制里出现的 `notification_type` 字面量**（**已确认存在**；**未能确认**哪些是当前
版本运行时真的会发）：

```
permission_prompt   plan_approval   auth_success   elicitation_complete
elicitation_dialog  elicitation_url_dialog   agent_needs_input   agent_completed
idle_prompt         quota_auto_resume_fired   plugin_notification
```

插件现状：`permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` /
`agent_needs_input` → `wait`；`agent_completed` → `done`；其余忽略。

两个值得后续确认的遗漏：

- **`plan_approval`**（等用户批准计划）目前被忽略 —— plan mode 下 agent 确实在等人，
  很可能应映射成 `wait`。
- **`idle_prompt`** 目前被忽略 —— 语义未确认，不要凭名字猜。

**已确认（顺带）**：`SessionStart.source` 的取值是
`startup | resume | clear | compact | fork` —— 插件对 `compact` 的特判有效，
`fork` / `clear` 会照常落 `idle`。
（`UserPromptSubmit.source` 是另一套：`user | sdk | system | loop_wakeup |
schedule_wakeup | poll_event`，两者不同源，不要混用。）

