#!/usr/bin/env bash
# 编译 macOS 命令行版登录联调工具。
#
# 目的：在装机到 Apple TV 之前，用**完全相同的一份 Swift 源码**
#       跑通真实的扫码登录链路（14030 → 14031 → 3000）。
#       这样登录失败时能立刻区分是「协议错」还是「App UI 错」。
#
# 为什么能编译：YoukuLoginClient.swift 只依赖 Foundation + CryptoKit，
#             两个框架在 macOS 上都有，没有 tvOS 专属 API。
#
# 用法：bash tools/登录联调/编译.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  "$ROOT/tools/登录联调/YoukuErrorShim.swift" \
  "$ROOT/tools/登录联调/QRWriter.swift" \
  "$ROOT/YoukuTV/Sources/MTopQuery.swift" \
  "$ROOT/YoukuTV/Sources/YoukuLoginClient.swift" \
  "$ROOT/tools/登录联调/main.swift" \
  -o "$OUT/youku-login-probe"

echo "✓ 编译完成：$OUT/youku-login-probe"
