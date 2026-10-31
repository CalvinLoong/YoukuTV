#!/usr/bin/env bash
# 跑凭据解析的 Swift 侧回归测试。
#
# 与 tools/凭据解析回归.py 跑同一批用例。
# 两边都过，才说明 App 里的解析逻辑和逆向确认的真实结构一致。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  "$ROOT/tools/登录联调/YoukuErrorShim.swift" \
  "$ROOT/YoukuTV/Sources/YoukuLoginClient.swift" \
  "$ROOT/tools/登录联调/测试/main.swift" \
  -o "$OUT/youku-cred-test"

"$OUT/youku-cred-test"

echo ""
echo "--- Python 侧对照 ---"
python3 "$ROOT/tools/凭据解析回归.py"
