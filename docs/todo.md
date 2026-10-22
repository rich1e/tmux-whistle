# 功能待办

开发过程中发现的问题与已知限制。每条都记录了**现象、触发方式、原因**，
修掉之后挪到「已修复」留档 —— 这些多数属于「不报错、只是行为不对」的类型，
只有留档才不会在重构时重新踩回去。

状态：⬜ 待处理 · ✅ 已修复

## 待处理

- [ ] **TODO-1** `jump` 不接受裸窗口名，但 `list` 显示的正是窗口名
- [ ] **TODO-2** 菜单超过 26 项时静默截断

## 已修复

- [x] **TODO-3** 菜单第 10 项起没有快捷键
- [x] **TODO-4** `make fmt-check` 实际没有检查 bash 测试文件

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

## 相关

- 开发与测试约定：[development.md](development.md)
- 使用者文档：[../README.md](../README.md)
