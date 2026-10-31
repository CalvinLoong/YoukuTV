#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""登录协议攻坚：系统地测试 Havana 轮询接口的参数变体。

已知：
  - genQrCode 走 acs.youku.com + GET + MD5(token&t&appKey&data) 签名 → 成功
  - qrcodelogin 走同一 host/方法 → 报 13015 / SERVICE_FAULT

本脚本枚举 token 格式、site、utdid、ext 等维度的组合，
找出服务端能正常返回状态码（14030 未扫码 / 14031 已扫 / 3000 成功）的组合。
"""
import hashlib
import itertools
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

APP_KEY = "23299685"
VER = "1.0"
GEN_API = "mtop.taobao.commonuse.mloginService.genQrCode"
POLL_API = "mtop.taobao.commonuse.mloginService.qrcodelogin"

UA_ANDROID = ("Mozilla/5.0 (Linux; Android 13; AppleTV) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36")
UA_PC = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
         "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


class Session:
    def __init__(self, ua=UA_ANDROID):
        self.ua = ua
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar))

    def cookies(self):
        return {c.name: c.value for c in self.jar}

    def token(self):
        v = self.cookies().get("_m_h5_tk", "")
        return v.split("_")[0][:32] if v else ""

    def prime(self, api, host="acs.youku.com"):
        url = (f"https://{host}/h5/{api}/{VER}/"
               f"?appKey={APP_KEY}&api={api}&v={VER}")
        try:
            self.opener.open(
                urllib.request.Request(url, headers={"User-Agent": self.ua}),
                timeout=20).read()
        except Exception:
            pass

    def call(self, api, data_obj, host="acs.youku.com", ver=VER,
             referer="https://login.youku.com/", ttid="123@tvhomeshell_yunos_1.0.0",
             extra_query=None):
        data = json.dumps(data_obj, separators=(",", ":"), ensure_ascii=False)
        if not self.token():
            self.prime(api, host)
        t = str(int(time.time() * 1000))
        sign = hashlib.md5(f"{self.token()}&{t}&{APP_KEY}&{data}".encode()).hexdigest()
        p = {"jsv": "2.6.1", "appKey": APP_KEY, "t": t, "sign": sign, "api": api,
             "v": ver, "timeout": "20000", "type": "jsonp", "dataType": "jsonp",
             "callback": "mtopjsonp1", "data": data, "ttid": ttid}
        if extra_query:
            p.update(extra_query)
        url = f"https://{host}/h5/{api}/{ver}/?" + urllib.parse.urlencode(p)
        req = urllib.request.Request(url, headers={
            "User-Agent": self.ua, "Referer": referer,
            "Accept": "application/json, text/plain, */*"})
        try:
            with self.opener.open(req, timeout=25) as r:
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
        except Exception as e:
            return {"_err": str(e)}
        m = re.search(r"^[^(]*\((.*)\)\s*;?\s*$", raw, re.S)
        try:
            return json.loads(m.group(1) if m else raw)
        except Exception:
            return {"_raw": raw[:400]}


def risk_control(utdid="", full=True):
    base = {"osName": "android", "osVersion": "13", "deviceModel": "AppleTV",
            "deviceName": "AppleTV", "screenSize": "3840x2160", "appStore": "",
            "ssid": "", "bssid": "", "deviceBrand": "Apple", "mac": "",
            "imei": "", "umidToken": ""}
    if not full:
        base = {"osName": "android", "osVersion": "13"}
    return json.dumps(base, separators=(",", ":"))


def gen_qr(sess, utdid, app_name=APP_KEY, site=0, sdk="android_4.8.2"):
    qr = {"appName": app_name, "callbackUrl": "",
          "ext": {"tlsite": "https://login.youku.com"},
          "qrCodeSize": 300, "sdkVersion": sdk, "site": site,
          "utdid": utdid, "youkuProperty": "{}",
          "genShortUrl": True, "genQrImage": True}
    return sess.call(GEN_API, {
        "qrCodeGenInfo": json.dumps(qr, separators=(",", ":")),
        "riskControlInfo": risk_control(utdid),
        "appKey": APP_KEY,
        "ext": json.dumps({"appKey": APP_KEY}, separators=(",", ":")),
    })


def token_info(token, uuid, utdid, site=0, app_version="13.0.1.3"):
    """严格按 TokenLoginRequest 的字段集（含两级父类继承字段）。"""
    return {
        "token": token, "loginSite": "", "scene": "", "tokenType": "",
        # LoginRequestBase
        "deviceTokenKey": "", "deviceTokenSign": "", "hid": "", "sid": "",
        "snsToken": "", "t": int(time.time() * 1000), "useDeviceToken": True,
        "deviceName": "AppleTV", "useAcitonType": True,
        # MemberRequestBase
        "appName": APP_KEY, "appVersion": app_version, "deviceId": "",
        "ext": {"uuid": uuid}, "locale": "zh_CN", "sdkVersion": "android_4.8.2",
        "site": site, "sysExt": {}, "ttid": "", "utdid": utdid,
    }


def summarize(tag, resp):
    d = resp.get("data")
    if not isinstance(d, dict):
        print(f"  {tag}: ret={resp.get('ret')} raw={str(resp.get('_raw') or resp.get('_err'))[:120]}")
        return None
    code = d.get("code")
    msg = d.get("message")
    rv = d.get("returnValue")
    ok = "✅" if code in (14030, 14031, 3000) else "  "
    print(f"  {ok} {tag}: ret={resp.get('ret')} code={code} msg={msg}")
    if isinstance(rv, dict):
        print(f"      returnValue keys={list(rv.keys())}")
        print(f"      {json.dumps(rv, ensure_ascii=False)[:600]}")
    return code


def main():
    print("=" * 72)
    print("阶段 1：生成二维码（复用同一 session，轮询必须同会话）")
    print("=" * 72)
    sess = Session(UA_ANDROID)
    utdid = "tv-utid-" + hashlib.md5(str(time.time()).encode()).hexdigest()[:12]
    uuid = "tv-uuid-" + hashlib.md5(str(time.time()).encode()).hexdigest()[:12]
    r = gen_qr(sess, utdid)
    d = r.get("data") or {}
    rv = d.get("returnValue") or {}
    print(f"  gen code={d.get('code')} token={rv.get('token')}")
    print(f"  qrCodeUrl={rv.get('qrCodeUrl')}")
    if not rv.get("token"):
        print("  生成失败，终止")
        return
    full_token = rv["token"]
    bare_token = full_token.split("_")[0]

    print()
    print("=" * 72)
    print("阶段 2：轮询参数变体枚举")
    print("=" * 72)
    variants = []
    for tname, tval in (("完整token", full_token), ("去后缀token", bare_token)):
        for site in (0, 23):
            for extra_ext in ({"uuid": uuid}, {"uuid": uuid, "appKey": APP_KEY},
                              {"appKey": APP_KEY}, {}):
                variants.append((f"{tname}|site={site}|ext={sorted(extra_ext)}",
                                 tval, site, extra_ext))
    # 只跑前 8 个，避免请求过多
    for tag, tval, site, extra_ext in variants[:8]:
        ti = token_info(tval, uuid, utdid, site)
        resp = sess.call(POLL_API, {
            "tokenInfo": json.dumps(ti, separators=(",", ":")),
            "riskControlInfo": risk_control(utdid),
            "appKey": APP_KEY,
            "ext": json.dumps({"appKey": APP_KEY, **extra_ext}, separators=(",", ":")),
        })
        code = summarize(tag, resp)
        if code in (14030, 14031, 3000):
            print("\n  ★★★ 命中可用组合，中断枚举 ★★★")
            print(f"  组合: {tag}")
            print(f"  tokenInfo = {json.dumps(ti, ensure_ascii=False)}")
            return


if __name__ == "__main__":
    main()
