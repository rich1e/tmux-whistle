# 版本号与发布规范

tmux-whistle 使用 **SemVer 2.0 + 预发布阶段 + 构建 metadata**。
版本真源位于 `bin/tmux-whistle` 顶部，CLI、doctor、安装器和 Makefile 都从同一处读取。

当前首个版本：

```text
0.1.0-alpha.1+20261030.1
```

## 1. 完整格式

```text
<MAJOR>.<MINOR>.<PATCH>[-<stage>.<N>]+<YYYYMMDD>.<BUILD>
```

示例：

```text
0.1.0-alpha.1+20261030.1   内测第 1 版，2026-10-30 的第 1 号对外构建
0.1.0-beta.1+20261115.18   公测第 1 版
1.0.0+20261201.42          首个正式版
```

`+` 后是 **build metadata**。按照 SemVer，它不参与版本优先级比较；不能靠增加构建日期或流水号代替 MAJOR/MINOR/PATCH 升版。

## 2. 主版、次版、修订

| 变化 | 升版规则 | 示例 |
|---|---|---|
| 公共 CLI、hook 参数或状态协议出现不兼容变化 | MAJOR，MINOR/PATCH 归零 | `1.4.2 → 2.0.0` |
| 新增向下兼容功能，或弃用但仍保留公共能力 | MINOR，PATCH 归零 | `1.3.2 → 1.4.0` |
| 只有向下兼容的问题修复 | PATCH | `1.3.2 → 1.3.3` |

0.x 表示公共接口仍可能调整。进入 `1.0.0` 前，公共 CLI、hook 事件参数与状态通道协议必须稳定。

## 3. 内测、公测、正式版

| 阶段 | 格式 | 用途 |
|---|---|---|
| 内测 | `-alpha.N` | 接口和交互仍在验证，主要供开发与早期试用 |
| 公测 | `-beta.N` | 核心功能已具备，扩大使用并收集兼容性问题 |
| 正式版 | 无后缀 | 已通过对应发布验收，不是预发布版本 |

N 从 1 开始，按数值递增，不使用 `01` 等前导零。首轮演进：

```text
0.1.0-alpha.1 → 0.1.0-beta.1 → 1.0.0
```

阶段与 MAJOR/MINOR/PATCH 是两条规则：修 bug 仍升 PATCH，阶段变化则调整预发布后缀；不能只改构建号表示功能升版。

## 4. 构建日期与流水号

```text
WHISTLE_BUILD_DATE='20261030'
WHISTLE_BUILD_NUMBER='1'
```

- 日期使用发布构建时的 **UTC `YYYYMMDD`**，不是用户运行 `--version` 时的当天日期。
- 流水号是该发布线的对外构建编号，首个为 1；新的对外构建递增，不按日重置。
- 重复查询或重复执行同一源码不会自动增加流水号。
- 每次新的对外源码发布，都要同时检查 base、构建日期和流水号是否需要更新。
- 不开放运行时环境变量覆盖版本；否则当次输出、安装制品与实际代码可能不一致。
- 当前版本表示源码中声明的发布/构建版本，不声称识别 dirty worktree 或精确 commit。

## 5. 查询与校验

```sh
tmux-whistle --version
# tmux-whistle 0.1.0-alpha.1+20261030.1

tmux-whistle version           # 同义命令
make version                   # 开发入口，复用同一个 CLI
make check-version             # 校验 SemVer、阶段、构建戳和实际输出
make check                     # 已包含 check-version
```

`--version` 在加载 lib、tmux 或 git 之前执行。即使只复制一份 CLI、PATH 指向不存在目录，也应能查询。

`check-version` 只检查格式和输出一致性，不判断日期是否等于今天、流水号是否比历史更大，也不操作 git。

## 6. 修改版本的位置

只修改 `bin/tmux-whistle` 顶部三个常量：

```sh
WHISTLE_VERSION='0.1.0-alpha.1'
WHISTLE_BUILD_DATE='20261030'
WHISTLE_BUILD_NUMBER='1'
```

不要在 README、doctor、install.sh 或 Makefile 中另写一份版本号；这些入口必须复用 CLI 输出。

## 7. 手工发布清单

首轮不自动创建 tag、不自动 push。维护者按顺序执行：

1. 在版本提交中更新 base、构建日期和流水号。
2. 同步更新 README 与开发文档中的当前版本示例；通用版本测试从 CLI 常量读取夹具，无需逐次改测试。
3. 运行 `make fmt`、`make check`、`make version`，核对完整输出。
4. 确认当前为 `main`，HEAD 就是准备发布的提交，工作区干净。
5. 确认提交已经按发布计划推送，且本地与远端不存在同名 tag。
6. 创建 annotated tag，标签只含 base，不含 build metadata：

   ```sh
   git tag -a 'v0.1.0-alpha.1' -m 'tmux-whistle 0.1.0-alpha.1'
   ```

7. 人工分别推送提交和 tag：

   ```sh
   git push origin main
   git push origin v0.1.0-alpha.1
   ```

**不自动 push、不强推、不移动或复用已经发布的 tag。** 新的公开发布必须使用新的 base；不能只改 build metadata 后复用旧 tag。
