#!/bin/bash
# GitHub 登录 + 自动创建公开仓库 + 推送代码
# 双击运行。过程中浏览器会弹出授权窗口，授权后自动完成剩余步骤。

set -u

DIR="/Users/calvin/WorkBuddy/2026-10-26-18-17-30"
GH="$DIR/tools/gh/gh_2.62.0_macOS_arm64/bin/gh"
REPO_NAME="YoukuTV"

echo "=========================================="
echo "  YoukuTV → GitHub 公开仓库"
echo "=========================================="
echo ""

# 1) 检查 gh
if [ ! -x "$GH" ]; then
    echo "✗ 找不到 gh 工具"
    exit 1
fi

# 2) 检查登录
if ! "$GH" auth status >/dev/null 2>&1; then
    echo "▸ 步骤 1/3：登录 GitHub"
    echo "  浏览器会弹出授权页面，勾选所有权限，点 Authorize。"
    echo ""
    "$GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key
    echo ""
fi

if ! "$GH" auth status >/dev/null 2>&1; then
    echo "✗ 登录未完成，请重新运行本脚本"
    exit 1
fi

USER=$("$GH" api user --jq '.login')
echo "✓ 已登录：$USER"

# 3) 建仓库（公开）
echo ""
echo "▸ 步骤 2/3：创建公开仓库 $REPO_NAME"
cd "$DIR" || exit 1

if "$GH" repo view "$USER/$REPO_NAME" >/dev/null 2>&1; then
    echo "  仓库已存在，跳过创建"
else
    "$GH" repo create "$REPO_NAME" \
        --public \
        --description "Apple TV (tvOS) client for Youku - reverse-engineered from CIBN TV client" \
        --source=. \
        --remote=origin \
        --push
fi

# 4) 确认推送
echo ""
echo "▸ 步骤 3/3：确认推送结果"
if "$GH" repo view "$USER/$REPO_NAME" >/dev/null 2>&1; then
    echo "✓ 仓库就绪：https://github.com/$USER/$REPO_NAME"
    echo ""
    echo "接下来："
    echo "  1. 打开上面的网址，点 Actions 标签"
    echo "  2. 左侧选 'Build tvOS IPA (unsigned)'"
    echo "  3. 右边点 Run workflow，等 10 分钟左右"
    echo "  4. 底部 Artifacts 下载 YoukuTV-tvos-ipa"
    echo ""
    read -r -p "按回车关闭..." _
else
    echo "✗ 仓库创建失败，请把上面的报错发给我"
    read -r -p "按回车关闭..." _
fi
