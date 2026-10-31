#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打包 tvOS IPA（未签名）并自检。

## 为什么不用 macOS 自带的 zip

实测在 GitHub Actions 的 macOS runner 上，`zip -qry YoukuTV-unsigned.ipa Payload`
会产出一个**结构损坏**的包：

- `Info.plist` 和 `PkgInfo` 在包内各出现**两次**
- 中央目录被写进了文件**中间**（起始位置 537507，而文件总长 545888）
- local file header 里的 csize 与中央目录对不上（差 1 字节）
- Python 的 `zipfile.testzip()` 报 "Bad CRC-32"，
  `unzip` 能勉强解出但**主程序 YoukuTV 直接丢失**

Sideloadly 解不开这种包，侧载必然失败。
Python 的 `zipfile` 行为确定，产出的包一定能被正确解开。

## 用法

    python3 打包IPA.py <AppName> [Payload目录] [输出ipa路径]
"""
import os
import sys
import zipfile


def main():
    if len(sys.argv) < 2:
        print("用法: python3 打包IPA.py <AppName> [Payload目录] [输出路径]", file=sys.stderr)
        return 1

    app_name = sys.argv[1]
    payload = sys.argv[2] if len(sys.argv) > 2 else "Payload"
    out = sys.argv[3] if len(sys.argv) > 3 else "YoukuTV-unsigned.ipa"

    if not os.path.isdir(payload):
        print(f"::error::找不到 Payload 目录：{payload}")
        return 1

    out_dir = os.path.dirname(os.path.abspath(out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        # ★ IPA 规范要求条目路径以 "Payload/" 开头，
        #   不能带上 Payload 目录自身的父路径（例如 build/Payload/...）。
        base = os.path.basename(payload.rstrip("/"))
        for root, dirs, files in os.walk(payload):
            for d in sorted(dirs):
                p = os.path.join(root, d)
                arc = f"{base}/{os.path.relpath(p, payload)}"
                z.write(p, arc)
            for f in sorted(files):
                p = os.path.join(root, f)
                arc = f"{base}/{os.path.relpath(p, payload)}"
                z.write(p, arc)

    # 自检：条目必须能完整读出且 CRC 正确
    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad:
            print(f"::error::IPA 自检失败，损坏条目：{bad}")
            return 1

        names = z.namelist()
        print("IPA 条目：")
        for n in names:
            print("  ", n)

        need = [
            f"{base}/{app_name}.app/{app_name}",
            f"{base}/{app_name}.app/Info.plist",
            f"{base}/{app_name}.app/Assets.car",
        ]
        for req in need:
            if req not in names:
                print(f"::error::IPA 缺少关键条目：{req}")
                print("（提示：主程序缺失通常说明 .app 目录本身不完整）")
                return 1

        # 不得有重复条目（macOS zip 的经典故障）
        if len(names) != len(set(names)):
            dupes = {n for n in names if names.count(n) > 1}
            print(f"::error::IPA 存在重复条目：{sorted(dupes)}")
            return 1

    size = os.path.getsize(out)
    print(f"✓ IPA 自检通过（{len(names)} 个条目，{size/1024:.0f} KB）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
