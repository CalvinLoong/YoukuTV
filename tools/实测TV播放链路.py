#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
实测 TV 端原生播放接口 `mtop.yunos.videoplay.playurl.getPlayUrlNew`。

逆向依据（CoolMiao TV / CIBN 版 APK）：
  a/g/a/a/n/playc.java:16-27
      appKey    = 23669785
      authCode  = 61ed3d678a781955028d395b54d20878
      api       = mtop.yunos.videoplay.playurl.getPlayUrlNew
      version   = 1.0
      ttid      = 123@tvhomeshell_yunos_1.0.0
  a/g/a/a/h/d/playO.java:153-161
      data = { "videoId": <fileId>, "systemInfo": <JSON 字符串> }
  com/yunos/tv/player/config/OttSystemConfig.java:320-388
      systemInfo 字段 = uuid/device_sn/token(stoken)/ccode/device_media/sw/...

本脚本做两件事：
  1. 枚举签名方式（cookie H5 sign / 原生 sign），找出哪种能让服务端认出 appKey
  2. 打通后打印响应结构，确认 stream 在哪个字段
"""
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import http.cookiejar

HOSTS = [
    "acs.m.taobao.com",
    "acs.youku.com",
]
API = "mtop.yunos.videoplay.playurl.getPlayUrlNew"
VERSION = "1.0"
APP_KEY = "23669785"
AUTH_CODE = "61ed3d678a781955028d395b54d20878"
TTID = "123@tvhomeshell_yunos_1.0.0"
UA = ("Mozilla/5.0 (Linux; Android 9; CIBN TV Build/PPR1) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/77.0.3865.120 Safari/537.36")


def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def jstr(o) -> str:
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def make_system_info(uuid: str, token: str = "", ccode: str = "0502",
                     device_model: str = "AppleTV4K") -> str:
    """构造 systemInfo（注意是 JSON 字符串，不是嵌套对象）。"""
    info = {
        "uuid": uuid,
        "device_sn": uuid[:32],
        "device_model": device_model,
        "device_system_version": "tvOS 27.0",
        "device_firmware_version": "27.0",
        "firmware": "27.0",
        "charge_type": "2,3,5",
        "sw": "sw4k",
        "verson_code": 1,
        "package_name": "com.youku.ott",
        "device_media": "TV_4K",
        "mac": "02:00:00:00:00:01",
        "ethmac": "02:00:00:00:00:01",
        "from": "0,7,9",
        "license": 0,
        "bcp": 0,
        "ccode": ccode,
    }
    if token:
        info["token"] = token
    return jstr(info)


class Client:
    def __init__(self, host: str):
        self.host = host
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar))
        self.token = ""

    def prime(self):
        """先请求一次拿 _m_h5_tk cookie。"""
        url = (f"https://{self.host}/h5/{API}/{VERSION}/?"
               + urllib.parse.urlencode({"appKey": APP_KEY, "api": API, "v": VERSION}))
        try:
            self.opener.open(urllib.request.Request(url, headers={"User-Agent": UA}),
                             timeout=20).read()
        except Exception as e:
            return f"prime err: {e}"
        for c in self.jar:
            if c.name == "_m_h5_tk":
                self.token = c.value.split("_")[0][:32]
        return f"token = {self.token[:12] or '(空)'}…"

    def call(self, data: str, sign_style: str = "h5", extra=None):
        t = str(int(time.time() * 1000))
        if sign_style == "h5":
            sign = md5(f"{self.token}&{t}&{APP_KEY}&{data}")
        elif sign_style == "h5_secret":
            sign = md5(f"{self.token}&{t}&{APP_KEY}&{data}&{AUTH_CODE}")
        elif sign_style == "native":
            sign = md5(f"{APP_KEY}{t}{APP_KEY}&{data}")
        elif sign_style == "native2":
            sign = md5(f"{APP_KEY}&{t}&{APP_KEY}&{data}")
        else:
            raise ValueError(sign_style)

        params = {
            "jsv": "2.6.1",
            "appKey": APP_KEY,
            "t": t,
            "sign": sign,
            "api": API,
            "v": VERSION,
            "timeout": "20000",
            "type": "originaljson",
            "dataType": "json",
            "data": data,
        }
        if extra:
            params.update(extra)
        url = f"https://{self.host}/h5/{API}/{VERSION}/?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={
            "User-Agent": UA,
            "Accept": "application/json",
            "Referer": "https://www.youku.com/",
        })
        try:
            with self.opener.open(req, timeout=25) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except Exception as e:
            return {"_http_error": str(e)}
        try:
            return json.loads(raw)
        except Exception:
            return {"_raw": raw[:400]}


def brief(resp):
    if "_http_error" in resp:
        return f"HTTP错误: {resp['_http_error']}"
    if "_raw" in resp:
        return f"非JSON: {resp['_raw'][:160]}"
    ret = resp.get("ret")
    if isinstance(ret, list):
        ret = "; ".join(ret)
    data = resp.get("data")
    ds = ""
    if isinstance(data, str):
        try:
            data = json.loads(data)
        except Exception:
            data = {}
    if isinstance(data, dict):
        # data.result 仍是 JSON 字符串
        result = data.get("result")
        if isinstance(result, str):
            try:
                result = json.loads(result)
            except Exception:
                result = {}
        if isinstance(result, dict):
            si = result.get("sourceInfo")
            if isinstance(si, dict):
                keys = [k for k, v in si.items() if v]
                ds = f" sourceInfo 有值: {keys}"
            else:
                ds = f" result keys: {list(result.keys())[:10]}"
        else:
            ds = f" data keys: {list(data.keys())[:10]}"
    return f"ret={ret}{ds}"


def main():
    # 取一个真实 vid
    vid = sys.argv[1] if len(sys.argv) > 1 else ""
    if not vid:
        print("用法: 实测TV播放链路.py <videoId>")
        print("  videoId 可以是 vid（如 XNTkzNDc4MDI2OA==）或 fileId")
        return

    uuid = "A1B2C3D4E5F60718293A4B5C6D7E8F90"
    for host in HOSTS:
        print("=" * 70)
        print(f"host = {host}")
        c = Client(host)
        print("  prime:", c.prime())
        for style in ("h5", "h5_secret", "native", "native2"):
            data = jstr({"videoId": vid, "systemInfo": make_system_info(uuid)})
            resp = c.call(data, style)
            print(f"  [{style:10s}] {brief(resp)}")
            if resp.get("ret") and any(
                    str(x).startswith("SUCCESS") for x in (resp["ret"] if isinstance(resp["ret"], list) else [resp["ret"]])):
                print("  ★ 命中！完整响应：")
                print(json.dumps(resp, ensure_ascii=False, indent=2)[:4000])
                return


if __name__ == "__main__":
    main()
