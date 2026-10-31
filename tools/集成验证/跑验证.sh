#!/bin/bash
# 在 macOS 上编译并运行集成验证工具。
# 复用 App 里同一份 Swift 源码，只是不带 SwiftUI/AVKit 的界面层。
set -e
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
xcrun swiftc -O $SRC -o build/youku-verify 2>&1 | head -40
./build/youku-verify
