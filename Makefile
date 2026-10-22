SHELL := /bin/sh

BATS  ?= bats
SHFMT ?= shfmt
TMUX  ?= tmux

# shfmt 可能装在 ~/.local/bin（二进制直装）或 brew
export PATH := $(HOME)/.local/bin:$(PATH)

LIB_SH   := $(wildcard lib/*.sh)
HOOK_SH  := $(wildcard hooks/*.sh)
BIN_SH   := bin/tmux-whistle install.sh
POSIX_SH := $(LIB_SH) $(HOOK_SH) $(BIN_SH)

# 测试辅助脚本是 bash，交给 shfmt。
# .bats 不是合法 bash（@test "name" { ... } 是 bats 自有语法），shfmt 解析不了，
# 所以格式化与格式检查都排除它们 —— 这些文件靠 review 保证风格。
BASH_SH := $(shell find test -name '*.bash' 2>/dev/null)
BATS_SH := $(shell find test -name '*.bats' 2>/dev/null)

SHFMT_FLAGS := -i 2 -bn -sr

.PHONY: help deps deps-shfmt lint fmt fmt-check check test test-unit test-integration \
        install uninstall doctor clean

help: ## 显示所有可用命令
	@printf 'tmux-whistle 开发命令\n\n'
	@grep -hE '^[a-z][a-zA-Z-]*:.*?##' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@printf '\n用法：改代码 → make fmt → make check → 提交\n'

## -- 依赖 ------------------------------------------------------------------

deps: ## 安装开发工具（bats-core / shellcheck / shfmt）
	@command -v $(BATS) >/dev/null 2>&1 || brew install bats-core
	@command -v shellcheck >/dev/null 2>&1 || brew install shellcheck
	@$(MAKE) --no-print-directory deps-shfmt

deps-shfmt: ## 只安装 shfmt（brew tap 不可用时回退到官方二进制直装）
	@command -v $(SHFMT) >/dev/null 2>&1 && exit 0; \
	brew install mvdan/sh/shfmt 2>/dev/null && exit 0; \
	echo 'brew tap 不可用，改用官方二进制'; \
	ver=$$(curl -sSL https://api.github.com/repos/mvdan/sh/releases/latest \
		| sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p' | head -1); \
	test -n "$$ver" || { echo '取不到最新版本号，手动指定：SHFMT_VER=v3.10.0 make deps-shfmt'; exit 1; }; \
	mkdir -p $(HOME)/.local/bin; \
	curl -sSL -o $(HOME)/.local/bin/$(SHFMT) \
		"https://github.com/mvdan/sh/releases/download/v$$ver/shfmt_v$$ver_darwin_$$(uname -m | sed 's/x86_64/amd64/')"; \
	chmod +x $(HOME)/.local/bin/$(SHFMT); \
	$(SHFMT) --version

## -- 质量 ------------------------------------------------------------------

lint: ## ShellCheck 静态检查
	@command -v shellcheck >/dev/null 2>&1 || { echo '缺 shellcheck，先跑 make deps'; exit 1; }
	shellcheck -x $(POSIX_SH)
	@for f in $(BASH_SH) $(BATS_SH); do shellcheck -x $$f || exit 1; done

fmt: ## shfmt 原地格式化（按方言分两次调用）
	@command -v $(SHFMT) >/dev/null 2>&1 || { echo '缺 shfmt，先跑 make deps'; exit 1; }
	$(SHFMT) -w $(SHFMT_FLAGS) -ln=posix $(POSIX_SH)
	$(SHFMT) -w $(SHFMT_FLAGS) -ln=bash $(BASH_SH)

fmt-check: ## 格式检查（有未格式化文件则非零退出）
	@command -v $(SHFMT) >/dev/null 2>&1 || { echo '缺 shfmt，先跑 make deps'; exit 1; }
	@out=$$($(SHFMT) -l $(SHFMT_FLAGS) -ln=posix $(POSIX_SH) $(BASH_SH)); \
	if [ -n "$$out" ]; then \
		echo '以下文件未格式化，跑 make fmt：'; echo "$$out"; exit 1; \
	fi

## -- 测试 ------------------------------------------------------------------

test: lint fmt-check test-unit test-integration ## 完整检查（同 check）

test-unit: ## L1 纯函数单测（不碰 tmux）
	@command -v $(BATS) >/dev/null 2>&1 || { echo '缺 bats，先跑 make deps'; exit 1; }
	$(BATS) --print-output-on-failure test/unit

test-integration: ## L2/L3 tmux 集成与端到端（隔离 socket）
	@command -v $(BATS) >/dev/null 2>&1 || { echo '缺 bats，先跑 make deps'; exit 1; }
	$(BATS) --print-output-on-failure test/integration test/e2e

check: lint fmt-check test-unit test-integration ## 提交前完整检查

## -- 安装与自检 ------------------------------------------------------------

install: ## 本地安装（符号链接 + tmux.conf.local marker 块）
	./install.sh

uninstall: ## 逆操作
	./install.sh --uninstall

doctor: ## 环境自检
	@if command -v tmux-whistle >/dev/null 2>&1; then tmux-whistle doctor; \
	else ./bin/tmux-whistle doctor; fi

clean: ## 清临时产物
	rm -rf .test-tmp