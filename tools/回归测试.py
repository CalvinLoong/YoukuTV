#!/usr/bin/env python3
"""YoukuTV 全链路回归测试。

用真实网络数据复刻 App 的完整流程，逐环节验证：
    搜索 → 过滤外站/损坏内容 → 详情 → 剧集列表 → 播放地址

用法:
    python3 tools/回归测试.py              # 测默认关键词
    python3 tools/回归测试.py 三体 甄嬛传     # 测指定关键词

返回码: 0 = 全部通过, 1 = 有失败项
"""
import http.cookiejar
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120 Safari/537.36")

AK = "24679788"
HOST = "un-acs.youku.com"
API = "mtop.youku.play.ups.appinfo.get"
API_VER = "1.1"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CREDENTIAL_SOURCE = os.path.join(ROOT, "YoukuTV", "Sources", "YoukuUpsClient.swift")

DEFAULT_KEYWORDS = ["甄嬛传", "庆余年", "三体", "动物世界"]


# ---------------------------------------------------------------- 凭据

def read_credential() -> dict:
    """从 App 源码里读出内置凭据（与 App 实际使用的完全一致）。"""
    with open(CREDENTIAL_SOURCE, encoding="utf-8") as fh:
        src = fh.read()

    def grab(pattern: str) -> str:
        m = re.search(pattern, src)
        return m.group(1) if m else ""

    return {
        "ckey": grab(r'ckey: "([^"]*)"'),
        "utid": grab(r'utid: "([^"]*)"'),
        "encryptR": grab(r'encryptRClient: "([^"]*)"'),
    }


# ---------------------------------------------------------------- 搜索

def is_valid_show_id(show_id: str) -> bool:
    """校验 showId。

    优酷正常 showId 是 20 位小写十六进制。
    注意 `efbfbd` 本身是合法 hex 序列，必须显式排除（服务端数据污染）。
    """
    if len(show_id) != 20:
        return False
    if "efbfbd" in show_id:
        return False
    return all(c in "0123456789abcdef" for c in show_id)


def search(keyword: str) -> list:
    """调用优酷 H5 搜索接口，返回过滤后的有效条目。"""
    url = "https://search.youku.com/api/search?" + urllib.parse.urlencode(
        {"keyword": keyword, "page": 1})
    req = urllib.request.Request(
        url, headers={"User-Agent": UA, "Referer": "https://so.youku.com/"})
    raw = urllib.request.urlopen(req, timeout=25).read()
    data = json.loads(raw.decode("utf-8", "ignore"))

    results = []
    for comp in data.get("pageComponentList") or []:
        cd = comp.get("commonData") or {}
        title = (cd.get("titleDTO") or {}).get("displayName")
        show_id = cd.get("showId") or ""
        if not title:
            continue
        # 只保留优酷自有内容（外站内容的 showId 会跳到不相干的节目）
        if cd.get("isYouku") != 1:
            continue
        if not is_valid_show_id(show_id):
            continue
        # leftButtonDTO.action.value 里带着可直接播放的 vid
        # （关键：优酷的 HTML 播放页有风控，搜索接口是纯 JSON 不受影响）
        button = cd.get("leftButtonDTO") or {}
        action = button.get("action") or {}
        url = action.get("value") or ""
        vid = ""
        if "/v_show/id_" in url:
            rest = url.split("/v_show/id_", 1)[1]
            vid = rest.split(".")[0] if "." in rest else ""

        icon = (cd.get("posterDTO") or {}).get("iconCorner") or {}
        results.append({
            "title": title,
            "showId": show_id,
            "videoId": vid,
            "badge": icon.get("tagText") or "",
            "source": cd.get("sourceName") or "优酷",
            "episodeTotal": cd.get("episodeTotal") or 0,
        })
    return results


# ---------------------------------------------------------------- 详情 / 剧集

