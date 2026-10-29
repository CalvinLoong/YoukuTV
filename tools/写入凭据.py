#!/usr/bin/env python3
"""把新的 ckey / utid / encryptR 写入 YoukuUpsClient.swift 的 builtin 凭据。

用法: python3 写入凭据.py <源文件路径> <ckey> <utid> <encryptR>
"""
import re
import sys
import time


def main() -> int:
    if len(sys.argv) < 5:
        print("用法: 写入凭据.py <file> <ckey> <utid> <encryptR>", file=sys.stderr)
        return 1

    path, ckey, utid, encrypt_r = sys.argv[1:5]
    with open(path, encoding="utf-8") as fh:
        src = fh.read()

    stamp = int(time.time())

    def sub(pattern, value, text):
        new, n = re.subn(pattern, lambda m: m.group(1) + value + m.group(2), text, count=1)
        if n == 0:
            raise SystemExit(f"未找到匹配: {pattern}")
        return new

    src = sub(r'(ckey: ")[^"]*(")', ckey, src)
    src = sub(r'(utid: ")[^"]*(")', utid, src)
    src = sub(r'(encryptRClient: ")[^"]*(")', encrypt_r, src)
    src = sub(r'(generatedAt: Date\(timeIntervalSince1970: )\d+(\))', str(stamp), src)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)

    print(f"已更新 {path}")
    print(f"  ckey 长度: {len(ckey)}")
    print(f"  utid: {utid}")
    print(f"  时间戳: {stamp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
