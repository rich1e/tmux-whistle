#!/usr/bin/env bats
# shellcheck shell=bash
#
# L3 端到端：喂构造的 Claude Code hook JSON 进 hooks/claude-code.sh，
# 断言退出码、stdout 为空、以及写出的 tmux 状态。
#
# ⚠️ 状态是**两条正交通道**，不是一个槽：
#     活动通道 @whistle         running / idle / gone
#     通知通道 @whistle_notice  done / wait / error
#   一个 pane 可以同时是 running + done。子 agent 的事件只写通知通道。
#
# 本文件最上面那组「双通道正交」用例是本次 bug 的回归测试：
# 后台 agent 完成时**绝不能**把主 agent 的 running 顶掉。

load '../test_helper/whistle'

setup() {
  wt_start
  unset TMUX_PANE TMUX TMUX_SOCKET
  # hook 进程靠 $TMUX_PANE 定位 pane，模拟"Claude Code 跑在这个 pane 里"
  export TMUX_PANE
  TMUX_PANE=$(wt display -p -t w1 '#{pane_id}')
  export WHISTLE_TMUX_SOCKET
  WHISTLE_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export WHISTLE_ROOT
}

teardown() {
  wt_stop
}

HOOK="$WHISTLE_ROOT/hooks/claude-code.sh"

feed() {
  run env TMUX_PANE="$TMUX_PANE" "$HOOK"
  assert_eq "$status" 0
  # Claude Code 会把 stdout 当 JSON 解析，任何输出都会干扰它
  assert_eq "$output" ''
}

# -- 通道读取 --------------------------------------------------------------
#
# 用 optp 读 pane 级 option（opt/optw 读的是 global，读错作用域会静默读空、
# 测试假绿）。

pane_act() { optp @whistle "$TMUX_PANE"; }
pane_eff() { optp @whistle_eff "$TMUX_PANE"; }
pane_notice() { optp @whistle_notice "$TMUX_PANE"; }
pane_notice_msg() { optp @whistle_notice_msg "$TMUX_PANE"; }
pane_notice_body() { optp @whistle_notice_body "$TMUX_PANE"; }
pane_sub() { optp @whistle_sub "$TMUX_PANE"; }

win_state() {
  local w
  w=$(wt display -p -t w1 '#{window_id}')
  wt show -wv -t "$w" @whistle_win 2> /dev/null || printf ''
}

# -- 双通道正交（本次 bug 的回归测试） --------------------------------------
#
# 根因链：主 agent 在跑（活动 running）→ 后台 agent 完成发
# Notification{agent_completed} → 早先无条件写 @whistle=done，把 running 顶掉
# → 用户切进窗口读掉通知 → 整格被清 → 推导层按「前台跑着 claude」认成 idle。
# 一个正在干活的 agent 显示成「空闲」，且零报错。
#
# 修法：子 agent 的事件只写通知通道，活动通道一动不动。

@test "e2e: 主 agent running 时 agent_completed → 活动仍 running，通知 done" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"开始干活"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_completed","message":"后台任务完成"}
EOF
  # 核心断言：活动通道没被顶掉
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '后台任务完成'
}

@test "e2e: 主 agent running 时 agent_needs_input → 活动仍 running，通知 wait" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"开始干活"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"teammate 在问你"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'wait'
}

@test "e2e: 通知不影响已点亮的活动通道（wait 也是）" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"开工"}
EOF
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"要批准"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'wait'
}

# -- Stop / StopFailure ----------------------------------------------------
#
# 一轮结束 = 两条通道各写一条：活动回落 idle，通知亮 done / error。

@test "e2e: Stop → 活动 idle + 通知 done，消息取自 last_assistant_message 首行" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp",
 "last_assistant_message":"重构完成：抽出了 core.sh\n\n其余细节在这里"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '重构完成：抽出了 core.sh'
  assert_eq "$(optp @whistle_src "$TMUX_PANE")" 'hook'
}

