#!/usr/bin/env python3
"""校验 App 内置的 ups 凭据是否还有效。

用法: python3 校验凭据.py [源文件路径]

返回码: 0 = 有效, 1 = 已失效
"""
import http.cookiejar
import hashlib
import json
import re
import sys
import time
import urllib.parse
import urllib.request

AK = "24679788"
HOST = "un-acs.youku.com"
API = "mtop.youku.play.ups.appinfo.get"
VER = "1.1"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120 Safari/537.36")

DEFAULT_SRC = "YoukuTV/Sources/YoukuUpsClient.swift"


def read_credential(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()

    def grab(pattern: str) -> str:
        m = re.search(pattern, src)
        return m.group(1) if m else ""

    return {
        "ckey": grab(r'ckey: "([^"]*)"'),
        "utid": grab(r'utid: "([^"]*)"'),
        "encryptR": grab(r'encryptRClient: "([^"]*)"'),
    }


def fetch_token(opener) -> str:
    opener.open(
        urllib.request.Request(
            f"https://{HOST}/h5/{API}/{VER}/?appKey={AK}",
            headers={"User-Agent": UA}),
        timeout=20).read()
    for c in opener.handlers[0].cookiejar if hasattr(opener.handlers[0], "cookiejar") else []:
        if c.name == "_m_h5_tk":
            return c.value.split("_")[0]
    return ""


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    cred = read_credential(path)
    if not cred["ckey"] or not cred["utid"]:
        print(f"✗ 无法从 {path} 读出凭据", file=sys.stderr)
        return 1

    print(f"ckey: {len(cred['ckey'])} 字符 | utid: {cred['utid']}")

    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    try:
        op.open(
            urllib.request.Request(
                f"https://{HOST}/h5/{API}/{VER}/?appKey={AK}",
                headers={"User-Agent": UA}),
            timeout=20).read()
    except Exception as exc:
        print(f"✗ 取 token 失败: {exc}", file=sys.stderr)
        return 1

    tok = ""
    for c in cj:
        if c.name == "_m_h5_tk":
            tok = c.value.split("_")[0]
    if not tok:
        print("✗ 未拿到 _m_h5_tk", file=sys.stderr)
        return 1

    steal = {
        "ccode": "0502", "utid": cred["utid"], "version": "9.22.2",
        "ckey": cred["ckey"], "client_ip": "0.0.0.0",
        "client_ts": str(int(time.time())),
    }
    biz = {
        "vid": "XODM5OTI3Njky", "local_vid": "XODM5OTI3Njky", "h265": 1,
        "current_showid": "9bbc2c96790d11e4b522", "preferClarity": -1,
        "media_type": "standard,subtitle", "app_ver": "9.22.2",
        "extag": "EXT-X-PRIVINF", "play_ability": 2164266240,
        "close_ability": 655360, "master_m3u8": 1, "drm_type": 3,
        "key_index": "web01", "encryptR_client": cred["encryptR"],
        "enc_ver": 2, "pn": "com.youku.pcweb", "playMode": "normal",
    }
    ad = {
        "vs": "1.0", "pver": "9.22.2", "sver": "2.0", "site": 1, "aw": "w",
        "fu": 0, "d": 0, "bt": "pc", "os": "mac", "partnerid": "null",
        "wintype": "interior", "isvert": 0, "vip": 0, "emb": 0, "p": 1,
        "rst": "mp4", "needbf": 2, "avs": "1.0", "needad": 1,
    }

    data = {"steal_params": steal, "biz_params": biz, "ad_params": ad}
    dj = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    t = str(int(time.time() * 1000))
    sign = hashlib.md5(f"{tok}&{t}&{AK}&{dj}".encode()).hexdigest()

    params = {
        "jsv": "2.6.1", "appKey": AK, "t": t, "sign": sign, "api": API,
        "v": VER, "timeout": "15000", "type": "jsonp", "dataType": "jsonp",
        "callback": "mtopjsonp1", "data": dj,
    }
    url = f"https://{HOST}/h5/{API}/{VER}/?" + urllib.parse.urlencode(params)

    try:
        body = op.open(
            urllib.request.Request(
                url, headers={"User-Agent": UA, "Referer": "https://v.youku.com/"}),
            timeout=25).read().decode("utf-8", "ignore")
    except Exception as exc:
        print(f"✗ 请求失败: {exc}", file=sys.stderr)
        return 1

    m = re.match(r"^\s*\w+\((.*)\)\s*;?$", body.strip(), re.S)
    payload = json.loads(m.group(1)) if m else json.loads(body)

    inner = payload.get("data", {}).get("data", {}) if isinstance(payload.get("data"), dict) else {}
    streams = inner.get("stream")

    print(f"ret: {payload.get('ret')}")
    if not streams:
        err = payload.get("data", {}).get("error") if isinstance(payload.get("data"), dict) else None
        print(f"✗ 凭据已失效（stream 为空） {err or ''}")
        print("  → 双击「更新ckey.command」重新生成")
        return 1

    print(f"✓ 凭据有效，取到 {len(streams)} 条播放地址:")
    for s in streams[:4]:
        print(f"   {s.get('stream_type'):8} {s.get('width')}x{s.get('height')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
