#!/usr/bin/env bats
# shellcheck shell=bash
# 版本输出、SemVer 校验与无依赖 fast-path。

load '../test_helper/whistle'
bats_require_minimum_version 1.5.0

setup() {
  CLI="$WHISTLE_ROOT/bin/tmux-whistle"
  CHECK_VERSION="$WHISTLE_ROOT/scripts/check-version.sh"
  VERSION_BASE=$(sed -n "s/^WHISTLE_VERSION='\\([^']*\\)'$/\\1/p" "$CLI")
  VERSION_DATE=$(sed -n "s/^WHISTLE_BUILD_DATE='\\([^']*\\)'$/\\1/p" "$CLI")
  VERSION_NUMBER=$(sed -n "s/^WHISTLE_BUILD_NUMBER='\\([^']*\\)'$/\\1/p" "$CLI")
  EXPECTED_VERSION="tmux-whistle ${VERSION_BASE}+${VERSION_DATE}.${VERSION_NUMBER}"
}

make_version_cli() {
  local name="$1" base="$2" build_date="$3" build_number="$4"
  TEST_CLI="$BATS_TEST_TMPDIR/$name"
  sed \
    -e "s/^WHISTLE_VERSION=.*/WHISTLE_VERSION='$base'/" \
    -e "s/^WHISTLE_BUILD_DATE=.*/WHISTLE_BUILD_DATE='$build_date'/" \
    -e "s/^WHISTLE_BUILD_NUMBER=.*/WHISTLE_BUILD_NUMBER='$build_number'/" \
    "$CLI" > "$TEST_CLI"
  chmod +x "$TEST_CLI"
}

@test "version: --version 与 version 输出同一个完整版本" {
  run --separate-stderr "$CLI" --version
  assert_eq "$status" 0
  assert_eq "$stderr" ''
  assert_eq "$output" "$EXPECTED_VERSION"

  run "$CLI" version
  assert_eq "$status" 0
  assert_eq "$output" "$EXPECTED_VERSION"
}

@test "version: 环境变量不能覆盖源码声明" {
  run env WHISTLE_VERSION=9.9.9 WHISTLE_BUILD_DATE=19990101 WHISTLE_BUILD_NUMBER=99 \
    "$CLI" --version
  assert_eq "$status" 0
  assert_eq "$output" "$EXPECTED_VERSION"
}

@test "version: 孤立 CLI 无 lib 且 PATH 不存在也能查询" {
  cp "$CLI" "$BATS_TEST_TMPDIR/standalone"
  chmod +x "$BATS_TEST_TMPDIR/standalone"

  run env PATH="$BATS_TEST_TMPDIR/no-such-dir" "$BATS_TEST_TMPDIR/standalone" --version

  assert_eq "$status" 0
  assert_eq "$output" "$EXPECTED_VERSION"
}

@test "version: 孤立 CLI 经符号链接查询不触发路径解析" {
  cp "$CLI" "$BATS_TEST_TMPDIR/standalone"
  chmod +x "$BATS_TEST_TMPDIR/standalone"
  ln -s "$BATS_TEST_TMPDIR/standalone" "$BATS_TEST_TMPDIR/version-link"

  run env PATH="$BATS_TEST_TMPDIR/no-such-dir" "$BATS_TEST_TMPDIR/version-link" --version

  assert_eq "$status" 0
  assert_eq "$output" "$EXPECTED_VERSION"
}

@test "version: 不调用运行时 date" {
  mkdir -p "$BATS_TEST_TMPDIR/date-bin"
  cat > "$BATS_TEST_TMPDIR/date-bin/date" << EOF
#!/bin/sh
printf called > "$BATS_TEST_TMPDIR/date-called"
exit 99
EOF
  chmod +x "$BATS_TEST_TMPDIR/date-bin/date"

  run env PATH="$BATS_TEST_TMPDIR/date-bin" "$CLI" --version

  assert_eq "$status" 0
  assert_eq "$output" "$EXPECTED_VERSION"
  [ ! -e "$BATS_TEST_TMPDIR/date-called" ]
}

@test "version: 额外参数在加载 lib 前报错" {
  cp "$CLI" "$BATS_TEST_TMPDIR/standalone"
  chmod +x "$BATS_TEST_TMPDIR/standalone"

  run env PATH="$BATS_TEST_TMPDIR/no-such-dir" \
    "$BATS_TEST_TMPDIR/standalone" --version extra

  assert_eq "$status" 1
  assert_not_contains "$output" '缺少 lib/'
  assert_contains "$output" '用法'
}

@test "version: help 复用 canonical 版本并列出版本命令" {
  run "$CLI" --help
  assert_eq "$status" 0
  assert_contains "$output" "$EXPECTED_VERSION"
  assert_contains "$output" '--version'
}