@test "e2e: Stop 的完整回复进通知正文，首行进通知消息" {
  # 改动前 last_assistant_message 被 head -n 1 砍掉首行以外的全部内容，
  # 那部分**无处可寻**。现在全文留在 @whistle_notice_body。
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp",
 "last_assistant_message":"重构完成：抽出了 core.sh\n拆开了状态机与渲染，其余细节在这里"}
EOF
  assert_eq "$(pane_notice_msg)" '重构完成：抽出了 core.sh'
  assert_eq "$(pane_notice_body)" \
    '重构完成：抽出了 core.sh 拆开了状态机与渲染，其余细节在这里'
}

@test "e2e: Stop 缺消息时正文也是空，不留残值" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_body)" ''
}

@test "e2e: Stop 缺 last_assistant_message 时也能置通知" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" ''
}

@test "e2e: Stop 消息里的 format 注入串被消毒" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"#{?window_active,EVIL,x}"}
EOF
  local m
  m=$(pane_notice_msg)
  assert_not_contains "$m" '#'
  assert_not_contains "$m" '{'
}

@test "e2e: Stop 会连带更新窗口徽章与全局计数" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  # 有效态 = 通知 done（rank 3）压过活动 idle（rank 1）
  assert_eq "$(win_state)" 'done'
  assert_eq "$(opt '@whistle_pending')" '1'
}

# -- 后台任务在飞（Stop 输入里的 background_tasks） --------------------------
#
# Claude Code 从 v2.1.145 起，Stop / SubagentStop 的 hook 输入带
# background_tasks 数组，列出「已后台化且还在飞」的工作
# （type 是友好标签：shell / subagent / workflow / monitor / MCP task …）。
#
# 主回合结束时若数组里有 shell / subagent / workflow，这一轮就**不算做完**：
# 活动态保持 running，且**不写 done 通知** —— 有效态按 rank 取高者
# （done 3 > running 2），报 done 会把 running 盖掉，徽章显示成「◆ 完成」，
# 正是 TODO-18 记的「在跑却显示完成」。
#
# 后台任务结束、Claude 被叫醒再跑一轮时，那一轮的 Stop 里数组已经空了 ——
# 那时才写 done、回落 idle。这是整个方案的闭环，必须钉住。

@test "e2e: Stop 带后台 shell → 活动 running、不写 done 通知" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"构建已在后台启动",
 "background_tasks":[{"id":"t1","type":"shell","status":"running",
   "description":"xcodebuild test","command":"xcodebuild test"}]}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(optp @whistle_msg "$TMUX_PANE")" '后台: xcodebuild test'
  # 有效态 = running（没有通知可压它）
  assert_eq "$(pane_eff)" 'running'
  # 通知通道一个字都不写：这一轮还没做完
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_notice_msg)" ''
  # 助手这一轮的结论文案不丢 —— 落在活动正文里
  assert_eq "$(optp @whistle_body "$TMUX_PANE")" '构建已在后台启动'
  # 全局 running 计数跟着走
  assert_eq "$(opt '@whistle_count_running')" '1'
}

@test "e2e: 后台结束后下一轮 Stop → 活动 idle + 通知 done" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"构建已在后台启动",
 "background_tasks":[{"id":"t1","type":"shell","status":"running","description":"xcodebuild test"}]}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" ''

  # 后台任务结束、Claude 被叫醒再跑一轮 —— 这一轮的数组已经空了
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"构建通过",
 "background_tasks":[]}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_notice_msg)" '构建通过'
  assert_eq "$(pane_eff)" 'done'
}

@test "e2e: 后台 subagent / workflow 也算在跑" {
  local t
  for t in subagent workflow; do
    feed <<EOF
{"hook_event_name":"Stop","background_tasks":[{"id":"t1","type":"$t","status":"running","description":"bg-$t"}]}
EOF
    assert_eq "$(pane_act)" 'running'
    assert_eq "$(pane_notice)" ''
  done
}

@test "e2e: monitor / MCP task 不算在跑（长驻监视器不该长期亮着 ▶）" {
  local t
  for t in monitor "MCP task"; do
    feed <<EOF
{"hook_event_name":"Stop","last_assistant_message":"做完了",
 "background_tasks":[{"id":"t1","type":"$t","status":"running","description":"watch"}]}
EOF
    assert_eq "$(pane_act)" 'idle'
    assert_eq "$(pane_notice)" 'done'
  done
}

