# 功能待办

开发过程中发现的问题与已知限制。每条都记录了**现象、触发方式、原因**，
修掉之后挪到「已修复」留档 —— 这些多数属于「不报错、只是行为不对」的类型，
只有留档才不会在重构时重新踩回去。

状态：⬜ 待处理 · ✅ 已修复

## 待处理

### 功能缺陷

（暂无）

### 缺失能力

（暂无）

### 文档缺陷

- [ ] **TODO-8** `@whistle_detect_wait-re` / `done-re` 代码在读，但文档里没有

## 已修复

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
按任何键都选不中。**菜单本身正常弹出**，其余功能（徽章、🔔 计数、瞬时提示、
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
—— 而 `running` 不计入 pending、🔔 不亮，非 Claude Code 的进程更没有 SessionEnd
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

## 本轮新增（2026-10-22）

三条功能，不是缺陷：

1. **`error` 接上自动来源** —— 订阅 Claude Code 的 `StopFailure` 事件
   （回合因 API 错误结束时**替代** `Stop` 触发，两者互斥）。消息取
   `last_assistant_message`（该字段在这个事件里就是渲染出来的错误文本，
   如 `API Error: Rate limit reached`），缺失时回落到错误类型名。
2. **`running` 显示徽章** —— 新增 `@whistle_icon_running` / `@whistle_color_running`，
   徽章条件式从三层变四层。它仍不计入 `🔔N`、不算待处理。
   <br>_（2026-10-23 改动：默认图标由 `●` 换成绿色 `▶`，默认色由 `#5f87af` 换成 `#00af00`。）_
3. **`prefix + n` 列出所有 agent** —— 新增 `whistle_agent_windows()`（按 window 去重、
   取 rank 最高的一行）。待处理项带编号可跳转。
   <br>_（2026-10-23 修正：running 项最初是 `-` 开头的 disabled 条目，只能看不能点。
   现在它与待处理项共用同一套 1–26 键位，都能跳，用绿色 `▶` 前缀区分。见下方「已修」。）_
4. **`running` 有了灭灯信号** —— 订阅 `SessionEnd`，agent 退出时清掉该 pane 的 running
   （见 TODO-11）。
5. **status-right 增加四态汇总** —— `▶1 ✓1 ◷0 ✗0`。`whistle_count_states`（纯函数）
   从同一份 `list-panes` 输出算四态分布，写入 `@whistle_count_*`；汇总段与 `🔔N`
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
