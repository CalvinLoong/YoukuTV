#!/usr/bin/env python3
"""本地编译预检：在推送前发现"语法检查过、但真机编译会失败"的问题。

背景：GitHub Actions 的免费 macOS runner 常常排队数小时，
不能把编译验证完全押在云端。这个脚本用本机的 macOS SDK 做一次
**真实编译**（swiftc -c），能在 30 秒内暴露真实编译错误。

原理：把 tvOS 专属的三处写法替换成 macOS 等价写法，
然后用 macOS SDK 编译。其余 95% 的代码与 tvOS 完全一致。

用法:
    python3 tools/本地编译检查.py
返回码: 0 = 编译通过, 1 = 有错误
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "YoukuTV", "Sources")

# tvOS 专属 → macOS 等价 的替换
# 1. .toolbar(_:for: .navigationBar) 是 tvOS 16+ / iOS 16+ 才有的 API
# 2. .card 按钮样式 macOS 没有
# 3. VideoPlayer 来自 AVKit，macOS 也支持，但这里换成 Text 以避免连带问题
REPLACEMENTS = [
    (
        ".toolbar(model.route != .home ? .hidden : .visible, for: .navigationBar)",
        "",
    ),
    (".buttonStyle(.card)", ".buttonStyle(.bordered)"),
    (r'VideoPlayer\(player: player\.player\)', 'Text("video")'),
]


def main() -> int:
    if shutil.which("swiftc") is None:
        print("✗ 找不到 swiftc（需要 Xcode Command Line Tools）")
        return 1

    sdk_result = subprocess.run(
        ["xcrun", "--show-sdk-path", "--sdk", "macosx"],
        capture_output=True, text=True,
    )
    sdk = sdk_result.stdout.strip()
    if not sdk or not os.path.isdir(sdk):
        print("✗ 找不到 macOS SDK")
        return 1

    tmp = tempfile.mkdtemp(prefix="youku_preflight_")
    try:
        files = [f for f in os.listdir(SOURCES) if f.endswith(".swift")]
        for name in files:
            with open(os.path.join(SOURCES, name), encoding="utf-8") as fh:
                src = fh.read()
            for pattern, replacement in REPLACEMENTS:
                src = src.replace(pattern, replacement)
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
                fh.write(src)

        print(f"编译 {len(files)} 个源文件（macOS SDK 等价编译）…")
        # 在临时目录里编译，避免 .o 产物落到仓库根目录
        proc = subprocess.run(
            [
                "swiftc", "-c",
                "-sdk", sdk,
                "-target", "arm64-apple-macos13.0",
                *sorted(os.path.join(tmp, f) for f in files),
                "-module-name", "YoukuTV",
                "-emit-module",
                "-emit-module-path", os.path.join(tmp, "YoukuTV.swiftmodule"),
            ],
            capture_output=True, text=True,
            cwd=tmp,
        )

        objects = [f for f in os.listdir(tmp) if f.endswith(".o")]
        errors = [ln for ln in (proc.stdout + proc.stderr).splitlines()
                  if "error:" in ln]
        warnings = [ln for ln in (proc.stdout + proc.stderr).splitlines()
                    if "warning:" in ln]

        if errors:
            print(f"\n✗ 发现 {len(errors)} 个编译错误：\n")
            for e in errors[:20]:
                print("   " + e.strip())
            return 1

        if warnings:
            print(f"\n⚠ {len(warnings)} 个警告：\n")
            for w in warnings[:10]:
                print("   " + w.strip())

        print(f"\n✓ 编译通过：{len(objects)}/{len(files)} 个目标文件，零错误")
        print("  注：tvOS 专属 API（.toolbar(for:)、.card）已在本地替换后验证，")
        print("      这部分仍需云端 tvOS 构建最终确认。")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