@test "e2e: background_tasks 缺失或不是数组 → 照旧 idle + done" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'

  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了","background_tasks":"oops"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'done'
}

@test "e2e: 多个后台任务 → 标题显示个数；没有 description 时退回 command" {
  feed <<'EOF'
{"hook_event_name":"Stop","background_tasks":[
 {"id":"t1","type":"shell","status":"running","description":"xcodebuild"},
 {"id":"t2","type":"shell","status":"running","description":"npm run dev"}]}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(optp @whistle_msg "$TMUX_PANE")" '后台: 2 个任务'

  feed <<'EOF'
{"hook_event_name":"Stop","background_tasks":[{"id":"t1","type":"shell","status":"running","command":"npm run dev"}]}
EOF
  assert_eq "$(optp @whistle_msg "$TMUX_PANE")" '后台: npm run dev'
}

# 官方文档：StopFailure 在回合因 API 错误结束时**替代** Stop 触发（两者互斥）。
# 它是 error 状态唯一的自动来源 —— 在此之前 error 只能靠手工
# `tmux-whistle error`，agent 因限流挂掉时状态栏毫无反应。

@test "e2e: StopFailure → 通知 error，消息取 last_assistant_message（错误文本本身）" {
  feed <<'EOF'
{"hook_event_name":"StopFailure","session_id":"s1","cwd":"/tmp",
 "error":"rate_limit","error_details":"429 Too Many Requests",
 "last_assistant_message":"API Error: Rate limit reached"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(pane_notice)" 'error'
  assert_eq "$(pane_notice_msg)" 'API Error: Rate limit reached'
  assert_eq "$(optp @whistle_src "$TMUX_PANE")" 'hook'
}

@test "e2e: StopFailure 缺 last_assistant_message 时回落到错误类型" {
  feed <<'EOF'
{"hook_event_name":"StopFailure","error":"overloaded"}
EOF
  assert_eq "$(pane_notice)" 'error'
  assert_eq "$(pane_notice_msg)" 'API 错误: overloaded'
}

@test "e2e: 各种错误类型都落成 error，不会被误判为 done" {
  local e
  for e in rate_limit overloaded authentication_failed server_error unknown; do
    feed <<EOF
{"hook_event_name":"StopFailure","error":"$e"}
EOF
    assert_eq "$(pane_notice)" 'error'
    assert_eq "$(pane_notice_msg)" "API 错误: $e"
  done
}

@test "e2e: StopFailure 计入待处理计数（它需要你处理）" {
  feed <<'EOF'
{"hook_event_name":"StopFailure","error":"billing_error",
 "last_assistant_message":"API Error: Billing issue"}
EOF
  assert_eq "$(opt '@whistle_pending')" '1'
}

@test "e2e: StopFailure + 后台在飞 → 活动 running，通知仍是 error" {
  feed <<'EOF'
{"hook_event_name":"StopFailure","error":"rate_limit",
 "last_assistant_message":"API Error: Rate limit reached",
 "background_tasks":[{"id":"t1","type":"shell","status":"running","description":"xcodebuild"}]}
EOF
  # 活动态：后台还有活，没干完
  assert_eq "$(pane_act)" 'running'
  # 通知态：API 错误 rank 高于 running，用户必须知道这一轮挂了
  assert_eq "$(pane_notice)" 'error'
  assert_eq "$(pane_notice_msg)" 'API Error: Rate limit reached'
  assert_eq "$(pane_eff)" 'error'
}

# -- PreToolUse / SubagentStop ---------------------------------------------
#
# PreToolUse 是 plan 模式的关键补丁：plan 批准后没有新的 UserPromptSubmit，
# 只有工具调用 —— 靠它把 running 点回来。

@test "e2e: PreToolUse(Agent) → 活动 running + 子 agent 标记写入" {
  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF
  # 标记存的是过期的 epoch 时间戳，非空即代表「有子 agent 在跑」
  local sub
  sub=$(pane_sub)
  [ -n "$sub" ] || {
    echo "期望写入 @whistle_sub，实际为空" >&2
    return 1
  }
  # 活动态可以是直接写的 @whistle=running，也可以由推导层按标记合成
  # （@whistle_eff=running）—— 两种都算「这个 pane 在干活」。
  local act eff
  act=$(pane_act)
  eff=$(pane_eff)
  if [ "$act" != running ] && [ "$eff" != running ]; then
    echo "期望活动 running，实际 @whistle=[$act] @whistle_eff=[$eff]" >&2
    return 1
  fi
}

@test "e2e: PreToolUse(Bash) → 活动 running，不写子 agent 标记" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$(pane_act)" 'idle'

  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Bash"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_sub)" ''
}

