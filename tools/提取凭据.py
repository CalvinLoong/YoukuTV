#!/usr/bin/env python3
"""从 ups 请求 URL 中提取 ckey / utid / encryptR_client。

用法: python3 提取凭据.py "<ups 请求 URL>"
"""
import json
import sys
import urllib.parse


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: 提取凭据.py <ups-request-url>", file=sys.stderr)
        return 1

    url = sys.argv[1].strip().strip('"')
    query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    if "data" not in query:
        print("URL 里没有 data 参数", file=sys.stderr)
        return 1

    data = json.loads(query["data"][0])
    steal = json.loads(data.get("steal_params", "{}"))
    biz = json.loads(data.get("biz_params", "{}"))

    result = {
        "ckey": steal.get("ckey", ""),
        "utid": steal.get("utid", ""),
        "encryptR": biz.get("encryptR_client", ""),
        "ccode": steal.get("ccode", ""),
        "vid": biz.get("vid", ""),
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
