// tmux-whistle 的 OpenCode TUI 插件。
//
// 职责只有三件：订阅事件、按「本 TUI 是否开着这个 session」过滤、spawn
// hooks/opencode.sh。**业务逻辑一概不在 JS 里** —— 状态映射全在 lib/opencode.sh，
// 原因见 docs/opencode-integration-plan.md §3.3：
//   · 仓库的 make check 不需要 node，逻辑进 JS 就引入 npm 依赖链
//   · 映射可被 bats 直接测（source 纯函数层）
//   · 少受 @opencode-ai/plugin 的版本漂移影响
//
// ⚠️ 为什么是 TUI part 而不是 server part：
// OpenCode 是「TUI 进程 + 共享后台服务」双进程。server 的环境是**启动快照**，
// 事件里又没有 pane 信息（99 个 V2 事件一个都没有）。只有 TUI 进程的
// TMUX_PANE 可信。所以本文件所在目录必须以**目录**形态软链进 plugins/
// （`tui.js` 这个文件名是契约，改了就不被认成 TUI part）。
//
// ⚠️ spawn 时必须**显式传** TMUX_PANE / TMUX —— 不依赖继承。

import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// 订阅哪些事件。与 lib/opencode.sh 的 whistle_oc_actions 一一对应；
// 这里多订 session.retry.scheduled 与 session.idle 是**故意的**：
// 映射层不处理它们，但 debug 日志要留痕（否则「收到了但没处理」查不到）。
const EVENTS = [
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.tool.called",
  "permission.asked",
  "permission.replied",
  "session.shell.started",
  "session.shell.ended",
  "session.retry.scheduled",
  "session.idle",
];

// hooks/opencode/tui.js → 仓库根。
// 用 import.meta.url 而不是 process.cwd()（那是用户项目目录）或 process.argv[1]
// （软链路径，.. 会指到 ~/.config/opencode/）。
// realpathSync 显式解析一次，不依赖 Node 的默认行为。
function repoRoot() {
  const here = fileURLToPath(import.meta.url);
  return dirname(dirname(dirname(realpathSync(here))));
}

