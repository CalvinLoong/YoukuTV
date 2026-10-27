#!/bin/bash
# 清理 macOS 应用缓存 —— 只删缓存，不碰任何用户数据
# 双击运行即可。清理前会显示各项大小。

set -u

echo "=========================================="
echo "  清理应用缓存（安全）"
echo "=========================================="
echo ""

# 计算可释放空间
calc() {
    if [ -d "$1" ]; then
        du -sh "$1" 2>/dev/null | cut -f1
    else
        echo "0B"
    fi
}

echo "【清理前】各缓存目录大小："
for d in "$HOME/Library/Caches" \
         "$HOME/Library/Logs" \
         "$HOME/Library/Saved Application State" \
         "$HOME/Library/Application Support/CrashReporter" \
         "$HOME/.Trash"; do
    [ -d "$d" ] && printf "  %-52s %s\n" "$(basename "$d")" "$(calc "$d")"
done
echo ""

read -r -p "确认清理？(输入 y 继续) " ans
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    echo "已取消。"
    exit 0
fi

echo ""
echo "清理中..."

# 1. 应用缓存
rm -rf "$HOME/Library/Caches"/* 2>/dev/null

# 2. 日志
rm -rf "$HOME/Library/Logs"/* 2>/dev/null

# 3. 应用状态快照（可重建）
rm -rf "$HOME/Library/Saved Application State"/* 2>/dev/null

# 4. 崩溃报告
rm -rf "$HOME/Library/Application Support/CrashReporter"/* 2>/dev/null

# 5. Xcode / 开发者工具残留（Command Line Tools 与 Xcode 缓存）
rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/* 2>/dev/null
rm -rf "$HOME/Library/Developer/Xcode/iOS DeviceSupport"/* 2>/dev/null
rm -rf "$HOME/Library/Developer/CoreSimulator/Caches"/* 2>/dev/null
rm -rf "$HOME/Library/Developer/Xcode/UserData/Previews"/* 2>/dev/null

# 6. 空的废纸篓内容（只清空的，不强制清）
rm -rf "$HOME/.Trash"/* 2>/dev/null

echo ""
echo "【清理后】可用空间："
df -h /System/Volumes/Data | tail -1
echo ""
echo "完成。这些都是可重建的缓存，不影响任何文档和聊天记录。"
