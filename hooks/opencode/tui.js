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

import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
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

    // 调试开关：TUI 没有读 tmux option 的 API，让 shell 代查一次（同步，开机只一次）。
    // 开着才写 trace —— 默认零副作用，不产生任何文件。
    const debugOn = (() => {
      try {
        const r = spawnSync(hook, ["--debug-on"], {
          stdio: "ignore",
          timeout: 1500,
          env: { ...process.env, TMUX_PANE: pane },
        });
        return r.status === 0;
      } catch {
        return false;
      }
    })();

    const trace = (msg) => {
      if (!debugOn) return;
      try {
        const p =
          process.env.WHISTLE_HOOK_LOG ||
          join(process.env.TMPDIR || tmpdir(), "tmux-whistle-hooks.log");
        appendFileSync(p, `${new Date().toISOString()} [js] agent=opencode trace ${msg}\n`);
      } catch {}
    };

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
    // 「本 TUI 是否开着这个 session」—— 过滤掉别的 TUI 的事件。
    // 共享 server 下所有 TUI 都收全部事件，不过滤就会在多个 pane 重复上报。
    //
    // ⚠️ 拿不到就 **fail-open**（返回 null = 不过滤），绝不返回空集合：
    // tabs 功能关闭 / 单 session 模式下 list() 可能返回空或形状不同，
    // 那时若当成「一条都不属于我」就会把所有事件丢光，且完全静默。
    // 记 trace 是为了下次能看出到底是哪种情况（R11）。
    const mine = () => {
      try {
        const list = context.ui?.tabs?.list?.();
        if (!Array.isArray(list) || list.length === 0) {
          trace("tabs-empty fail-open");
          return null;
        }
        const ids = new Set();
        for (const it of list) {
          if (typeof it === "string") ids.add(it);
          else if (it && typeof it === "object") {
            const id = it.sessionID ?? it.sessionId ?? it.id ?? it.session?.id;
            if (id) ids.add(String(id));
          }
        }
        if (ids.size === 0) {
          trace("tabs-shape-unknown fail-open");
          return null;
        }
        return ids;
      } catch (err) {
        trace(`tabs-error fail-open err=${String(err && err.message ? err.message : err)}`);
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

    // 把一条事件翻译成 shell 能吃的扁平 JSON 并排队发送。
    // 抽成函数是为了让「逐类型订阅」与「全量流兜底」两条路径共用同一套逻辑。
    const handle = (type, data) => {
      data = data ?? {};
      const sessionID = data.sessionID;
      if (!sessionID) {
        trace(`drop type=${type} reason=no-sessionID`);
        return;
      }

      const allowed = mine();
      if (allowed && !allowed.has(sessionID)) {
        trace(`drop type=${type} reason=not-my-tab session=${sessionID} tabs=${[...allowed].join(";")}`);
        return;
      }

      trace(`accept type=${type} session=${sessionID}`);

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

      const child = isChild(sessionID);
      if (child) payload.child = child;

      send(payload);
    };

    // ⚠️ **逐类型订阅必须各自 try/catch**：某一条 data.on() 抛异常会打断
    // 整个循环，后面所有事件都收不到，而且**完全静默** —— 探针照样有记录，
    // 状态栏却一直是 ◉。2026-11-13 就是这么坏的。
    const unsubs = [];
    const subscribed = [];
    const failed = [];

    for (const type of EVENTS) {
      try {
        const stop = context.data.on(type, (event) => {
          // 兼容两种形状：{ data } 或直接给 data。
          handle(type, event?.data ?? event ?? {});
        });
        if (typeof stop === "function") unsubs.push(stop);
        subscribed.push(type);
      } catch (err) {
        failed.push(type);
        trace(`subscribe-failed type=${type} err=${String(err && err.message ? err.message : err)}`);
      }
    }

    // 兜底：逐类型订阅失败的那些，改从全量事件流里筛。
    // 官方文档：data.listen 收全部 server 事件（形状是 { details }）。
    if (failed.length > 0 && typeof context.data.listen === "function") {
      try {
        const stop = context.data.listen((arg) => {
          const type = arg?.details?.type ?? arg?.type ?? arg?.event?.type;
          if (!type || !failed.includes(type)) return;
          handle(type, arg?.details?.data ?? arg?.data ?? {});
        });
        if (typeof stop === "function") unsubs.push(stop);
        trace(`listen-fallback for ${failed.join(",")}`);
      } catch (err) {
        trace(`listen-failed err=${String(err && err.message ? err.message : err)}`);
      }
    }

    trace(`subscribed=${subscribed.length}/${EVENTS.length} failed=${failed.join(",") || "none"}`);

    // 把订阅结果带进探针，doctor 一眼能看出「订阅建立了几条」。
    try {
      const summary = spawn(hook, ["--probe", String(subscribed.length), failed.join(",")], {
        stdio: "ignore",
        env: { ...process.env, TMUX_PANE: pane },
      });
      summary.on("error", () => {});
    } catch {}

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