@test "e2e: PreToolUse 在当前活动是 gone 时不改回 running" {
  # SessionEnd 已经宣告 agent 走了。把 gone 改回 running 会让一盏已经灭掉的
  # ▶ 重新亮起，而它再也没人灭。
  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
EOF
  assert_eq "$(pane_act)" 'gone'

  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Bash"}
EOF
  assert_eq "$(pane_act)" 'gone'
}

@test "e2e: agent_completed 清掉子 agent 标记" {
  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF
  [ -n "$(pane_sub)" ]

  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_completed","message":"后台任务完成"}
EOF
  assert_eq "$(pane_sub)" ''
  assert_eq "$(pane_notice)" 'done'
}

@test "e2e: SubagentStop 只清标记，不动活动通道（主 agent 可能还在跑）" {
  # 回归（2026-11-02 用户实测截图）：子 agent 结束时把活动态写成 idle，
  # 会把**正在等结果的主 agent**标成「空闲」—— 状态栏与菜单都显示错，
  # 且全程零报错。活动态的收尾归 Stop 事件管。
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF
  [ -n "$(pane_sub)" ]

  feed <<'EOF'
{"hook_event_name":"SubagentStop"}
EOF
  assert_eq "$(pane_sub)" ''
  # 主 agent 这一轮还没结束（Stop 才是收尾），所以活动态保持 running。
  # 修复前这里是 idle。
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_eff)" 'running'
}

@test "e2e: 主回合结束后活动态才回到 idle" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"Stop"}
EOF
  assert_eq "$(pane_act)" 'idle'
}

# 现场（2026-11-02 用户实测，dayfold 那个 pane）：
#   主回合结束时后台子 agent 还在跑 → Stop 写的 idle 被 @whistle_sub 就地转成
#   running 存进 @whistle；子 agent 随后结束、标记被清掉，但 @whistle 里那份
#   running **没有任何事件再改写它** → 那盏 ▶ 亮到下一次事件为止（实测 33 分钟）。
#
# 修法：Stop 写什么就存什么（idle），「还有子 agent 在跑」由**推导层**按标记
# 合成 —— 这本来就是 whistle_sub_set 注释里写的设计，@whistle 存 running
# 等于把推导结果烤进了真源，标记一清就再也回落不了。

@test "e2e: 子 agent 在跑时 Stop → 标记清掉后能回落 idle，不留永久 ▶" {
  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF
  [ -n "$(pane_sub)" ] || {
    echo "期望写入 @whistle_sub，实际为空" >&2
    return 1
  }

  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"派了两个后台 agent"}
EOF
  # 标记还在：活动通道由推导层撑成 running。
  # 有效态仍是 done（rank 3 > running 2）—— Stop 的通知照写，这是老规矩。
  assert_eq "$(pane_eff)" 'done'
  assert_eq "$(opt '@whistle_count_running')" '1'

  feed <<'EOF'
{"hook_event_name":"SubagentStop"}
EOF
  assert_eq "$(pane_sub)" ''
  # 关键断言：标记清掉后不能还自称 running。
  # 修复前 @whistle 里烤着 Stop 时那份 running（用户读掉 ◆ 之后就是一盏
  # 永不熄灭的 ▶，实测亮了 33 分钟）。
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(opt '@whistle_count_running')" '0'
}

