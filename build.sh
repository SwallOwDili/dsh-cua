#!/bin/bash
# 构建 dsh-cua 的原生 MCP 服务器。
#
# 只依赖系统自带的 Swift 工具链（Xcode Command Line Tools），不需要额外 SDK。
# 输出：bin/cua-mcp、bin/cua-overlay、bin/cua-live

set -euo pipefail
cd "$(dirname "$0")"

SRC="src/main.swift"
OUT="bin/cua-mcp"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误: 找不到 swiftc。安装 Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p bin

ARCH=$(uname -m)
echo "构建目标架构: $ARCH"

# -O 足够；不需要 -whole-module-optimization（单文件）。
# 通用二进制：package.json 声明了 arm64 + x64，就必须真的编出两片，
# 否则 Intel 机器装上即坏。Swift 6.1 的 swiftc 不认 -arch，
# 用双 -target 各编一次再 lipo 合并。最低系统 14.0（ScreenCaptureKit 要求 14.0+）。
build_universal() {
  local out="$1"; shift
  # 不做 2>/dev/null：编译错误必须打出来并中断。
  # 静默吞错会让脚本继续跑「上一次成功编译的旧二进制」自检并输出 PASS，
  # 造成「改了没生效但验证通过」的假象（2026-10-27 踩过）。
  rm -f "$out.arm64" "$out.x64"
  swiftc -O -target arm64-apple-macosx14.0 -o "$out.arm64" "$@" || return 1
  swiftc -O -target x86_64-apple-macosx14.0 -o "$out.x64"  "$@" || return 1
  lipo -create "$out.arm64" "$out.x64" -output "$out" || return 1
  rm -f "$out.arm64" "$out.x64"
  [ -x "$out" ] || return 1
}

build_universal "$OUT" "$SRC" || { echo "编译失败: $SRC" >&2; exit 1; }

# overlay：被操作窗口左上角的标记进程
LIVE_OUT="bin/cua-live"
OVERLAY_OUT="bin/cua-overlay"
build_universal "$OVERLAY_OUT" overlay/main.swift || { echo "编译失败: overlay" >&2; exit 1; }
build_universal "$LIVE_OUT" live/main.swift || { echo "编译失败: live" >&2; exit 1; }

echo "已生成 $OUT"
echo "--- 自检 ---"
"./$OUT" --selftest

# pnpm 对 file: 依赖按 mtime/lockfile 判定，update 可能跳过复制，
# 导致 profile 里留下旧二进制。这里直接覆盖已安装副本，保证确定性。
# 同步目标 profile：优先 $DSH_PROFILE，否则挑 ~/.dsh/profiles 下
# node_modules 里已装有 dsh-cua 的那个。多 profile 机器可用
# DSH_PROFILE=xxx ./build.sh 指定。
if [ -n "${DSH_PROFILE:-}" ]; then
  INSTALLED_DIR="$HOME/.dsh/profiles/$DSH_PROFILE/node_modules/dsh-cua"
else
  INSTALLED_DIR=""
  for d in "$HOME"/.dsh/profiles/*/node_modules/dsh-cua; do
    if [ -d "$d" ]; then INSTALLED_DIR="$d"; break; fi
  done
fi
if [ -d "$INSTALLED_DIR" ]; then
  install -m 755 "$OUT" "$INSTALLED_DIR/bin/cua-mcp"
  install -m 755 "$OVERLAY_OUT" "$INSTALLED_DIR/bin/cua-overlay"
  install -m 755 "$LIVE_OUT" "$INSTALLED_DIR/bin/cua-live"
  # package.json 常是硬链接，install 会因 "same file" 失败；cmp 相同就跳过。
  for f in cordis.patch.yml package.json index.js client.js mcp-bridge.js README.md; do
    if ! cmp -s "$f" "$INSTALLED_DIR/$f" 2>/dev/null; then
      cp -f "$f" "$INSTALLED_DIR/$f" 2>/dev/null || true
    fi
  done
  echo "已同步到 profile: $INSTALLED_DIR"
else
  echo "未检测到已安装副本（首次安装请执行 dsh plugin --profile web add file:$PWD）"
fi
