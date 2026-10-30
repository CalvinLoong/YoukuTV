#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Apple TV 配对自检工具（tvOS 26/27 适用）

用途：在 Apple TV 上打开"配对模式"页面后，运行本脚本，
      立刻告诉你电脑能不能"看见"你的 Apple TV、它的 IP 是多少、
      以及 Sideloadly 能不能完成配对。

用法：
    python3 tools/检查AppleTV配对.py          # 检查一次
    python3 tools/检查AppleTV配对.py --watch  # 持续监听（推荐，配对时用）

配合 Sideloadly 排查 tvOS 26.4+ 的 mDNS 服务名变更问题。
"""

import subprocess
import sys
import time
import re
import socket
import argparse

# tvOS 26.4 起 Apple 把广播服务名改了，两个都要查
SERVICES = [
    ("_remotepairing-manual-pairing._tcp", "tvOS 26.4+ 新服务名（配对用）"),
    ("_apple-pairable._tcp", "tvOS 26.4 之前的老服务名（配对用）"),
    ("_apple-mobdev2._tcp", "iOS 设备发现（Apple TV 一般没有）"),
    ("_airplay._tcp", "AirPlay 接收端（用来确认 Apple TV 在线）"),
    ("_companion-link._tcp", "Apple 设备互联（用来确认 Apple TV 在线）"),
]

# 一眼能认出来的 Apple TV 广播名
# 注意：mDNS 里 "Apple TV" 的空格可能是 U+00A0，所以匹配前统一归一化
TV_HINTS = ("appletv", "客厅", "卧室", "书房", "apple tv")


def norm(s: str) -> str:
    """把不换行空格等统一成普通空格并小写，便于比较"""
    return s.replace("\xa0", " ").replace(" ", " ").strip().lower()


def run_dnssd_browse(service: str, seconds: float = 3.0):
    """用 dns-sd 浏览一个 mDNS 服务，返回 (实例名列表, 原始文本)"""
    try:
        p = subprocess.Popen(
            ["dns-sd", "-B", service, "local."],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
    except FileNotFoundError:
        return [], "dns-sd 不可用"
    time.sleep(seconds)
    p.terminate()
    try:
        out, _ = p.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        out = ""
    names = []
    for line in out.splitlines():
        if "Add" not in line and "Add?" not in line:
            continue
        # dns-sd 输出里，**列**之间是普通空格，**实例名内部**可能是 U+00A0
        # （例如 "Apple TV" 实际写作 "Apple\xa0TV"）。
        # 所以这里只用普通空格切分，实例名里的 U+00A0 要原样保留。
        parts = line.strip().split(" ")
        parts = [p for p in parts if p != ""]
        # 形如: 时间 Add <flags> <if> local. <service> <实例名>
        try:
            idx = parts.index("local.")
        except ValueError:
            continue
        if len(parts) <= idx + 2:
            continue
        n = parts[idx + 2].strip()
        if n and n not in names:
            names.append(n)
    return names, out


def resolve(service: str, instance: str, seconds: float = 3.0):
    """解析一个实例的真实 IP"""
    try:
        p = subprocess.Popen(
            ["dns-sd", "-L", instance, service, "local."],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
    except FileNotFoundError:
        return None
    time.sleep(seconds)
    p.terminate()
    try:
        out, _ = p.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        out = ""
    m = re.search(r"can be reached at ([\w\-.]+):\d+", out)
    if not m:
        return None
    host = m.group(1)
    try:
        return socket.gethostbyname(host)
    except socket.gaierror:
        return host


def scan_once(verbose=False):
    """扫描一轮，返回 (找到的TV列表, 诊断信息字典)"""
    info = {}
    online = []
    for svc, desc in SERVICES:
        names, _ = run_dnssd_browse(svc, 2.5)
        info[svc] = names
        if verbose:
            print(f"  扫描 {svc}")
        if svc in ("_airplay._tcp", "_companion-link._tcp"):
            for n in names:
                if any(h in norm(n) for h in TV_HINTS):
                    if (svc, n) not in online:
                        online.append((svc, n))

    # 找可配对的 Apple TV
    pairable = []
    for svc in ("_remotepairing-manual-pairing._tcp", "_apple-pairable._tcp"):
        for n in info.get(svc, []):
            ip = resolve(svc, n, 2.5)
            pairable.append((svc, n, ip))
    return pairable, info, online


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", action="store_true", help="持续监听")
    args = ap.parse_args()

    print("=" * 60)
    print("  Apple TV 配对自检（tvOS 26/27）")
    print("=" * 60)
    print()
    print("请先在 Apple TV 上打开：")
    print("  设置 → 遥控器与设备 → 遥控器App与设备")
    print("（这个页面要一直停留着，不要退出）")
    print()

    while True:
        print("正在扫描局域网…")
        pairable, info, online = scan_once()

        print()
        print("【1】Apple TV 是否在线")
        if online:
            for svc, n in online:
                print(f"    ✅ 发现 {n}   (via {svc})")
        else:
            print("    ⚠️  没扫到 Apple TV。检查：")
            print("       · 电视和电脑是不是同一个 WiFi？")
            print("       · 电视是不是睡着/待机了？")
            print("       · 路由器有没有开 AP 隔离（访客网络隔离）？")

        print()
        print("【2】配对服务是否广播")
        if pairable:
            for svc, n, ip in pairable:
                print(f"    ✅ 配对服务已广播")
                print(f"       实例名 : {n}")
                print(f"       IP 地址: {ip or '解析失败（可用上面 IP 手填）'}")
                print(f"       服务名 : {svc}")
            print()
            print("  → 电视端已就绪。现在打开 Sideloadly，")
            print("    右侧设备列表应该能看到它。选它 → 填 Apple ID → Start")
        else:
            print("    ❌ 没有广播配对服务")
            print("       说明电视还没进入配对模式。")
            print("       请在电视上确认停在「遥控器App与设备」这一页。")
            print()
            print("       如果电视明明停在那页还是扫不到：")
            print("       · tvOS 26.4+ 换了广播名，若 Sideloadly 版本太老会认不出")
            print("         （你的 Sideloadly 需 ≥ 0.61）")
            print("       · 两边都「忘记此网络」再重连一次，重启 Mac")

        print()
        print("=" * 60)
        if not args.watch:
            break
        print("  监听中… Ctrl+C 退出")
        print()
        time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n已退出")