@test "e2e: SubagentStop 不清通知通道" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"要批准"}
EOF
  assert_eq "$(pane_notice)" 'wait'

  feed <<'EOF'
{"hook_event_name":"SubagentStop"}
EOF
  assert_eq "$(pane_notice)" 'wait'
}

# -- Notification ----------------------------------------------------------

@test "e2e: permission_prompt → 通知 wait（等待下一步）" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt",
 "message":"Claude needs your permission","title":"Permission needed"}
EOF
  assert_eq "$(pane_notice)" 'wait'
  assert_eq "$(pane_notice_msg)" 'Claude needs your permission'
}

@test "e2e: agent_needs_input → 通知 wait" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"teammate 在问你"}
EOF
  assert_eq "$(pane_notice)" 'wait'
}

@test "e2e: agent_completed → 通知 done" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_completed","message":"后台任务完成"}
EOF
  assert_eq "$(pane_notice)" 'done'
}

@test "e2e: 无关的通知类型被忽略，不污染两条通道" {
  for t in auth_success elicitation_complete quota_auto_resume_fired plugin_notification; do
    feed <<EOF
{"hook_event_name":"Notification","notification_type":"$t","message":"噪音"}
EOF
    assert_eq "$(pane_notice)" ''
    assert_eq "$(pane_act)" ''
  done
}

@test "e2e: 通知类型缺失时不写任何状态" {
  feed <<'EOF'
{"hook_event_name":"Notification","message":"没有类型的通知"}
EOF
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_act)" ''
}

# -- UserPromptSubmit ------------------------------------------------------

@test "e2e: UserPromptSubmit → 活动 running + 通知被清空" {
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$(pane_notice)" 'done'

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"继续"}
EOF
  assert_eq "$(pane_act)" 'running'
  # 上一轮的通知在这个 pane 里压掉：用户就在这儿输入，显然已经看过
  assert_eq "$(pane_notice)" ''
  assert_eq "$(pane_notice_msg)" ''
}

@test "e2e: 下一轮对话开始时通知正文也被清掉，不留上一轮的残值" {
  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1",
 "last_assistant_message":"做完了\n细节一\n细节二"}
EOF
  assert_contains "$(pane_notice_body)" '细节二'

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"再来一轮"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice_body)" ''
}

# 后台任务完成时，Claude Code 把 `<task-notification>` 包在 `<system-reminder>`
# 里当 user 角色消息喂回会话 —— 于是 hook 也会收到一次 UserPromptSubmit。
# 那不是真人输入：活动态照旧点亮，但**不能**拿它当「已读」，
# 否则用户还没看过的那条通知会被悄悄抹掉。

@test "e2e: 后台任务完成叫醒的那一轮（task-notification）不算已读" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"agent_completed","message":"后台任务完成"}
EOF
  assert_eq "$(pane_notice)" 'done'

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit",
 "prompt":"<system-reminder>\n<task-notification>\n<task-id>t1</task-id>\n</task-notification>\n</system-reminder>"}
EOF
  # agent 确实在处理这条通知 —— 活动态点亮
  assert_eq "$(pane_act)" 'running'
  # 但那条没人看过的通知留着
  assert_eq "$(pane_notice)" 'done'

  # 真人敲一句，才算看过
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"继续"}
EOF
  assert_eq "$(pane_notice)" ''
}

@test "e2e: UserPromptSubmit 把 idle 顶成 running" {
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  assert_eq "$(pane_act)" 'idle'

  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"开工"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(opt '@whistle_count_idle')" '0'
}

# -- SessionStart ----------------------------------------------------------

@test "e2e: SessionStart(startup) 报 idle，不点亮 running" {
  # agent 起来了但还停在提示符前等着 —— 这是「空闲」，不是「在干活」。
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(opt '@whistle_count_idle')" '1'
  assert_eq "$(opt '@whistle_count_running')" '0'
  # idle 不算待处理：⚑ 不亮
  assert_eq "$(opt '@whistle_pending')" '0'
}

