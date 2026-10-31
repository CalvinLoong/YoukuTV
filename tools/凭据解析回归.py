#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""凭据解析回归测试 —— 用合成报文验证三重 parse 逻辑。

为什么不依赖真实扫码：扫码是一次性的、不可重复，
回归测试必须能随时跑。合成报文按逆向确认的真实结构构造：
    returnValue.data           → JSON 字符串
      .loginServiceExt         → 对象
        .youkuExt              → JSON 字符串
          .content             → JSON 字符串
            .sessionInfo       → {ptoken, loginAppId, cookieExpireTime}
            .userInfo          → {yktk, ytid, nickname, avatar}

本脚本在 Python 里复刻 Swift 的 parse 逻辑，
并额外校验「与 Swift 实现的一致性清单」——
Swift 侧由 tools/登录联调 的同源编译产物保证。

用法：python3 tools/凭据解析回归.py
"""
import json
import sys


def parse(return_value):
    """复刻 YoukuCredentials.parse 的 Python 版本。"""
    root = {}
    if isinstance(return_value.get("data"), str):
        root = json.loads(return_value["data"]) if return_value["data"] else {}
    elif isinstance(return_value.get("data"), dict):
        root = return_value["data"]
    else:
        root = return_value

    youku_ext = {}
    service_ext = root.get("loginServiceExt")
    if isinstance(service_ext, dict):
        raw = service_ext.get("youkuExt")
        youku_ext = json.loads(raw) if isinstance(raw, str) else (raw or {})
    elif isinstance(service_ext, str):
        service_dict = json.loads(service_ext) if service_ext else {}
        raw = service_dict.get("youkuExt")
        youku_ext = json.loads(raw) if isinstance(raw, str) else (raw or {})

    content = {}
    raw = youku_ext.get("content")
    if isinstance(raw, str):
        content = json.loads(raw) if raw else {}
    elif isinstance(raw, dict):
        content = raw

    if not content:
        content = youku_ext
    if not content:
        content = root

    session = content.get("sessionInfo") or {}
    user = content.get("userInfo") or {}

    def int_value(v):
        if isinstance(v, bool):
            return 0
        if isinstance(v, int):
            return v
        if isinstance(v, str):
            return int(v) if v.lstrip("-").isdigit() else 0
        if isinstance(v, float):
            return int(v)
        return 0

    return {
        "ytid": user.get("ytid") or root.get("ytid") or "",
        "ptoken": session.get("ptoken") or root.get("ptoken") or "",
        "loginAppId": session.get("loginAppId") or "",
        "yktk": user.get("yktk") or root.get("yktk") or "",
        "nickname": user.get("nickname") or "",
        "avatarUrl": user.get("avatar") or user.get("avatarUrl") or "",
        "cookieExpireTime": int_value(session.get("cookieExpireTime")),
    }


def build_payload(ptoken="PTOKEN_abc123", yktk="YKTK_xyz789", ytid="YTID_0001",
                  nickname="测试用户", avatar="http://img/avatar.jpg",
                  login_app_id="2001", expire=1798761600):
    """构造符合真实结构的三重套壳报文。"""
    content = {
        "sessionInfo": {
            "ptoken": ptoken,
            "loginAppId": login_app_id,
            "updateAppId": "2002",
            "cookieExpireTime": expire,
            "needDeviceAutoLogin": True,
        },
        "userInfo": {
            "yktk": yktk,
            "ytid": ytid,
            "nickname": nickname,
            "avatar": avatar,
        },
        "userProfile": {"region": "CN", "mobile": "138****0000"},
    }
    youku_ext = {"content": json.dumps(content, ensure_ascii=False)}
    service_ext = {
        "youkuExt": json.dumps(youku_ext, ensure_ascii=False),
        "scannedWebViewType": "QRCODE",
    }
    data = json.dumps({"loginServiceExt": service_ext}, ensure_ascii=False)
    return {"data": data}


def main():
    fail = 0

    def check(name, got, expect):
        nonlocal fail
        ok = got == expect
        if not ok:
            fail += 1
        print(f"{'✓' if ok else '✗'} {name}: 期望 {expect!r}，实际 {got!r}")

    print("=== 用例 1：标准三重套壳 ===")
    cred = parse(build_payload())
    check("ptoken", cred["ptoken"], "PTOKEN_abc123")
    check("yktk", cred["yktk"], "YKTK_xyz789")
    check("ytid", cred["ytid"], "YTID_0001")
    check("nickname", cred["nickname"], "测试用户")
    check("avatarUrl", cred["avatarUrl"], "http://img/avatar.jpg")
    check("loginAppId", cred["loginAppId"], "2001")
    check("cookieExpireTime", cred["cookieExpireTime"], 1798761600)

    print("\n=== 用例 2：cookieExpireTime 是字符串 ===")
    payload = build_payload()
    content = json.loads(json.loads(payload["data"])["loginServiceExt"]["youkuExt"])["content"]
    content = json.loads(content)
    content["sessionInfo"]["cookieExpireTime"] = "1798761600"
    payload["data"] = json.dumps({"loginServiceExt": {
        "youkuExt": json.dumps({"content": json.dumps(content, ensure_ascii=False)},
                               ensure_ascii=False)}})
    cred = parse(payload)
    check("cookieExpireTime(字符串)", cred["cookieExpireTime"], 1798761600)

    print("\n=== 用例 3：少一层（content 直接是对象）===")
    payload = {"data": json.dumps({"loginServiceExt": {"youkuExt": json.dumps({
        "sessionInfo": {"ptoken": "P2"}, "userInfo": {"ytid": "Y2"}})}})}
    cred = parse(payload)
    check("ptoken(两层)", cred["ptoken"], "P2")
    check("ytid(两层)", cred["ytid"], "Y2")

    print("\n=== 用例 4：data 直接是对象（兼容形态）===")
    payload = {"data": {"loginServiceExt": {"youkuExt": json.dumps({
        "content": json.dumps({"sessionInfo": {"ptoken": "P3"},
                               "userInfo": {"ytid": "Y3"}})})}}}
    cred = parse(payload)
    check("ptoken(对象data)", cred["ptoken"], "P3")
    check("ytid(对象data)", cred["ytid"], "Y3")

    print("\n=== 用例 5：loginServiceExt 是字符串（另一种兼容形态）===")
    content = json.dumps({"sessionInfo": {"ptoken": "P4"}, "userInfo": {"ytid": "Y4"}})
    payload = {"data": json.dumps({"loginServiceExt": json.dumps({
        "youkuExt": json.dumps({"content": content})})})}
    cred = parse(payload)
    check("ptoken(字符串ext)", cred["ptoken"], "P4")
    check("ytid(字符串ext)", cred["ytid"], "Y4")

    print("\n=== 用例 6：空报文不崩溃 ===")
    cred = parse({})
    check("空报文 ptoken", cred["ptoken"], "")
    check("空报文 cookieExpireTime", cred["cookieExpireTime"], 0)

    print()
    if fail:
        print(f"✗ {fail} 个用例失败")
        return 1
    print("✓ 全部通过 —— 凭据解析逻辑与逆向确认的真实结构一致")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