export default {
  id: "tmux-whistle",
  async setup(context) {
    // 不在 tmux 里就整体退化为 no-op —— 没有 pane 可标记。
    const pane = process.env.TMUX_PANE;
    if (!pane) return;

    const root = repoRoot();
    const hook = join(root, "hooks", "opencode.sh");

    // 自检：报一次「我在 TUI 里活过来了」。
    // 这条是 R3 的可观测出口 —— 没加载则日志里一行都不会有；
    // 加载进 server 则日志里会带错误的 TMUX_PANE。
    // 只在 @whistle_debug=on 时真的落盘（与事件日志同一开关）。
    try {
      const probe = spawn(hook, ["--probe"], {
        stdio: "ignore",
        env: { ...process.env, TMUX_PANE: pane },
      });
      probe.on("error", () => {});
    } catch {}

    // 启动报 idle（◉）——「TUI 起来了」不等于「agent 在干活」。
    // 必须做，否则上一轮退出写的 gone（rank 0、不显示）会一直留着：
    // 推导层只把**空**状态推成 idle，gone 不是空，救不回来。
    try {
      const start = spawn(hook, ["--tui-start"], {
        stdio: "ignore",
        env: { ...process.env, TMUX_PANE: pane },
      });
      start.on("error", () => {});
    } catch {}

    // 事件 → 传给 shell 的扁平 JSON。
    // 只取需要的字段：shell 侧不做嵌套解析（jq/python3/sed 三级降级都只认顶层）。
    //
    // ⚠️ **必须串行**：每条事件 spawn 一个子进程去写 tmux。并发 spawn 时
    // 子进程完成顺序不保证 —— 实测过 `permission.asked`(wait) 与
    // `execution.succeeded`(done) 并发时，done 后到把 ◔ 盖成了 ◆。
    // 状态写入是有序语义（后发生的事件赢），所以这里用一条 promise 链排队。
    //
    // 代价是串行延迟（每个子进程几十毫秒）。事件频率不高 ——
    // tool.called 可能密一些，但它只写一个 @whistle=running，幂等且极快。
    let queue = Promise.resolve();
    const send = (payload, extra) => {
      const body = JSON.stringify({ ...payload, ...extra });
      queue = queue
        .then(
          () =>
            new Promise((resolve) => {
              try {
                const child = spawn(hook, [], {
                  stdio: ["pipe", "ignore", "ignore"],
                  env: { ...process.env, TMUX_PANE: pane },
                });
                child.on("error", () => resolve());
                child.on("close", () => resolve());
                child.stdin.on("error", () => {});
                child.stdin.end(body);
              } catch {
                resolve();
              }
            })
        )
        .catch(() => {});
    };

    // 「本 TUI 是否开着这个 session」—— 过滤掉别的 TUI 的事件。
    // 共享 server 下所有 TUI 都收全部事件，不过滤就会在多个 pane 重复上报。
    //
    // ⚠️ 若 tabs 功能关闭、list() 返回空，**不能**把事件全丢掉（那会静默无状态）。
    // 取不到就 fail-open。这条与 R11 对应。
    const mine = () => {
      try {
        const list = context.ui?.tabs?.list?.();
        return Array.isArray(list) && list.length > 0 ? new Set(list) : null;
      } catch {
        return null;
      }
    };

    const isChild = (sessionID) => {
      try {
        const s = context.data?.session?.get?.(sessionID);
        return s && s.parentID ? "1" : "";
      } catch {
        return "";
      }
    };

    const unsubs = [];
    for (const type of EVENTS) {
      const stop = context.data.on(type, (event) => {
        const data = event?.data ?? {};
        const sessionID = data.sessionID;
        if (!sessionID) return;

        const allowed = mine();
        if (allowed && !allowed.has(sessionID)) return;

        // 只挑顶层标量字段，shell 侧不做嵌套解析。
        const payload = { event: type, sessionID };

        if (type === "session.execution.interrupted") {
          payload.reason = String(data.reason ?? "");
        }
        if (type === "permission.replied") {
          payload.reply = String(data.reply ?? "");
        }
        if (type === "permission.asked") {
          // 权限请求的文案：优先 message，回落成「动作 + 资源」。
          const action = String(data.action ?? "");
          const res = Array.isArray(data.resources) ? data.resources.join(", ") : "";
          payload.message = data.message || `${action}${res ? ": " + res : ""}`;
        }
        if (type === "session.execution.failed") {
          payload.message = String(data.error?.message ?? data.error?.type ?? "");
        }
        if (type === "session.execution.succeeded" || type === "session.execution.started") {
          // 标题：OpenCode 的 session 标题（本地缓存，不发请求）。
          try {
            const title = context.data?.session?.get?.(sessionID)?.title;
            if (title) payload.message = String(title);
          } catch {
            // 取不到标题不影响状态。
          }
        }
        if (type === "session.shell.started" || type === "session.shell.ended") {
          const shell = data.shell ?? {};
          payload.shellID = String(shell.id ?? "");
          payload.shellStatus = String(shell.status ?? "");
          if (type === "session.shell.started" && shell.command) {
            payload.message = String(shell.command);
          }
        }
        if (type === "session.tool.called" || type === "session.retry.scheduled") {
          // 不写状态，只留 debug 日志。
        }

        const child = isChild(sessionID);
        if (child) payload.child = child;

        send(payload);
      });
      if (typeof stop === "function") unsubs.push(stop);
    }

    // cleanup：TUI 要退了，同步写 gone。
    // 不写 gone 会留一盏灭不掉的 ▶ —— 收尾时 pane_current_command 仍是 opencode，
    // 清空状态会被紧接着的重算又认成 idle。
    //
    // ⚠️ 必须先等 queue 排空：退出时可能有事件还没落盘（比如最后那条
    // execution.succeeded），直接写 gone 会把它们冲掉。
    // 然后同步等 --tui-exit 结束 —— 异步的话 TUI 退出会带走子进程，
    // 清除跑到一半被杀，gone 就写不进去。
    return async () => {
      for (const stop of unsubs) {
        try {
          stop();
        } catch {}
      }
      try {
        await queue;
      } catch {}
      try {
        await new Promise((resolve) => {
          const child = spawn(hook, ["--tui-exit"], {
            stdio: "ignore",
            env: { ...process.env, TMUX_PANE: pane },
          });
          child.on("error", () => resolve());
          child.on("close", () => resolve());
        });
      } catch {}
    };
  },
};

export { EVENTS };
