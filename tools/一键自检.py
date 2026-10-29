#!/usr/bin/env python3
"""YoukuTV 一键自检：编译 + 凭据 + 播放链路。

一次跑完三件事，任何一项失败都会明确报出来：

  1. 编译检查   —— 用 macOS SDK 做等价编译，暴露真实编译错误
  2. 凭据检查   —— 内置的 ckey/utid 是否还有效
  3. 播放链路   —— 搜索 → 取 vid → 取播放地址（真实网络请求）

用法:
    python3 tools/一键自检.py
    python3 tools/一键自检.py 庆余年 甄嬛传      # 指定测试关键词
返回码: 0 = 全部通过, 1 = 有失败项
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable


def step(title: str) -> None:
    print()
    print("━" * 62)
    print(f" {title}")
    print("━" * 62)


def run_check(script: str, args=None) -> bool:
    cmd = [PY, os.path.join(ROOT, "tools", script)]
    if args:
        cmd += args
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        print("✗ 超时（5 分钟）")
        return False
    out = (proc.stdout or "") + (proc.stderr or "")
    print(out.rstrip())
    return proc.returncode == 0


def main() -> int:
    keywords = sys.argv[1:] or None
    results = {}

    step("1/3  编译检查（macOS SDK 等价编译）")
    results["编译"] = run_check("本地编译检查.py")

    step("2/3  凭据有效性")
    results["凭据"] = run_check("校验凭据.py")

    step("3/3  播放链路回归")
    results["链路"] = run_check("回归测试.py", keywords)

    print()
    print("━" * 62)
    print(" 自检结果")
    print("━" * 62)
    for name, ok in results.items():
        print(f"  {'✓' if ok else '✗'} {name}")
    failed = [k for k, v in results.items() if not v]
    print()
    if failed:
        print(f"✗ {len(failed)} 项未通过：{', '.join(failed)}")
        return 1
    print("✓ 全部通过 —— 代码可编译、凭据有效、播放链路通畅")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