@test "e2e: SessionStart(resume) 报 idle —— resurrect 恢复 agent 不再误报 running" {
  # 这就是 @resurrect-processes + @continuum-restore 的现场：tmux server 起来，
  # 三个 claude --continue 各自发 SessionStart(source=resume)。
  # 早先这里映射成 running，于是状态栏亮 ▶3，而一个都没在跑。
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"resume"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(win_state)" 'idle'
}

@test "e2e: SessionStart 把残留的 running 换成 idle（上一个 agent 被 SIGKILL）" {
  # 被 SIGKILL / 崩溃的 agent 不会发 SessionEnd，▶ 就永远灭不掉。
  # 新进程起来了 ⇒ 旧的没了，这时换成 idle 是安全的。
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  assert_eq "$(pane_act)" 'idle'
  assert_eq "$(win_state)" 'idle'
}

@test "e2e: SessionStart 清掉残留的子 agent 标记" {
  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF
  [ -n "$(pane_sub)" ]

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  assert_eq "$(pane_sub)" ''
}

@test "e2e: SessionStart 不顶掉待处理通知（done 留着等你处理）" {
  # 活动通道写 idle 不能把上一轮还没读的 ◆ 当成已读抹掉 ——
  # 守卫在 core 的写入点里，不在 hook 里。
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_act)" 'idle'

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"resume"}
EOF
  assert_eq "$(pane_notice)" 'done'
  assert_eq "$(pane_act)" 'idle'
}

@test "e2e: idle 也顶不掉 wait（等待授权中被恢复）" {
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"要批准"}
EOF
  assert_eq "$(pane_notice)" 'wait'

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"resume"}
EOF
  assert_eq "$(pane_notice)" 'wait'
}

@test "e2e: SessionStart(source=compact) 两条通道都不动" {
  # compact 发生在轮中，agent 确实还在干活。写 idle 会把正在转的 ▶ 掐掉；
  # 通知通道同样不该被这次压缩动到。
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit"}
EOF
  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"要批准"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'wait'

  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"compact"}
EOF
  assert_eq "$(pane_act)" 'running'
  assert_eq "$(pane_notice)" 'wait'
}

# -- SessionEnd ------------------------------------------------------------
#
# SessionEnd 是「临时」状态（running / idle）的"灭灯"信号：agent 退出了，
# 窗口不该继续亮 ▶ 或 ◉。
#
# ⚠️ 活动通道不是**清空**，而是收成 gone：钩子跑的时候 agent 进程还没退出，
# pane_current_command 仍是 claude —— 清空的话紧接着的重算会按「前台跑着
# agent」把它又认成空闲，留下一盏灭不掉的 ◉。

@test "e2e: SessionEnd 把 running 收成 gone（agent 走了）" {
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit"}
EOF
  assert_eq "$(pane_act)" 'running'

  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
EOF
  assert_eq "$(pane_act)" 'gone'
  # gone 不参与任何显示：徽章空、计数不涨
  assert_eq "$(win_state)" ''
  assert_eq "$(opt '@whistle_count_running')" '0'
  assert_eq "$(opt '@whistle_count_idle')" '0'
}

@test "e2e: SessionEnd 也收掉 idle（agent 走了就不该再显示空闲）" {
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  assert_eq "$(pane_act)" 'idle'

  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
EOF
  assert_eq "$(pane_act)" 'gone'
  assert_eq "$(opt '@whistle_count_idle')" '0'
  assert_eq "$(win_state)" ''
}

@test "e2e: SessionEnd 不动通知通道（done 留着等你处理）" {
  # agent 退出不代表你已经看过，那些 done 要留到你处理。
  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了\n细节一"}
EOF
  assert_eq "$(pane_notice)" 'done'

  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
EOF
  assert_eq "$(pane_act)" 'gone'
  assert_eq "$(pane_notice)" 'done'
  assert_contains "$(pane_notice_body)" '细节一'
  assert_eq "$(opt '@whistle_pending')" '1'
}

@test "e2e: SessionEnd 清掉子 agent 标记" {
  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF
  [ -n "$(pane_sub)" ]

  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other"}
EOF
  assert_eq "$(pane_sub)" ''
}

