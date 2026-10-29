#!/usr/bin/env bash
#
# 生成/更新 App 内置的 ups 凭据（ckey + utid + encryptR_client）。
#
# 背景：
#   优酷的 ups 播放接口需要一组「设备指纹」凭据。实测结论：
#     - ckey 与 utid 配套使用，缺一不可
#     - ckey **不绑定** vid → 一组凭据可播放任意视频
#     - ckey 有效期 > 2 天（实测 2 天前的仍可用）
#   但服务端会轮换，一旦失效 App 就取不到播放地址。
#
# 用法：
#   1. 运行本脚本 → 它会打开一个真实浏览器窗口
#   2. 浏览器里随便操作一下（让播放器开始播放），脚本自动抓取
#   3. 抓到的凭据会写回 YoukuTV/Sources/YoukuUpsClient.swift
#
# 依赖：agent-browser（已装在 ../tools/ab）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
AB_BIN="$ROOT/tools/ab/node_modules/.bin"
NODE_BIN="$ROOT/tools/node-v24.22.1-darwin-arm64/bin"
export PATH="$AB_BIN:$NODE_BIN:$PATH"

TARGET_SHOW="${1:-9bbc2c96790d11e4b522}"   # 三体预告片的 showId

if [ ! -x "$AB_BIN/agent-browser" ]; then
  echo "错误：找不到 agent-browser（$AB_BIN/agent-browser）"
  exit 1
fi

echo "▶ 打开优酷播放页，请等待播放器开始播放…"
agent-browser close >/dev/null 2>&1 || true
sleep 1
agent-browser open "https://list.youku.com/show/id_${TARGET_SHOW}.html" >/dev/null 2>&1

echo "▶ 等待 ups 请求…"
FOUND=""
for i in $(seq 1 24); do
  sleep 5
  OUT=$(agent-browser eval "
(function(){
  var es = performance.getEntriesByType('resource');
  var out = [];
  for (var i=0;i<es.length;i++){
    var n = es[i].name || '';
    if (n.indexOf('appinfo') !== -1) out.push(n);
  }
  return out.join('###');
})()
" 2>/dev/null | tr -d '"' | head -1)

  if [ -n "$OUT" ] && [ "$OUT" != "null" ]; then
    FOUND="$OUT"
    echo "  ✓ 抓到 ups 请求（第 $((i*5)) 秒）"
    break
  fi
  echo "  … 等待中 ($((i*5))s)"
done

if [ -z "$FOUND" ]; then
  echo "✗ 未抓到 ups 请求。请确认页面已开始播放（可能需要点一下播放按钮）。"
  agent-browser close >/dev/null 2>&1 || true
  exit 1
fi

echo "▶ 解析凭据…"
PAYLOAD=$(python3 "$ROOT/tools/提取凭据.py" "$FOUND")
CK=$(echo "$PAYLOAD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["ckey"])')
UT=$(echo "$PAYLOAD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["utid"])')
ER=$(echo "$PAYLOAD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["encryptR"])')

if [ -z "$CK" ] || [ -z "$UT" ]; then
  echo "✗ 解析失败（ckey 或 utid 为空）"
  exit 1
fi

echo "  ckey 长度: ${#CK}"
echo "  utid: $UT"

echo "▶ 写回源码…"
python3 "$ROOT/tools/写入凭据.py" "$ROOT/YoukuTV/Sources/YoukuUpsClient.swift" "$CK" "$UT" "$ER"

agent-browser close >/dev/null 2>&1 || true

echo ""
echo "✓ 完成。已更新 YoukuTV/Sources/YoukuUpsClient.swift"
echo "  现在提交并推送，GitHub Actions 会重新构建 ipa。"