def detail(show_id: str, tries: int = 2) -> dict:
    """从 H5 播放页解析节目详情与剧集列表。

    注意两个实测坑：
    1. 请求**不能带 Referer**，否则服务端只返回 1.5KB 骨架页（无 SSR 数据）
    2. SSR 数据是**间歇性**返回的（同 URL 8 次只有 2 次带完整数据），
       所以要重试
    """
    url = f"https://list.youku.com/show/id_{show_id}.html"
    html = None
    for attempt in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        resp = urllib.request.urlopen(req, timeout=25)
        body = resp.read().decode("utf-8", "ignore")
        if "__INITIAL_DATA__" in body:
            html = body
            break
        time.sleep(0.6 * (attempt + 1))

    if html is None:
        # 兜底：跳转 URL 里一定有 vid
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        resp = urllib.request.urlopen(req, timeout=25)
        m = re.search(r"/v_show/id_([^.?]+)\.html", resp.url)
        return {
            "videoId": m.group(1) if m else "",
            "showName": "",
            "episodeTotal": 0,
            "episodes": [],
            "hasEpisodeList": False,
        }

    marker = re.search(r"__INITIAL_DATA__\s*=\s*", html)
    if not marker:
        raise RuntimeError("页面结构已变更（找不到 __INITIAL_DATA__）")
    rest = html[marker.end():]

    # 按括号配对截取 JSON
    depth = 0
    end = None
    for i, ch in enumerate(rest):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise RuntimeError("页面结构已变更（JSON 未闭合）")

    root = json.loads(rest[:end].rstrip().rstrip(";"))
    extra = (root.get("pageMap") or {}).get("extra") or {}

    episodes = []
    for module in root.get("moduleList") or []:
        for comp in module.get("components") or []:
            if comp.get("type") != 10013:      # 选集组件
                continue
            for item in comp.get("itemList") or []:
                vid = item.get("action_value") or ""
                if not vid:
                    continue
                info = item.get("episodeInfo") or {}
                # 实测：benefitType 0 与 1 均可正常播放；5 才是会员内容
                episodes.append({
                    "index": item.get("stage") or item.get("stageIndex") or len(episodes) + 1,
                    "title": item.get("title") or "",
                    "vid": vid,
                    "isVip": (info.get("benefitType") or 0) == 5,
                })

    return {
        "videoId": extra.get("videoId") or "",
        "showName": extra.get("showName") or "",
        "episodeTotal": extra.get("episodeTotal") or 0,
        "episodes": episodes,
        "hasEpisodeList": bool(episodes),
    }


# ---------------------------------------------------------------- 播放地址

class UpsClient:
    """ups 播放接口客户端（复刻 YoukuUpsClient 的请求逻辑）。"""

    def __init__(self, credential: dict):
        self.credential = credential
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar))
        self.token = ""
        self._prime()

    def _prime(self) -> None:
        try:
            self.opener.open(
                urllib.request.Request(
                    f"https://{HOST}/h5/{API}/{API_VER}/?appKey={AK}",
                    headers={"User-Agent": UA}),
                timeout=20).read()
        except Exception:
            pass
        for c in self.jar:
            if c.name == "_m_h5_tk":
                self.token = c.value.split("_")[0]
                break

    def playback(self, vid: str, show_id: str) -> list:
        steal = {
            "ccode": "0502",
            "utid": self.credential["utid"],
            "version": "9.22.2",
            "ckey": self.credential["ckey"],
            "client_ip": "0.0.0.0",
            "client_ts": str(int(time.time())),
        }
        biz = {
            "vid": vid, "local_vid": vid, "h265": 1,
            "current_showid": show_id, "preferClarity": -1,
            "media_type": "standard,subtitle", "app_ver": "9.22.2",
            "extag": "EXT-X-PRIVINF", "play_ability": 2164266240,
            "close_ability": 655360, "master_m3u8": 1, "drm_type": 3,
            "key_index": "web01", "encryptR_client": self.credential["encryptR"],
            "enc_ver": 2, "pn": "com.youku.pcweb", "playMode": "normal",
        }
        ad = {
            "vs": "1.0", "pver": "9.22.2", "sver": "2.0", "site": 1, "aw": "w",
            "fu": 0, "d": 0, "bt": "pc", "os": "mac", "partnerid": "null",
            "wintype": "interior", "isvert": 0, "vip": 0, "emb": 0, "p": 1,
            "rst": "mp4", "needbf": 2, "avs": "1.0", "needad": 1,
        }
        data = {"steal_params": steal, "biz_params": biz, "ad_params": ad}
        payload = json.dumps(data, separators=(",", ":"), ensure_ascii=False)

        t = str(int(time.time() * 1000))
        sign = hashlib.md5(f"{self.token}&{t}&{AK}&{payload}".encode()).hexdigest()
        params = {
            "jsv": "2.6.1", "appKey": AK, "t": t, "sign": sign,
            "api": API, "v": API_VER, "timeout": "15000",
            "type": "jsonp", "dataType": "jsonp", "callback": "mtopjsonp1",
            "data": payload,
        }
        url = f"https://{HOST}/h5/{API}/{API_VER}/?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(
            url, headers={"User-Agent": UA, "Referer": "https://v.youku.com/"})
        body = self.opener.open(req, timeout=25).read().decode("utf-8", "ignore")

        m = re.match(r"^\s*\w+\((.*)\)\s*;?$", body.strip(), re.S)
        parsed = json.loads(m.group(1)) if m else json.loads(body)
        inner = parsed.get("data") or {}
        return (inner.get("data") or {}).get("stream") or []


