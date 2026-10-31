#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""实测优酷 passport 扫码登录接口是否可用 PC Web 的 MD5 签名调通。

背景：逆向发现酷喵 TV 的 passport 登录走 mtop.youku.passport.ottservice.genQrcode，
但其 MTOP sign 走 SecurityGuard（无法纯 Swift 复刻）。
本脚本验证：能否用 PC Web 的标准 MD5(token&t&appKey&data) 签名调通同一个 mtop 接口。
若能通，说明服务端对 passport 接口也接受标准 MD5 sign → 登录可纯 Swift 实现。
"""
import hashlib
import json
import re
import time
import urllib.parse
import http.cookiejar
import urllib.request

APP_KEY = "23299685"          # CIBN/酷喵 passport appKey（逆向自 AliTvConfig）
API_GEN = "mtop.youku.passport.ottservice.genQrcode"
API_LOGIN = "mtop.youku.passport.ottservice.loginByQrcode"
HOST = "acs.youku.com"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def cookie_map():
    return {c.name: c.value for c in jar}


def token():
    v = cookie_map().get("_m_h5_tk", "")
    return v.split("_")[0][:32] if v else ""


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def strip_jsonp(text):
    m = re.search(r"^[^(]*\((.*)\)\s*;?\s*$", text, re.S)
    if m:
        return m.group(1)
    return text


def call(api, data_obj, version="1.0", use_post=True):
    """调用 mtop h5 接口，自动做 token prime + MD5 签名。"""
    data = json.dumps(data_obj, separators=(",", ":"), ensure_ascii=False)

    # prime: 先请求一次拿 _m_h5_tk
    if not token():
        prime_url = f"https://{HOST}/h5/{api}/{version}/?appKey={APP_KEY}&api={api}&v={version}"
        req = urllib.request.Request(prime_url, headers={"User-Agent": UA})
        try:
            opener.open(req, timeout=20).read()
        except Exception as e:
            print(f"   prime 失败: {e}")

    t = str(int(time.time() * 1000))
    tok = token()
    sign = md5(f"{tok}&{t}&{APP_KEY}&{data}")

    params = {
        "jsv": "2.6.1",
        "appKey": APP_KEY,
        "t": t,
        "sign": sign,
        "api": api,
        "v": version,
        "timeout": "20000",
        "type": "jsonp",
        "dataType": "jsonp",
        "callback": "mtopjsonp1",
        "data": data,
        "ttid": "123@tvhomeshell_yunos_1.0.0",
    }
    url = f"https://{HOST}/h5/{api}/{version}/?" + urllib.parse.urlencode(params)
    headers = {
        "User-Agent": UA,
        "Referer": "https://passport.youku.com/",
        "Accept": "application/json, text/plain, */*",
    }
    body = None
    if use_post:
        req = urllib.request.Request(url, data=data.encode("utf-8"), headers=headers, method="POST")
        # POST 时 data 已在 query 里，同时放 body
    else:
        req = urllib.request.Request(url, headers=headers, method="GET")

    try:
        with opener.open(req, timeout=25) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
    except Exception as e:
        return {"_error": str(e)}

    raw = strip_jsonp(raw)
    try:
        return json.loads(raw)
    except Exception:
        return {"_raw": raw[:600]}


def summarize(title, resp):
    print(f"\n{'='*60}")
    print(f"[{title}]")
    print(f"{'='*60}")
    if "_error" in resp or "_raw" in resp:
        print(json.dumps(resp, ensure_ascii=False, indent=2)[:900])
        return
    ret = resp.get("ret", [])
    print(f"ret = {ret}")
    d = resp.get("data")
    if isinstance(d, dict):
        # passport 业务体在 content
        content = d.get("content")
        keys = list(d.keys())
        print(f"data keys = {keys}")
        if isinstance(content, dict):
            print(f"content keys = {list(content.keys())}")
            for k in ("qrcode", "qrcodeUrl", "cycleSecs", "extInfo", "ptoken", "ytid",
                      "yktk", "loginAppId", "nickname", "ptokenExpireTime"):
                if k in content:
                    v = content[k]
                    print(f"  content.{k} = {str(v)[:120]}")
        else:
            print(f"data (no content) = {json.dumps(d, ensure_ascii=False)[:500]}")
    else:
        print(json.dumps(resp, ensure_ascii=False)[:700])


if __name__ == "__main__":
    print(f"token 前置探测: {cookie_map()}")

    base_info = {
        "appId": "23299685",
        "timestamp": int(time.time() * 1000),
        "sdkVersion": "13.0.0.5",
        "osName": "android",
        "osVersion": "13",
        "deviceName": "AppleTV",
        "deviceBrand": "Apple",
        "deviceModel": "AppleTV",
        "screenSize": "3840x2160",
        "utdid": "test-utid-0001",
        "appVersion": "13.0.1.3",
        "uuid": "test-uuid-0001",
        "cid": "test-cid-0001",
        "network": "WIFI",
        "genShortUrl": True,
    }

    print("\n>>> 实验 1：passport genQrcode（GET）")
    r1 = call(API_GEN, dict(base_info), use_post=False)
    summarize("genQrcode GET", r1)

    print("\n>>> 实验 2：passport genQrcode（POST）")
    r2 = call(API_GEN, dict(base_info), use_post=True)
    summarize("genQrcode POST", r2)

    # 若任一成功且拿到 qrcode，尝试轮询
    for label, r in (("GET", r1), ("POST", r2)):
        try:
            content = r["data"]["content"]
        except Exception:
            continue
        qr = content.get("qrcode")
        if not qr:
            continue
        print(f"\n>>> 实验 3：轮询 loginByQrcode（{label}）")
        r3 = call(API_LOGIN, {**base_info, "qrcode": qr, "cycleSecs": 2000}, use_post=False)
        summarize(f"loginByQrcode {label}", r3)
        break

    print("\n>>> cookie 终态:", cookie_map())
