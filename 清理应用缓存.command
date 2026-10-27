#!/bin/bash
# 清理大厂的本地缓存（腾讯文档 / 飞书 / 豆包 / WPS）
#
# 只删除这些应用「重新登录后会自动重建」的缓存目录。
# 云端已同步的文件不受影响。
#
# ⚠️ 如果你在这几个 App 里有【只存在本地、尚未同步】的草稿或未上传文件，
#    请先手动确认，或直接按 Ctrl+C 退出。

set -u

echo "=========================================="
echo "  清理大厂应用缓存（约 8-12GB）"
echo "=========================================="
echo ""

# 待清理的缓存子目录（相对 App Support / Containers 的路径）
TARGETS=(
  "$HOME/Library/Application Support/TDAppDesktop/office_cache"
  "$HOME/Library/Application Support/TDAppDesktop/LocalCache"
  "$HOME/Library/Application Support/TDAppDesktop/Cache"
  "$HOME/Library/Application Support/TDAppDesktop/logs"
  "$HOME/Library/Application Support/LarkShell/cache"
  "$HOME/Library/Application Support/LarkShell/Cache"
  "$HOME/Library/Application Support/LarkShell/logs"
  "$HOME/Library/Application Support/Doubao/Cache"
  "$HOME/Library/Application Support/Doubao/cache"
  "$HOME/Library/Containers/com.kingsoft.wpsoffice.mac/Data/Library/Caches"
  "$HOME/Library/Containers/com.kingsoft.wpsoffice.mac/Data/Library/Application Support/Kingsoft/office6/cache"
  "$HOME/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches"
  "$HOME/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/Cache"
)

total=0
found=0
echo "将清理以下目录："
for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
        sz=$(du -sh "$t" 2>/dev/null | cut -f1)
        printf "  %-10s %s\n" "$sz" "$(echo "$t" | sed "s|$HOME|~|")"
        found=$((found+1))
    fi
done

if [ "$found" -eq 0 ]; then
    echo ""
    echo "没有找到可清理的目录（可能已经清过了）。"
    exit 0
fi

echo ""
echo "共 $found 项。清理的都是可重建缓存。"
echo ""
read -r -p "确认清理？(输入 y 继续) " ans
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    echo "已取消。"
    exit 0
fi

echo ""
echo "清理中..."
for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
        rm -rf "${t:?}"/* 2>/dev/null
    fi
done

echo ""
echo "【清理后】可用空间："
df -h /System/Volumes/Data | tail -1
echo ""
echo "完成。首次打开这些 App 可能会稍慢（需重建缓存），登录状态不受影响。"
echo ""
echo "提示：微信聊天记录/视频占 26GB，需在微信 App 内"
echo "      设置 → 通用 → 存储空间 里手动清理。"