@test "check-version: 当前源码与 make 入口合法" {
  run "$CHECK_VERSION" "$CLI"
  assert_eq "$status" 0

  run make -s -C "$WHISTLE_ROOT" check-version
  assert_eq "$status" 0

  run make -s -C "$WHISTLE_ROOT" version
  assert_eq "$status" 0
  assert_eq "$output" "$EXPECTED_VERSION"
}

@test "check-version: alpha beta 正式版与合法 build 都可校验" {
  while IFS='|' read -r base build_date build_number expected; do
    make_version_cli valid-cli "$base" "$build_date" "$build_number"
    run "$CHECK_VERSION" "$TEST_CLI"
    assert_eq "$status" 0
    run "$TEST_CLI" --version
    assert_eq "$status" 0
    assert_eq "$output" "$expected"
  done << EOF
0.1.0-alpha.1|20261030|1|tmux-whistle 0.1.0-alpha.1+20261030.1
0.2.0-beta.2|20261101|17|tmux-whistle 0.2.0-beta.2+20261101.17
1.0.0|20261231|203|tmux-whistle 1.0.0+20261231.203
0.0.0-alpha.10|20270102|4|tmux-whistle 0.0.0-alpha.10+20270102.4
EOF
}

@test "check-version: 非法 core stage 与 build 全部拒绝" {
  while IFS='|' read -r base build_date build_number; do
    make_version_cli invalid-cli "$base" "$build_date" "$build_number"
    run "$CHECK_VERSION" "$TEST_CLI"
    assert_eq "$status" 1
    assert_contains "$output" '版本'
  done << EOF
v0.1.0|20261030|1
0.1|20261030|1
01.0.0|20261030|1
0.01.0|20261030|1
0.1.00|20261030|1
0.1.0+20261030.1|20261030|1
0.1.0-alpha|20261030|1
0.1.0-alpha.0|20261030|1
0.1.0-alpha.01|20261030|1
0.1.0-beta.01|20261030|1
0.1.0-rc.1|20261030|1
0.1.0|2026103|1
0.1.0|2026A030|1
0.1.0||1
0.1.0|20261030|0
0.1.0|20261030|01
0.1.0|20261030|-1
0.1.0|20261030|1.5
0.1.0|20261030|
EOF
}

@test "check-version: 缺失重复或异常形式的常量赋值都拒绝" {
  make_version_cli missing-cli '0.1.0' '20261030' '1'
  sed "/^WHISTLE_VERSION='/d" "$TEST_CLI" > "$BATS_TEST_TMPDIR/missing"
  chmod +x "$BATS_TEST_TMPDIR/missing"
  run "$CHECK_VERSION" "$BATS_TEST_TMPDIR/missing"
  assert_eq "$status" 1

  make_version_cli duplicate-cli '0.1.0' '20261030' '1'
  printf "WHISTLE_VERSION='0.2.0'\n" >> "$TEST_CLI"
  run "$CHECK_VERSION" "$TEST_CLI"
  assert_eq "$status" 1

  make_version_cli quotes-cli '0.1.0' '20261030' '1'
  sed "s/^WHISTLE_VERSION=.*/WHISTLE_VERSION=\"0.1.0\"/" "$TEST_CLI" \
    > "$BATS_TEST_TMPDIR/quotes"
  chmod +x "$BATS_TEST_TMPDIR/quotes"
  run "$CHECK_VERSION" "$BATS_TEST_TMPDIR/quotes"
  assert_eq "$status" 1
}

@test "check-version: export 前导空白 readonly 的重复赋值也拒绝" {
  local name form value
  for name in WHISTLE_VERSION WHISTLE_BUILD_DATE WHISTLE_BUILD_NUMBER; do
    case "$name" in
    WHISTLE_VERSION) value='9.9.9' ;;
    WHISTLE_BUILD_DATE) value='19990101' ;;
    WHISTLE_BUILD_NUMBER) value='99' ;;
    esac
    for form in export leading readonly; do
      make_version_cli alternate-cli '0.1.0' '20261030' '1'
      case "$form" in
      export) printf "export %s='%s'\n" "$name" "$value" >> "$TEST_CLI" ;;
      leading) printf "  %s='%s'\n" "$name" "$value" >> "$TEST_CLI" ;;
      readonly) printf "readonly %s='%s'\n" "$name" "$value" >> "$TEST_CLI" ;;
      esac
      run "$CHECK_VERSION" "$TEST_CLI"
      assert_eq "$status" 1
    done
  done
}

@test "check-version: 额外尾部空行也不能通过" {
  make_version_cli blank-cli '0.1.0' '20261030' '1'
  awk -v q="'" '
    $0 == "  whistle_version" {
      print
      print "  printf " q "\\n" q
      next
    }
    { print }
  ' "$TEST_CLI" > "$BATS_TEST_TMPDIR/blank"
  chmod +x "$BATS_TEST_TMPDIR/blank"

  run "$CHECK_VERSION" "$BATS_TEST_TMPDIR/blank"

  assert_eq "$status" 1
}
