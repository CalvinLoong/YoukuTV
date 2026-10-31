#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探针：完整复刻 App 端的 ups 取流链路，实测每一步返回什么。

目的：定位「视频进入后无法播放」的真实失败点。
逐段验证：
  1. 搜索接口能否拿到 vid
  2. ups 接口能否拿到 stream（免费内容）
  3. m3u8 地址本身能否用 curl 拉通（带/不带请求头）
  4. 主播放列表(auto)内容里的 URI 是绝对还是相对
"""
import hashlib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
import http.cookiejar

APP_KEY = "24679788"
HOST = "un-acs.youku.com"
API = "mtop.youku.play.ups.appinfo.get"
VERSION = "1.1"
TTID = "123@tvhomeshell_yunos_1.0.0"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CKEY = ("140#o8foFD6ezzWioQo2+bhu4pN8s9DfVoO52wuS/WRX/zGIMrMVf7dtiRzmxLATDWpY4FiWlp1zzRn0a2/SGFzxSx8za3h/zzrb22U3lp1xzCQiVXE/tFzx2Dc33b/BeHmijDapVrMn3rNmgkYEG5R5hPU4n8fKJKz0pKziPLYJIk1oX2QDQBoq3uz3pNJtDTp+wlAAJzY7a7oluQAA9ORe8Sk54uGspJd4oAqJKt6+jyGmx7j1Q/exmOk1UNGBkAOA80quTu/lBy2YR2j+9gFgjrHwuZVlN2162HflgwbOoyP/9DDGY60zrA6QEmMT+J7aVaXv+sUoBtcHXL7wyk0Hn9oTOcR8nqH9VTCfDHIHXLSYitT+OtVps49ybWAYQ/3LR0tOzh14nuweR69asPm0QRbSwqtEOzQ68vkO+1K6ieM509aqaxu8dQIwSxf5b95zz6m/dMDdEBKRba/sGR9LqDebjhcf5nT6WuSdeNJFOXWmWa9myBdjrWObmaEopgMYRWcxQJnfmnEN7vqdhwIPeQ3ExmrriutZ3aZh6uSuaOEDr+ZhNvY38yaDg/4E5v8gJ4CbQmY37wSnz3Py2R5Qvl4hIHEUXsFkicYkff82iTrfGSYQF8/s4tG7ZSr1fzcYPbZITZIjwiaJ+UWbcSy5nB+WG7afir+ULOCB6F/bcf0py5mgUyM5JodiH8vRFNgD3ElWpr5CBMXTarIhmbB57QSphuaGCdSJ8ki+TV+PtpsHUbviG6UVUopMeQxNcyeMkN0ddgdNFgC3huHE")
UTID = "Dg5qI8+GsDsCAavdUaZcHoaR"
ENCRYPT = "+UklxYpCot0pHeJOAcTh4A=="

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def cookies():
    return {c.name: c.value for c in jar}


def token():
    v = cookies().get("_m_h5_tk", "")
    return v.split("_")[0][:32] if v else ""


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def jstr(o):
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False)


def strip_jsonp(text):
    m = re.search(r"^[^(]*\((.*)\)\s*;?\s*$", text, re.S)
    return m.group(1) if m else text


def ups(vid, show_id="", prefer_clarity=-1, play_ability=2164266240,
        close_ability=655360, master_m3u8=1):
    now = int(time.time())
    steal = {"ccode": "0502", "utid": UTID, "version": "9.22.2", "ckey": CKEY,
             "client_ip": "192.168.1.1", "client_ts": str(now)}
    biz = {"vid": vid, "local_vid": vid, "h265": 1, "preferClarity": prefer_clarity,
           "media_type": "standard,subtitle", "app_ver": "9.22.2",
           "extag": "EXT-X-PRIVINF", "play_ability": play_ability,
           "close_ability": close_ability, "master_m3u8": master_m3u8,
           "drm_type": 3, "key_index": "web01", "encryptR_client": ENCRYPT,
           "skh": 1, "start_point_ms": 0, "last_clarity": -1, "wdm": 1,
           "pn": "com.youku.pcweb", "playMode": "normal", "enc_ver": 2,
           "local_time": str(now)}
    if show_id:
        biz["current_showid"] = show_id
    ad = {"vs": "1.0", "pver": "9.22.2", "sver": "2.0", "site": 1, "aw": "w",
          "fu": 0, "d": 0, "bt": "pc", "os": "mac", "osv": "", "dq": "auto",
          "atm": "", "partnerid": "null", "wintype": "interior", "isvert": 0,
          "vip": 0, "p": 1, "rst": "mp4", "needbf": 2, "avs": "1.0", "needad": 1}
    data = jstr({"steal_params": jstr(steal), "biz_params": jstr(biz),
                 "ad_params": jstr(ad)})

    if not token():
        prime = (f"https://{HOST}/h5/{API}/{VERSION}/?"
                 f"appKey={APP_KEY}&api={API}&v={VERSION}")
        try:
            opener.open(urllib.request.Request(prime, headers={"User-Agent": UA}),
                        timeout=20).read()
        except Exception as e:
            print("  prime 失败:", e)

    t = str(int(time.time() * 1000))
    sign = md5(f"{token()}&{t}&{APP_KEY}&{data}")
    params = {"jsv": "2.6.1", "appKey": APP_KEY, "t": t, "sign": sign, "api": API,
              "v": VERSION, "timeout": "15000", "type": "jsonp",
              "dataType": "jsonp", "callback": "mtopjsonp1", "data": data,
              "ttid": TTID}
    url = f"https://{HOST}/h5/{API}/{VERSION}/?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "User-Agent": UA, "Referer": "https://v.youku.com/",
        "Accept": "application/json, text/plain, */*"})
    try:
        with opener.open(req, timeout=25) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
    except Exception as e:
        return {"_error": str(e)}
    try:
        return json.loads(strip_jsonp(raw))
    except Exception:
        return {"_raw": raw[:800]}


def search_vid(keyword):
    url = ("https://search.youku.com/api/search?keyword="
           + urllib.parse.quote(keyword) + "&page=1")
    req = urllib.request.Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (Apple TV; CPU like Mac OS X) "
                       "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                       "Version/17.0 Safari/605.1.15"),
        "Referer": "https://so.youku.com/"})
    with opener.open(req, timeout=20) as resp:
        root = json.loads(resp.read().decode("utf-8", "replace"))
    out = []
    for comp in root.get("pageComponentList") or []:
        cd = comp.get("commonData") or {}
        if cd.get("isYouku") != 1:
            continue
        btn = (cd.get("leftButtonDTO") or {}).get("action") or {}
        u = btn.get("value") or ""
        m = re.search(r"/v_show/id_([^.]+)\.html", u)
        if m:
            title = (cd.get("titleDTO") or {}).get("displayName") or ""
            badge = ((cd.get("posterDTO") or {}).get("iconCorner") or {}).get("tagText") or ""
            out.append((m.group(1), title, badge))
    return out


def fetch_m3u8(url, label):
    for name, hdrs in (("带UA+Referer", {"User-Agent": UA,
                                         "Referer": "https://v.youku.com/"}),
                       ("仅UA", {"User-Agent": UA}),
                       ("无头", {})):
        try:
            req = urllib.request.Request(url, headers=hdrs)
            with opener.open(req, timeout=20) as resp:
                body = resp.read()
            print(f"  [{label}/{name}] HTTP {resp.status}, {len(body)} bytes, "
                  f"前80字符: {body[:80]!r}")
            return body
        except urllib.error.HTTPError as e:
            print(f"  [{label}/{name}] HTTP {e.code}")
        except Exception as e:
            print(f"  [{label}/{name}] 失败: {type(e).__name__} {e}")
    return None


if __name__ == "__main__":
    keyword = sys.argv[1] if len(sys.argv) > 1 else "三体"
    print(f"=== 1. 搜索「{keyword}」取 vid ===")
    try:
        hits = search_vid(keyword)
    except Exception as e:
        print("搜索失败:", e)
        hits = []
    for vid, title, badge in hits[:6]:
        print(f"  vid={vid}  {title}  [{badge}]")
    if not hits:
        print("没有可用 vid，退出")
        sys.exit(1)

    vid, title, badge = hits[0]
    print(f"\n=== 2. ups 取流（vid={vid} {title}）===")
    resp = ups(vid)
    if "_error" in resp or "_raw" in resp:
        print(json.dumps(resp, ensure_ascii=False)[:800])
        sys.exit(1)
    print("  ret =", resp.get("ret"))
    data = resp.get("data") or {}
    streams = data.get("stream") or []
    print(f"  stream 条数 = {len(streams)}")
    for s in streams:
        raw = s.get("m3u8_url") or ""
        kind = "PLAINLIST" if raw.startswith("#EXTM3U") else "URL"
        print(f"  - type={s.get('stream_type')} {s.get('width')}x{s.get('height')} "
              f"[{kind}] {raw[:110]}")

    if not streams:
        print("  没有 stream —— 这是「无法播放」的根因")
        print("  data keys =", list(data.keys()))
        sys.exit(0)

    print("\n=== 3. 拉取真实 m3u8 ===")
    real = [s for s in streams if not (s.get("m3u8_url") or "").startswith("#EXTM3U")]
    if real:
        u = real[0]["m3u8_url"]
        body = fetch_m3u8(u, real[0].get("stream_type"))
        if body:
            print("  m3u8 内容前 400 字符:")
            print("  " + body[:400].decode("utf-8", "replace").replace("\n", "\n  "))

    print("\n=== 4. 主播放列表(auto)内容解析 ===")
    auto = [s for s in streams if (s.get("m3u8_url") or "").startswith("#EXTM3U")]
    for s in auto:
        content = s["m3u8_url"]
        norm = content.replace("\\r\\n", "\n").replace("\\n", "\n")
        lines = [l for l in norm.split("\n") if l.strip()]
        print(f"  auto 清单共 {len(lines)} 行，前 12 行:")
        for l in lines[:12]:
            print("   ", l[:130])
        uris = [l for l in lines if not l.startswith("#")]
        rel = [u for u in uris if not u.startswith("http")]
        print(f"  URI 总数 {len(uris)}，其中相对路径 {len(rel)} 个")
        if uris:
            print("  试拉第一个 URI:", uris[0][:120])
            fetch_m3u8(uris[0], "auto-child")