@test "e2e: SessionEnd 重复触发是幂等的" {
  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other"}
EOF
  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"other"}
EOF
  assert_eq "$(pane_act)" 'gone'
}

# -- 边界 ------------------------------------------------------------------

@test "e2e: 未知事件静默退出" {
  # PostToolUse 我们不订阅，也不处理。
  feed <<'EOF'
{"hook_event_name":"PostToolUse","tool_name":"Bash"}
EOF
  assert_eq "$(pane_act)" ''
  assert_eq "$(pane_notice)" ''
}

@test "e2e: 空 stdin 不报错也不写状态" {
  feed < /dev/null
  assert_eq "$(pane_act)" ''
  assert_eq "$(pane_notice)" ''
}

@test "e2e: 畸形 JSON 不崩、不写状态" {
  feed <<'EOF'
{not valid json at all
EOF
  assert_eq "$(pane_act)" ''
  assert_eq "$(pane_notice)" ''
}

@test "e2e: 不在 tmux 内时静默退出（没有 pane 可标记）" {
  run env -u TMUX_PANE -u WHISTLE_TMUX_SOCKET -u TMUX_SOCKET "$HOOK" <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF
  assert_eq "$status" 0
  assert_eq "$output" ''
}

@test "e2e: Stop 桌面通知携带来源 pane 的精确点击回调" {
  wt set -g @whistle_os on
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/terminal-notifier" << 'EOF'
#!/bin/sh
{
  printf 'call\n'
  printf '%s\n' "$@"
} >> "$WHISTLE_TEST_TN_ARGS"
EOF
  chmod +x "$fake_bin/terminal-notifier"
  export WHISTLE_TEST_TN_ARGS="$BATS_TEST_TMPDIR/tn.args"
  PATH="$fake_bin:$PATH"
  export PATH

  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"桌面通知跳转"}
EOF

  local args
  args=$(cat "$WHISTLE_TEST_TN_ARGS")
  assert_contains "$args" "tmux-whistle:$WHISTLE_TMUX_SOCKET:$TMUX_PANE"
  assert_contains "$args" '-execute'
  assert_contains "$args" '--desktop-jump'
  assert_contains "$args" "$TMUX_PANE"
}

# -- JSON 解析降级 ---------------------------------------------------------

@test "e2e: 无 jq 时 sed 启发式也能取出字段" {
  # 造一个只含 sh 工具的 PATH，强制走 sed 分支
  local shdir="$BATS_TEST_TMPDIR/shonly"
  mkdir -p "$shdir"
  for t in sh cat sed head printf tmux date grep tr cut wc basename dirname; do
    ln -sf "$(command -v "$t")" "$shdir/$t" 2> /dev/null || true
  done

  run env PATH="$shdir" TMUX_PANE="$TMUX_PANE" WHISTLE_TMUX_SOCKET="$WHISTLE_TMUX_SOCKET" \
    "$HOOK" <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"需要你批准"}
EOF
  assert_eq "$status" 0
  assert_eq "$(pane_notice)" 'wait'
  assert_eq "$(pane_notice_msg)" '需要你批准'
}

# -- 事件追踪日志 -----------------------------------------------------------
#
# 插件原本一行日志都没有 —— hook 收到什么事件、写了什么状态，全靠猜。
# @whistle_debug on 时每个收到的 hook 事件都追加一行到日志文件。
#
# 日志路径用 WHISTLE_HOOK_LOG 覆盖（不写进用户真实的 TMPDIR）。

setup_hook_log() {
  HOOK_LOG="$BATS_TEST_TMPDIR/hooks.log"
  rm -f "$HOOK_LOG"
  export WHISTLE_HOOK_LOG="$HOOK_LOG"
}

