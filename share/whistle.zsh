# tmux-whistle 可选的 OSC 133 片段（zsh）。
#
# 作用：让 tmux 知道"一条命令跑完了"，从而触发 pane-command-finished hook，
# 做到**免轮询**的命令级检测。
#
# 完全不 source 它也丝毫不影响 tmux-whistle 的主要功能
# （hooks 推送 + 徽章 + 四渠道投递）。
#
# 用法：在 ~/.zshrc 里加
#   source ~/.config/tmux/plugins/tmux-whistle/share/whistle.zsh
#
# 注意：pane-command-finished 需要 tmux >= 3.4。
# 更老的版本请改用 @whistle-detect（关键词兜底）。

# 已装过其它 shell integration 的不要重复发 —— OSC 133 重复会打乱 tmux 的状态机
if [[ -z ${__whistle_osc133_installed:-} ]]; then
  __whistle_osc133_installed=1

  autoload -Uz add-zsh-hook

  typeset -g __whistle_last_status=0
  typeset -g __whistle_have_running=0

  # 必须先注册：precmd 钩子按注册顺序执行，$? 只有第一个能看到上条命令的退出码
  __whistle_osc133_capture_status() {
    __whistle_last_status=$?
  }
  add-zsh-hook precmd __whistle_osc133_capture_status

  __whistle_osc133_precmd() {
    # D = 上一条命令结束（带退出码），A = 提示符开始
    if (( __whistle_have_running )); then
      printf '\e]133;D;%s\a' "$__whistle_last_status"
      __whistle_have_running=0
    fi
    printf '\e]133;A\a'
  }

  __whistle_osc133_preexec() {
    printf '\e]133;C\a'
    __whistle_have_running=1
  }

  __whistle_osc133_chpwd() {
    printf '\e]133;P;k=cwd;cwd=%s\a' "$PWD"
  }

  add-zsh-hook precmd __whistle_osc133_precmd
  add-zsh-hook preexec __whistle_osc133_preexec
  add-zsh-hook chpwd __whistle_osc133_chpwd
fi