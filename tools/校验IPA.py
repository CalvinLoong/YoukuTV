#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验下载下来的 IPA 是否可正常侧载。

检查项（任何一项不过就退出码 1）：
  1. zipfile.testzip() 无损坏条目
  2. 无重复条目
  3. 第一层条目必须是 Payload/（IPA 规范）
  4. 必须含 Payload/<App>.app/<App>（主程序）
  5. 必须含 Payload/<App>.app/Info.plist
  6. 必须含 Payload/<App>.app/Assets.car（缺陷 1 的关键）
  7. Info.plist 里图标键齐全（缺陷 1）
  8. 主程序是有效的 Mach-O，且架构含 arm64

用法：python3 tools/校验IPA.py <ipa路径> [App名]
"""
import json
import plistlib
import subprocess
import sys
import zipfile

APP_NAME = "YoukuTV"


def fail(msg):
    print(f"  ✗ {msg}")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print("用法: python3 tools/校验IPA.py <ipa路径> [App名]", file=sys.stderr)
        return 1
    ipa = sys.argv[1]
    app = sys.argv[2] if len(sys.argv) > 2 else APP_NAME

    print(f"=== 校验 {ipa} ===")

    # 1) 损坏检测
    with zipfile.ZipFile(ipa) as z:
        bad = z.testzip()
        if bad is not None:
            fail(f"归档存在损坏条目：{bad}")

        names = z.namelist()
        if len(names) != len(set(names)):
            dup = [n for n in set(names) if names.count(n) > 1]
            fail(f"存在重复条目：{dup}")
        print(f"  ✓ testzip() 通过，共 {len(names)} 个条目")

        # 3) 第一层必须是 Payload/
        tops = {n.split("/")[0] for n in names}
        if tops != {"Payload"}:
            fail(f"第一层条目不是纯 Payload/：{sorted(tops)}")
        print("  ✓ 条目前缀正确（Payload/...）")

        # 4-6) 关键文件
        need = {
            f"Payload/{app}.app/{app}": "主程序",
            f"Payload/{app}.app/Info.plist": "Info.plist",
            f"Payload/{app}.app/Assets.car": "Assets.car",
        }
        for path, label in need.items():
            if path not in names:
                fail(f"缺少{label}：{path}")
            print(f"  ✓ 存在{label}")

        # 7) Info.plist 键检查
        plist = plistlib.loads(z.read(f"Payload/{app}.app/Info.plist"))
        icons = plist.get("CFBundleIcons") or {}
        primary = icons.get("CFBundlePrimaryIcon")
        # ★ Xcode 会把 CFBundlePrimaryIcon 扁平化：
        #   写成字典 → 产物里是字符串 "App Icon"
        #   所以两种形态都要认。
        if isinstance(primary, dict):
            primary = primary.get("CFBundleIconName")
        if not primary:
            fail("Info.plist 缺少 CFBundleIcons.CFBundlePrimaryIcon")
        print(f"  ✓ 图标键齐全（CFBundleIconName = {primary}）")
        print(f"    CFBundleDisplayName = {plist.get('CFBundleDisplayName')}")
        print(f"    TVTopShelfImage = {plist.get('TVTopShelfImage')}")

        assets_size = z.getinfo(f"Payload/{app}.app/Assets.car").file_size
        print(f"  ✓ Assets.car 大小 {assets_size} 字节")
        if assets_size < 10000:
            fail("Assets.car 太小，很可能图标没编进去")

        # 8) 提取主程序检查 Mach-O
        exe = z.read(f"Payload/{app}.app/{app}")
        magic = exe[:4]
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                         b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            fail(f"主程序不是 Mach-O（magic = {magic.hex()}）")
        print(f"  ✓ 主程序是合法 Mach-O（{len(exe)} 字节）")

    # 架构检查（macOS 特有）
    import tempfile
    import os
    with tempfile.TemporaryDirectory() as td:
        exe_path = os.path.join(td, app)
        with zipfile.ZipFile(ipa) as z:
            with open(exe_path, "wb") as f:
                f.write(z.read(f"Payload/{app}.app/{app}"))
        try:
            out = subprocess.run(["lipo", "-info", exe_path],
                                 capture_output=True, text=True, timeout=30).stdout.strip()
            print(f"  ✓ 架构：{out}")
            if "arm64" not in out:
                fail("主程序不含 arm64 架构")
        except FileNotFoundError:
            print("  ⚠️ 本机无 lipo，跳过架构检查")

    print("\n✓ IPA 全部校验通过，可用于侧载")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