@test "e2e: debug on 时每个事件都记一行，含事件名与关键字段" {
  setup_hook_log
  wt set -g @whistle_debug on

  feed <<'EOF'
{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp",
 "last_assistant_message":"重构完成：抽出了 core.sh"}
EOF

  local log
  log=$(cat "$HOOK_LOG")
  assert_contains "$log" 'hook_event_name=Stop'
  assert_contains "$log" 'last_assistant_message=重构完成：抽出了 core.sh'
  # 时间戳与 pane 也要在
  assert_contains "$log" 'TMUX_PANE='
  assert_contains "$log" "$TMUX_PANE"
}

@test "e2e: debug on 时各类事件都记下自己的关键字段" {
  setup_hook_log
  wt set -g @whistle_debug on

  feed <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"要批准"}
EOF
  feed <<'EOF'
{"hook_event_name":"SessionStart","source":"startup"}
EOF
  feed <<'EOF'
{"hook_event_name":"UserPromptSubmit","prompt":"开工"}
EOF
  feed <<'EOF'
{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
EOF

  local log
  log=$(cat "$HOOK_LOG")
  assert_contains "$log" 'hook_event_name=Notification'
  assert_contains "$log" 'notification_type=permission_prompt'
  assert_contains "$log" 'hook_event_name=SessionStart'
  assert_contains "$log" 'source=startup'
  assert_contains "$log" 'hook_event_name=UserPromptSubmit'
  assert_contains "$log" 'prompt=开工'
  assert_contains "$log" 'hook_event_name=SessionEnd'
  assert_contains "$log" 'reason=prompt_input_exit'
}

@test "e2e: debug on 时 PreToolUse 也记下 tool_name" {
  setup_hook_log
  wt set -g @whistle_debug on

  feed <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Agent"}
EOF

  local log
  log=$(cat "$HOOK_LOG")
  assert_contains "$log" 'hook_event_name=PreToolUse'
  assert_contains "$log" 'tool_name=Agent'
}

@test "e2e: debug off（默认）时不写日志" {
  setup_hook_log
  # 不设 @whistle_debug —— 默认就是 off
  wt set -g @whistle_debug off

  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF

  assert_eq "$status" 0
  # ⚠️ 这里不能写成 `[ -f ... ] && { ...; return 1; }` 再跟一个裸 `return 0`：
  # ShellCheck 把 @test 体末尾的裸 `return` 当成**文件作用域**的 return，
  # 于是它后面所有 @test 都被标成「不可达」（SC2317）。
  # 写成 if 块，条件为假时最后一条命令的退出码就是 0，语义完全等价。
  if [ -f "$HOOK_LOG" ]; then
    echo "debug off 却写了日志文件"
    return 1
  fi
}

@test "e2e: 未知事件也会被记一行（收到但没处理的事件查得到）" {
  setup_hook_log
  wt set -g @whistle_debug on

  feed <<'EOF'
{"hook_event_name":"PostToolUse","tool_name":"Bash"}
EOF

  local log
  log=$(cat "$HOOK_LOG")
  assert_contains "$log" 'hook_event_name=PostToolUse'
  assert_contains "$log" 'tool_name=Bash'
  # 未知事件不写状态
  assert_eq "$(pane_act)" ''
}

@test "e2e: 日志只留首行且截断到 80 字符，不写完整 prompt" {
  setup_hook_log
  wt set -g @whistle_debug on

  local long
  long=$(printf 'x%.0s' $(seq 1 200))
  feed <<EOF
{"hook_event_name":"UserPromptSubmit","prompt":"首行内容\n第二行不该进日志$long"}
EOF

  local log
  log=$(cat "$HOOK_LOG")
  assert_contains "$log" 'prompt=首行内容'
  assert_not_contains "$log" '第二行不该进日志'
}

@test "e2e: 写日志不影响 hook 的 stdout —— stdout 恒为空" {
  # Claude Code 把 hook 的 stdout 当 JSON 解析，任何输出都会干扰它。
  setup_hook_log
  wt set -g @whistle_debug on

  feed <<'EOF'
{"hook_event_name":"Stop","last_assistant_message":"做完了"}
EOF

  assert_eq "$output" ''
  # 日志确实写进去了（stdout 空 ≠ 没写日志）
  assert_contains "$(cat "$HOOK_LOG")" 'hook_event_name=Stop'
}
