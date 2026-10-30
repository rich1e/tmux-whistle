#!/bin/sh
# 校验 CLI 内嵌版本常量与实际 --version 输出是否满足发布格式。

_cv_cli="${1:-bin/tmux-whistle}"

_cv_error() {
  printf '版本校验失败: %s\n' "$*" >&2
}

[ -f "$_cv_cli" ] || {
  _cv_error "找不到 CLI [$_cv_cli]"
  exit 1
}

# 只接受恰好一个单引号赋值；双引号、重复或缺失都不能静默通过。
_cv_read_const() {
  _cv_name="$1"
  _cv_all=$(awk -v name="$_cv_name" '
    $0 ~ "^[[:space:]]*((export|readonly)[[:space:]]+)?" name "[[:space:]]*=" { count++ }
    END { print count + 0 }
  ' "$_cv_cli")
  _cv_valid=$(grep -c "^$_cv_name='[^']*'$" "$_cv_cli" 2> /dev/null) || _cv_valid=0
  [ "$_cv_all" = 1 ] && [ "$_cv_valid" = 1 ] || return 1
  sed -n "s/^$_cv_name='\\([^']*\\)'$/\\1/p" "$_cv_cli"
}

_cv_base=$(_cv_read_const WHISTLE_VERSION) || {
  _cv_error 'WHISTLE_VERSION 必须且仅能有一个单引号赋值'
  exit 1
}
_cv_date=$(_cv_read_const WHISTLE_BUILD_DATE) || {
  _cv_error 'WHISTLE_BUILD_DATE 必须且仅能有一个单引号赋值'
  exit 1
}
_cv_number=$(_cv_read_const WHISTLE_BUILD_NUMBER) || {
  _cv_error 'WHISTLE_BUILD_NUMBER 必须且仅能有一个单引号赋值'
  exit 1
}

if ! printf '%s' "$_cv_base" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta)\.[1-9][0-9]*)?$'; then
  _cv_error "SemVer 或阶段格式非法 [$_cv_base]"
  exit 1
fi
if ! printf '%s' "$_cv_date" | grep -Eq '^[0-9]{8}$'; then
  _cv_error "构建日期必须是 YYYYMMDD [$_cv_date]"
  exit 1
fi
if ! printf '%s' "$_cv_number" | grep -Eq '^[1-9][0-9]*$'; then
  _cv_error "构建流水号必须是正整数 [$_cv_number]"
  exit 1
fi

_cv_expected_base="tmux-whistle ${_cv_base}+${_cv_date}.${_cv_number}"
# 哨兵保留末尾换行，并把 CLI 的真实退出码一并带出命令替换。
_cv_actual=$(
  "$_cv_cli" --version 2>&1
  _cv_rc=$?
  printf '\037%s' "$_cv_rc"
  exit "$_cv_rc"
)
_cv_rc=$?
[ "$_cv_rc" -eq 0 ] || {
  _cv_error "--version 执行失败（退出码 $_cv_rc）"
  exit 1
}
_cv_expected=$(printf '%s\n\0370' "$_cv_expected_base")
[ "$_cv_actual" = "$_cv_expected" ] || {
  _cv_error "输出与常量不一致（含换行差异）：期望 [$_cv_expected_base]"
  exit 1
}

printf '版本校验通过: %s\n' "$_cv_expected_base"
