#!/bin/bash
# 在 macOS 上编译并运行集成验证工具。
# 复用 App 里同一份 Swift 源码，只是不带 SwiftUI/AVKit 的界面层。
#
# ★ pipefail 必须开：`swiftc ... | head -40` 这条管道的退出码默认取自 head，
#   编译失败会被静默吞掉，然后跑的是**上一次留下的旧二进制** ——
#   实测踩过这个坑：以为在验新代码，其实验的是半小时前的旧构建。
#   现在编译失败会直接退出，不会拿旧二进制冒充新结果。
set -eo pipefail
cd "$(dirname "$0")/../.."
SRC="YoukuTV/Sources/YoukuMTopClient.swift \
     YoukuTV/Sources/YoukuUpsClient.swift \
     YoukuTV/Sources/YoukuLoginClient.swift \
     YoukuTV/Sources/YoukuSSR.swift \
     YoukuTV/Sources/YoukuHomeClient.swift \
     YoukuTV/Sources/YoukuHistoryStore.swift \
     YoukuTV/Sources/YoukuWebClient.swift \
     YoukuTV/Sources/YoukuEpisodeClient.swift \
     YoukuTV/Sources/MTopQuery.swift \
     tools/集成验证/main.swift"
mkdir -p build
echo "▸ 编译验证工具 …"
xcrun swiftc -O $SRC -o build/youku-verify 2>&1 | tee build/verify_build.log
echo "▸ 编译完成，开始验证"
echo ""
./build/youku-verify
