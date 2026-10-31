#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
抓取并解析优酷网页首页的 `__INITIAL_DATA__`，用于摸清首页推荐模块结构。

实测要点：
1. 首页 SSR 也是**间歇性**返回的（同 URL 多次请求有时拿不到），必须重试。
2. `__INITIAL_DATA__` 里混了 JavaScript 的 `undefined`（如 `"PUM":undefined`），
   直接 JSON 解析会失败 —— 必须先把**字符串之外**的 `undefined` 替换成 `null`。
3. 不能带 Referer（服务端只对无 Referer + 常规浏览器 UA 做 SSR）。
"""
import json
import sys
import time
import urllib.request

UA = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}


def fetch_html(url="https://www.youku.com/", attempts=6):
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=25) as r:
                raw = r.read().decode("utf-8", "replace")
            if "__INITIAL_DATA__" in raw:
                return raw
            print(f"  第{i+1}次：{len(raw)} 字符，无 SSR 数据")
        except Exception as e:
            print(f"  第{i+1}次失败：{e}")
        time.sleep(1.0)
    return None


def extract_blob(raw):
    i = raw.index("__INITIAL_DATA__")
    start = raw.index("{", i)
    depth = 0
    end = None
    in_str = False
    esc = False
    for j in range(start, len(raw)):
        c = raw[j]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    return raw[start:end]


def strip_undefined(blob):
    """把字符串之外的 undefined 换成 null。"""
    out = []
    i = 0
    in_str = False
    esc = False
    while i < len(blob):
        c = blob[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if blob.startswith("undefined", i):
            out.append("null")
            i += 9
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load(url="https://www.youku.com/"):
    raw = fetch_html(url)
    if raw is None:
        raise SystemExit("多次重试仍拿不到 SSR 数据")
    blob = extract_blob(raw)
    clean = strip_undefined(blob)
    return json.loads(clean)


if __name__ == "__main__":
    d = load()
    with open("build/youku_home_ssr.json", "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    print("✓ 解析成功，顶层 keys:", list(d.keys()))

    ml = d.get("moduleList") or []
    print(f"moduleList: {len(ml)} 个")
    for idx, mod in enumerate(ml):
        for ci, comp in enumerate(mod.get("components") or []):
            items = comp.get("itemList") or []
            if not items:
                continue
            print(f"\n--- module[{idx}] {mod.get('typeName')} / comp[{ci}] "
                  f"{comp.get('typeName')} type={comp.get('type')} items={len(items)}")
            it = items[0]
            for k, v in it.items():
                s = json.dumps(v, ensure_ascii=False)
                if len(s) > 200:
                    s = s[:200] + "…"
                print(f"      {k} = {s}")

    nav = d.get("navList") or []
    print(f"\n=== navList: {len(nav)} 项 ===")
    for n in nav[:15]:
        print("  ", json.dumps(n, ensure_ascii=False)[:300])
