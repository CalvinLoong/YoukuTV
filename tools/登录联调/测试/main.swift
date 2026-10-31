import Foundation

/// 凭据解析的 Swift 侧回归测试。
///
/// 与 `tools/凭据解析回归.py` 跑同一批用例 ——
/// 两边逻辑必须一致，否则「Python 测过、App 里还是错的」。
///
/// 用法：bash tools/登录联调/跑测试.sh
///
/// 注意：本文件必须叫 `main.swift` ——
/// Swift 多文件编译时，顶层表达式只允许出现在 main.swift 里。

// MARK: - 测试用例

struct Case {
    let name: String
    let payload: [String: Any]
    let expect: [String: String]   // 字段名 → 期望值
}

func buildPayload(
    ptoken: String = "PTOKEN_abc123",
    yktk: String = "YKTK_xyz789",
    ytid: String = "YTID_0001",
    nickname: String = "测试用户",
    avatar: String = "http://img/avatar.jpg",
    loginAppId: String = "2001",
    expire: Any = 1798761600
) -> [String: Any] {
    let content: [String: Any] = [
        "sessionInfo": [
            "ptoken": ptoken,
            "loginAppId": loginAppId,
            "updateAppId": "2002",
            "cookieExpireTime": expire,
            "needDeviceAutoLogin": true,
        ],
        "userInfo": [
            "yktk": yktk,
            "ytid": ytid,
            "nickname": nickname,
            "avatar": avatar,
        ],
        "userProfile": ["region": "CN", "mobile": "138****0000"],
    ]
    let youkuExt: [String: Any] = ["content": YoukuLoginClient.jsonString(content)]
    let serviceExt: [String: Any] = [
        "youkuExt": YoukuLoginClient.jsonString(youkuExt),
        "scannedWebViewType": "QRCODE",
    ]
    let data: [String: Any] = ["loginServiceExt": serviceExt]
    return ["data": YoukuLoginClient.jsonString(data)]
}

var cases: [Case] = []

// 用例 1：标准三重套壳
cases.append(Case(
    name: "标准三重套壳",
    payload: buildPayload(),
    expect: [
        "ptoken": "PTOKEN_abc123", "yktk": "YKTK_xyz789", "ytid": "YTID_0001",
        "nickname": "测试用户", "avatarUrl": "http://img/avatar.jpg",
        "loginAppId": "2001", "cookieExpireTime": "1798761600",
    ]
))

// 用例 2：cookieExpireTime 是字符串
cases.append(Case(
    name: "cookieExpireTime 是字符串",
    payload: buildPayload(expire: "1798761600"),
    expect: ["cookieExpireTime": "1798761600"]
))

// 用例 3：少一层（content 直接是对象）
cases.append(Case(
    name: "少一层（content 直接是对象）",
    payload: ["data": YoukuLoginClient.jsonString([
        "loginServiceExt": ["youkuExt": YoukuLoginClient.jsonString([
            "sessionInfo": ["ptoken": "P2"], "userInfo": ["ytid": "Y2"],
        ])],
    ])],
    expect: ["ptoken": "P2", "ytid": "Y2"]
))

// 用例 4：data 直接是对象
cases.append(Case(
    name: "data 直接是对象",
    payload: ["data": [
        "loginServiceExt": ["youkuExt": YoukuLoginClient.jsonString([
            "content": YoukuLoginClient.jsonString([
                "sessionInfo": ["ptoken": "P3"], "userInfo": ["ytid": "Y3"],
            ]),
        ])],
    ]],
    expect: ["ptoken": "P3", "ytid": "Y3"]
))

// 用例 5：loginServiceExt 是字符串
cases.append(Case(
    name: "loginServiceExt 是字符串",
    payload: ["data": YoukuLoginClient.jsonString([
        "loginServiceExt": YoukuLoginClient.jsonString([
            "youkuExt": YoukuLoginClient.jsonString([
                "content": YoukuLoginClient.jsonString([
                    "sessionInfo": ["ptoken": "P4"], "userInfo": ["ytid": "Y4"],
                ]),
            ]),
        ]),
    ])],
    expect: ["ptoken": "P4", "ytid": "Y4"]
))

// 用例 6：空报文不崩溃
cases.append(Case(
    name: "空报文不崩溃",
    payload: [:],
    expect: ["ptoken": "", "yktk": "", "ytid": "", "cookieExpireTime": "0"]
))

// MARK: - 执行

var failures = 0
print("=== Swift 凭据解析回归测试 ===\n")

for testCase in cases {
    print("── \(testCase.name)")
    let cred = YoukuCredentials.parse(testCase.payload)
    let actual: [String: String] = [
        "ptoken": cred.ptoken,
        "yktk": cred.yktk,
        "ytid": cred.ytid,
        "nickname": cred.nickname,
        "avatarUrl": cred.avatarUrl,
        "loginAppId": cred.loginAppId,
        "cookieExpireTime": String(cred.cookieExpireTime),
    ]
    for (key, want) in testCase.expect.sorted(by: { $0.key < $1.key }) {
        let got = actual[key] ?? "<nil>"
        let ok = got == want
        if !ok { failures += 1 }
        print("   \(ok ? "✓" : "✗") \(key): 期望 \(want)，实际 \(got)")
    }
    print("")
}

if failures > 0 {
    print("✗ \(failures) 个断言失败")
    exit(1)
}
print("✓ 全部通过 —— Swift 实现的凭据解析与逆向确认的真实结构一致")
