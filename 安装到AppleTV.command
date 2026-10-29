#!/bin/bash
# 把已编译好的 YoukuTV 安装包装进你的 Apple TV。
# 双击运行。全程免费，不需要 Xcode，不需要付费开发者账号。

set -u

DIR="/Users/calvin/WorkBuddy/2026-10-26-18-17-30"
GH="$DIR/tools/gh/gh_2.62.0_macOS_arm64/bin/gh"
IPA="$DIR/输出/YoukuTV-unsigned.ipa"
REPO="CalvinLoong/YoukuTV"
WORKFLOW="build-tvos-ipa.yml"

echo "=========================================="
echo "  YoukuTV → Apple TV 安装助手"
echo "=========================================="
echo ""

if [ ! -x "$GH" ]; then
  echo "✗ 找不到辅助工具（$GH）"
  exit 1
fi

# ---------------------------------------------------------------
# 第 1 步：如果本地还没有 ipa，就去 GitHub 下载最新一次构建
# ---------------------------------------------------------------
if [ ! -f "$IPA" ]; then
  echo "▸ 本地还没有安装包，正在从 GitHub 下载最新构建……"
  mkdir -p "$DIR/输出"

  if ! "$GH" auth status >/dev/null 2>&1; then
    echo "  首次使用需要登录 GitHub，浏览器会弹出授权页面，"
    echo "  勾选全部权限后点 Authorize。"
    "$GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key
  fi

  echo "  ▸ 触发一次云端编译（需要几分钟）……"
  "$GH" workflow run "$WORKFLOW" --repo "$REPO" --ref main
  if [ $? -ne 0 ]; then
    echo "  ✗ 触发失败，请到网页上手动运行："
    echo "    https://github.com/$REPO/actions"
    exit 1
  fi

  echo "  ▸ 等待编译完成（最多等 25 分钟）……"
  RUN_ID=""
  for i in $(seq 1 50); do
    sleep 30
    RUN_ID=$("$GH" api "repos/$REPO/actions/runs?per_page=1" --jq '.workflow_runs[0].id' 2>/dev/null)
    STATUS=$("$GH" api "repos/$REPO/actions/runs/$RUN_ID" --jq '.status' 2>/dev/null)
    DONE=$("$GH" api "repos/$REPO/actions/runs/$RUN_ID/jobs" --jq '[.jobs[]|select(.name=="Publish IPA artifact")|.conclusion][0] // ""' 2>/dev/null)
    echo "    [$((i*30))秒] 运行 $RUN_ID 状态=$STATUS  打包=$DONE"
    if [ "$DONE" = "success" ]; then break; fi
  done

  if [ "$DONE" != "success" ]; then
    echo "  ✗ 编译还没成功，可以到网页上看日志："
    echo "    https://github.com/$REPO/actions/runs/$RUN_ID"
    exit 1
  fi

  echo "  ▸ 下载安装包……"
  "$GH" run download "$RUN_ID" --repo "$REPO" -n "YoukuTV-tvos-ipa" -D "$DIR/输出" || {
    echo "  ✗ 下载失败，请到网页上手动下载 Artifacts 里的 YoukuTV-tvos-ipa"
    exit 1
  }
fi

echo ""
echo "✓ 安装包就位："
ls -lh "$IPA" | awk '{print "  " $5 "  " $9}'
echo ""

# ---------------------------------------------------------------
# 第 2 步：检查 Sideloadly 是否已安装
# ---------------------------------------------------------------
SIDELOADLY=""
for CAND in "/Applications/Sideloadly.app" "/Applications/Sideloadly.app/Contents/MacOS/Sideloadly" \
            "$HOME/Applications/Sideloadly.app" "/Applications/Sideloadly/Sideloadly.app"; do
  if [ -e "$CAND" ]; then SIDELOADLY="$CAND"; break; fi
done

if [ -z "$SIDELOADLY" ]; then
  echo "▸ 没检测到 Sideloadly，正在打开官网请下载安装……"
  open "https://sideloadly.io"
  echo ""
  echo "  下载安装完成后，重新双击本脚本即可。"
  echo ""
  echo "  安装包已经准备好了，安装完 Sideloadly 后再运行一次。"
  exit 0
fi

echo "✓ 已找到 Sideloadly：$SIDELOADLY"
echo ""

# ---------------------------------------------------------------
# 第 3 步：提示用户完成配对与侧载
# ---------------------------------------------------------------
echo "=========================================="
echo "  接下来请在 Sideloadly 里完成 3 步"
echo "=========================================="
echo ""
echo "① 配对 Apple TV"
echo "   Apple TV 和这台电脑连同一个 WiFi"
echo "   Apple TV → 设置 → 遥控器与设备 → 远程 App 与设备"
echo "   记下显示的 4 位配对码"
echo ""
echo "② 侧载"
echo "   Sideloadly 里点 + ，选这个文件："
echo "     $IPA"
echo "   设备列表里选你的 Apple TV"
echo "   填入你的免费 Apple ID 和密码，点 Start"
echo ""
echo "③ 信任开发者"
echo "   Apple TV → 设置 → 通用 → 隐私与安全性 → App 安装"
echo "   点你的 Apple ID → 信任"
echo ""
echo "✓ 装好后主屏幕上会出现 Youku TV 图标"
echo ""
echo "提示：免费 Apple ID 签名 7 天后失效。"
echo "      在 Sideloadly 的 Advanced Options 里勾上 Auto-Refresh 可自动续签。"
echo ""

if [ -n "$SIDELOADLY" ]; then
  echo "▸ 正在打开 Sideloadly 和安装包所在文件夹……"
  open "$SIDELOADLY" 2>/dev/null
  open "$DIR/输出" 2>/dev/null
fi

read -r -p "按回车键结束…" _