# ---------------------------------------------------------------- 主流程

def run(keywords: list) -> int:
    cred = read_credential()
    if not cred["ckey"] or not cred["utid"]:
        print("✗ 无法从源码读出内置凭据")
        return 1

    print("═" * 62)
    print(" YoukuTV 全链路回归测试")
    print("═" * 62)
    print(f"凭据: ckey {len(cred['ckey'])} 字符 | utid {cred['utid']}")
    print()

    client = UpsClient(cred)
    if not client.token:
        print("✗ 拿不到 _m_h5_tk token")
        return 1

    failures = 0
    for keyword in keywords:
        print(f"【{keyword}】")
        try:
            items = search(keyword)
        except Exception as exc:
            print(f"  ✗ 搜索失败: {str(exc)[:70]}")
            failures += 1
            continue

        if not items:
            print("  ✗ 没有有效结果（全部被过滤或接口无数据）")
            failures += 1
            continue
        print(f"  搜索: {len(items)} 条有效结果")

        for item in items[:3]:
            print(f"  ▸ {item['title'][:20]:22} 源={item['source']:4} "
                  f"{item['episodeTotal']:3}集 [{item['badge'] or '免费'}]")

            # ---- 主路径：用搜索接口直出的 vid 播放（不碰 HTML，无风控）----
            if item["videoId"]:
                streams = client.playback(item["videoId"], item["showId"])
                if streams:
                    types = [s.get("stream_type") for s in streams]
                    print(f"    ✓ 直出vid 可播 → {len(streams)} 条地址 {types[:4]}")
                else:
                    badge = item["badge"]
                    if badge in ("VIP", "付费"):
                        print(f"    ○ 直出vid 无地址（{badge}内容，预期行为）")
                    else:
                        print(f"    ✗ 直出vid 取不到地址 ← 异常")
                        failures += 1
            else:
                print("    ○ 搜索结果未带 vid（需靠详情页解析）")

            # ---- 补充路径：HTML 播放页解析选集（可选，可能被风控）----
            try:
                det = detail(item["showId"])
            except Exception as exc:
                print(f"    · 选集解析失败（不影响播放）: {str(exc)[:40]}")
                continue

            eps = det["episodes"]
            if not eps:
                print("    · 无选集列表")
                continue

            free = [e for e in eps if not e["isVip"]]
            vip = [e for e in eps if e["isVip"]]
            print(f"    · 选集 {len(eps)} 集（免费 {len(free)} / 会员 {len(vip)}）")

            # 抽测：第 1 集 + 中间一集
            picks = [eps[0]]
            if len(eps) > 3:
                picks.append(eps[len(eps) // 2])

            for ep in picks:
                streams = client.playback(ep["vid"], item["showId"])
                tag = "会员" if ep["isVip"] else "免费"
                if streams:
                    types = [s.get("stream_type") for s in streams]
                    print(f"    ✓ 第{ep['index']}集[{tag}] {len(streams)} 条地址 {types[:4]}")
                else:
                    if ep["isVip"]:
                        print(f"    ○ 第{ep['index']}集[{tag}] 无地址（会员内容，预期行为）")
                    else:
                        print(f"    ✗ 第{ep['index']}集[{tag}] 免费内容却取不到地址 ← 异常")
                        failures += 1
        print()

    print("═" * 62)
    if failures:
        print(f"✗ {failures} 项异常")
        return 1
    print("✓ 全部通过（免费内容可播；会员内容按设计不可用）")
    return 0


def main() -> int:
    keywords = sys.argv[1:] or DEFAULT_KEYWORDS
    return run(keywords)


if __name__ == "__main__":
    raise SystemExit(main())
