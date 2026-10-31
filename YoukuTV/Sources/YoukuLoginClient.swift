import Foundation
import CryptoKit

/// 优酷扫码登录客户端（Havana 链路）。
///
/// ## 逆向来源
///
/// 酷喵 TV APK 的 `com.youku.passport.data.UIHavanaComponent`：
/// - `genQrCodeThread()`（:165）→ 生成二维码
/// - `getRpcRequest()`（:241）→ 轮询登录结果
/// - `buildBaseLoginRequest()`（:71）→ tokenInfo 字段来源
/// - `RiskControlInfo.buildRiskControlInfo()`（:29）→ riskControlInfo 字段来源
///
/// ## 关键坑（实测得出，踩过才知道）
///
/// 1. **接口必须走 GET**，POST 会返回 HTTP 415。
/// 2. **tokenInfo 只能有 12 个字段**。APK 用 fastjson 序列化，
///    默认不开启 `WriteMapNullValue`，所以**所有 null 字段整个被省略**。
///    多传空字符串/null 字段会让服务端反序列化抛异常 →
///    返回 `FAIL_SYS_SERVICE_FAULT`（这是实测最难缠的一个错）。
/// 3. **tokenInfo.token 是 genQrCode 返回的 `returnValue.token` 整串**
///    （形如 `1ED6F9A2..._0000000`），不是 cookie `_m_h5_tk` 的 32 位。
///    签名用的 token 和 tokenInfo 里的 token 是两个不同的值。
/// 4. **字段类型要严格**：`site`/`t` 是数字，`useDeviceToken`/`useAcitonType` 是布尔。
///    写成字符串会导致类型转换失败。
/// 5. **轮询的 ext 要带 uuid**，而 genQrCode 的 ext 不带。
///
/// ## 状态码
///
/// - `14030` 未扫码（继续等）
/// - `14031` 已扫码，等待手机确认
/// - `3000` 登录成功，`returnValue` 里是凭据
actor YoukuLoginClient {
    // MARK: - 常量

    static let appKey = "23299685"
    static let host = "acs.youku.com"
    static let genQrCodeAPI = "mtop.taobao.commonuse.mloginService.genQrCode"
    static let qrCodeLoginAPI = "mtop.taobao.commonuse.mloginService.qrcodelogin"
    static let version = "1.0"
    static let sdkVersion = "android_4.8.2"
    static let ttid = "123@tvhomeshell_yunos_1.0.0"

    static let userAgent =
        "Mozilla/5.0 (Linux; Android 13; AppleTV Build/TQ3A.230805.001) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 "
        + "Chrome/120.0.0.0 Mobile Safari/537.36"

    // MARK: - 状态

    private var token: String = ""
    private var cookieStore: [String: String] = [:]
    private let session: URLSession

    /// 设备标识。服务端可能校验其合法性，但实测任意稳定值都能走通。
    private let utdid: String
    private let uuid: String

    init(utdid: String = YoukuLoginClient.makeDeviceId("utdid"),
         uuid: String = YoukuLoginClient.makeDeviceId("uuid")) {
        self.utdid = utdid
        self.uuid = uuid
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: config)
    }

    // MARK: - 公开 API

    /// 生成登录二维码。
    struct QRCode {
        /// 二维码内容（优酷短链），用户用手机优酷 App 扫这个。
        let url: String
        /// 轮询用的 token。
        let pollToken: String
        /// 建议的轮询间隔（毫秒）。
        let pollMilliseconds: Int
    }

    func generateQRCode() async throws -> QRCode {
        let qrInfo: [String: Any] = [
            "appName": Self.appKey,
            "callbackUrl": "",
            "ext": ["tlsite": "https://login.youku.com"],
            "qrCodeSize": 300,
            "sdkVersion": Self.sdkVersion,
            "site": 0,
            "utdid": utdid,
            "youkuProperty": "{}",
            "genShortUrl": true,
            "genQrImage": true
        ]

        let response = try await call(
            api: Self.genQrCodeAPI,
            data: [
                "qrCodeGenInfo": Self.jsonString(qrInfo),
                "riskControlInfo": Self.riskControlInfo,
                "appKey": Self.appKey,
                "ext": Self.jsonString(["appKey": Self.appKey])
            ]
        )

        guard let payload = response["data"] as? [String: Any] else {
            throw YoukuError.decodingFailed("登录接口未返回数据")
        }
        // code == 3000 表示生成成功
        //
        // ★ 坑：服务端返回的 code 是**字符串** "3000"，不是数字 3000。
        //   早期版本写成 `as? Int` 会静默失败得到 0，
        //   于是走进 error 分支报「二维码生成失败：成功」——一个自相矛盾的错误。
        //   JSONSerialization 不做类型转换，必须两种都试。
        let code = Self.intValue(payload["code"])
        guard code == 3000 else {
            let message = payload["message"] as? String ?? "未知错误"
            throw YoukuError.mtop("二维码生成失败：\(message)")
        }
        guard let returnValue = payload["returnValue"] as? [String: Any],
              let url = returnValue["qrCodeUrl"] as? String,
              let pollToken = returnValue["token"] as? String,
              !pollToken.isEmpty else {
            throw YoukuError.decodingFailed("二维码内容缺失")
        }

        let interval = returnValue["pollMilliseconds"] as? Int ?? 3000
        return QRCode(url: url, pollToken: pollToken, pollMilliseconds: interval)
    }

    /// 轮询登录状态。
    enum PollResult {
        /// 还没扫码。
        case waiting
        /// 已扫码，等用户在手机上确认。
        case scanned
        /// 登录成功，返回凭据。
        case success(YoukuCredentials)
    }

    func pollLogin(token pollToken: String) async throws -> PollResult {
        // ★ 严格 12 个字段，多一个少一个都会被服务端拒绝。
        //   依据：APK 用 fastjson 序列化，DEFAULT_GENERATE_FEATURE 未开启
        //   WriteMapNullValue，故所有 null 字段被整个省略。
        let tokenInfo: [String: Any] = [
            "appName": Self.appKey,
            "deviceName": "Apple(AppleTV)",
            "ext": ["uuid": uuid],
            "sdkVersion": Self.sdkVersion,
            "site": 0,
            "t": 0,
            "token": pollToken,
            "ttid": "",
            "useAcitonType": true,
            "useDeviceToken": true,
            "utdid": utdid
        ]

        let response = try await call(
            api: Self.qrCodeLoginAPI,
            data: [
                "tokenInfo": Self.jsonString(tokenInfo),
                "riskControlInfo": Self.riskControlInfo,
                "appKey": Self.appKey,
                "ext": Self.jsonString(["appKey": Self.appKey, "uuid": uuid])
            ]
        )

        guard let payload = response["data"] as? [String: Any] else {
            throw YoukuError.decodingFailed("轮询接口未返回数据")
        }

        let code = Self.intValue(payload["code"])
        switch code {
        case 14030:
            return .waiting
        case 14031:
            return .scanned
        case 3000:
            guard let returnValue = payload["returnValue"] as? [String: Any] else {
                throw YoukuError.decodingFailed("登录成功但未返回凭据")
            }
            lastReturnValue = returnValue
            return .success(YoukuCredentials.parse(returnValue))
        default:
            let message = payload["message"] as? String ?? "未知状态 \(code)"
            throw YoukuError.mtop("扫码登录失败：\(message)")
        }
    }

    /// 登录成功时服务端返回的原始 `returnValue`。
    ///
    /// 用途：凭据解析一旦对不上结构，用它对照真实结构，
    /// 不用再抓包重跑。App 里用不到，是给联调工具用的。
    private var lastReturnValue: [String: Any]?

    func lastRawReturnValue() -> [String: Any]? { lastReturnValue }

    // MARK: - 协议实现

    private func call(api: String, data: [String: Any]) async throws -> [String: Any] {
        let payload = Self.jsonString(data)

        if token.isEmpty {
            try await primeToken(api: api)
        }

        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Self.md5Hex("\(token)&\(timestamp)&\(Self.appKey)&\(payload)")

        var components = URLComponents(
            string: "https://\(Self.host)/h5/\(api)/\(Self.version)/"
        )!
        components.queryItems = [
            .init(name: "jsv", value: "2.6.1"),
            .init(name: "appKey", value: Self.appKey),
            .init(name: "t", value: timestamp),
            .init(name: "sign", value: sign),
            .init(name: "api", value: api),
            .init(name: "v", value: Self.version),
            .init(name: "timeout", value: "20000"),
            .init(name: "type", value: "jsonp"),
            .init(name: "dataType", value: "jsonp"),
            .init(name: "callback", value: "mtopjsonp1"),
            .init(name: "data", value: payload),
            .init(name: "ttid", value: Self.ttid)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://login.youku.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        applyCookies(to: &request)

        // 注意：这里必须用 GET。实测 POST 会返回 HTTP 415。
        let (body, response) = try await session.data(for: request)
        captureCookies(from: response)

        guard let http = response as? HTTPURLResponse else {
            throw YoukuError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw YoukuError.httpStatus(http.statusCode)
        }

        let text = String(data: body, encoding: .utf8) ?? ""
        guard let json = Self.stripJSONP(text) ?? (try? JSONSerialization.jsonObject(
            with: body
        ) as? [String: Any]) else {
            throw YoukuError.decodingFailed(text.prefix(200).description)
        }
        return json
    }

    /// 触发服务端下发 `_m_h5_tk`（签名的原料）。
    private func primeToken(api: String) async throws {
        var components = URLComponents(
            string: "https://\(Self.host)/h5/\(api)/\(Self.version)/"
        )!
        components.queryItems = [
            .init(name: "appKey", value: Self.appKey),
            .init(name: "api", value: api),
            .init(name: "v", value: Self.version)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        applyCookies(to: &request)
        if let (_, response) = try? await session.data(for: request) {
            captureCookies(from: response)
        }
        guard !token.isEmpty else {
            throw YoukuError.tokenUnavailable
        }
    }

    private func applyCookies(to request: inout URLRequest) {
        guard !cookieStore.isEmpty else { return }
        let value = cookieStore
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        request.setValue(value, forHTTPHeaderField: "Cookie")
    }

    private func captureCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, name.lowercased() == "set-cookie" else { continue }
            guard let raw = value as? String else { continue }
            for part in raw.components(separatedBy: ",") {
                let piece = part.trimmingCharacters(in: .whitespaces)
                guard let eq = piece.firstIndex(of: "=") else { continue }
                let cname = String(piece[piece.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                var cval = String(piece[piece.index(after: eq)...])
                if let semi = cval.firstIndex(of: ";") {
                    cval = String(cval[cval.startIndex..<semi])
                }
                guard !cname.isEmpty else { continue }
                cookieStore[cname] = cval
                if cname == "_m_h5_tk" {
                    let rawToken = cval.split(separator: "_").first.map(String.init) ?? cval
                    token = String(rawToken.prefix(32))
                }
            }
        }
    }

    // MARK: - 工具

    /// 风控信息。字段与 APK 的 `RiskControlInfo.buildRiskControlInfo()` 一致。
    private static let riskControlInfo: String = {
        let dict: [String: Any] = [
            "appStore": "",
            "bssid": "",
            "deviceBrand": "Apple",
            "deviceModel": "AppleTV",
            "deviceName": "AppleTV",
            "imei": "",
            "latitude": 0.0,
            "longitude": 0.0,
            "mac": "",
            "osName": "android",
            "osVersion": "13",
            "ottLicense": "1",
            "screenSize": "3840x2160",
            "ssid": "",
            "umidToken": ""
        ]
        return jsonString(dict)
    }()

    static func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 宽松地取整数值。
    ///
    /// mtop 的 `code` 字段在不同接口上类型不统一：
    ///   · Havana 登录接口 → 字符串 `"3000"`
    ///   · ups 播放接口   → 有时是数字 `3000`
    ///
    /// `JSONSerialization` 不做隐式类型转换，直接 `as? Int` 会静默失败。
    /// 历史上就因为这一点，扫码登录在 App 里必然失败
    /// （报「二维码生成失败：成功」这种自相矛盾的错）。
    static func intValue(_ raw: Any?) -> Int {
        switch raw {
        case let value as Int: return value
        case let value as String: return Int(value) ?? 0
        case let value as NSNumber: return value.intValue
        default: return 0
        }
    }

    static func stripJSONP(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = String(trimmed[trimmed.index(after: open)..<close])
        return try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any]
    }

    private static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 生成稳定的伪随机设备标识。
    ///
    /// 服务端不校验其真实性（实测任意稳定值都能走通），
    /// 但同一台设备每次启动必须用同一个值，否则会话会失效。
    private static func makeDeviceId(_ prefix: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: "youku.device.\(prefix)") {
            return saved
        }
        let seed = "\(prefix)-\(UUID().uuidString)"
        let hash = Insecure.MD5.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let value = "tv-\(prefix)-\(String(hash.prefix(16)))"
        UserDefaults.standard.set(value, forKey: "youku.device.\(prefix)")
        return value
    }
}

// MARK: - 凭据

/// 登录后拿到的账号凭据。
struct YoukuCredentials: Codable, Equatable {
    /// 用户标识
    let ytid: String
    /// 会话 ptoken
    let ptoken: String
    /// 登录 appId
    let loginAppId: String
    /// 用户令牌
    let yktk: String
    /// 昵称
    let nickname: String
    /// 头像
    let avatarUrl: String
    /// Cookie 过期时间戳
    let cookieExpireTime: Int

    /// 是否是有效的登录态
    var isValid: Bool { !ytid.isEmpty && !ptoken.isEmpty }

    /// 从 Havana 的 `returnValue` 解析凭据。
    ///
    /// ## 真实结构（逆向自 `HavanaDataHelper.processLoginReturnData`，
    /// `/tmp/km/jd/classes2/sources/com/youku/passport/utils/HavanaDataHelper.java:38`）
    ///
    /// 关键点：**`returnValue.data` 本身是一个 JSON 字符串**，不是对象。
    /// 整条链是**三重字符串套壳**，必须 parse 三次：
    ///
    /// ```
    /// returnValue                          ← LoginReturnData 对象
    /// └─ data                             ← ★ String！内容是 JSON 文本
    ///    └─ (parse 1) AliUserResponseData
    ///       ├─ loginServiceExt            ← Map<String,String>（对象，不是字符串）
    ///       │  └─ youkuExt                ← ★ String！内容是 JSON 文本
    ///       │     └─ (parse 2)
    ///       │        └─ content            ← ★ String！内容是 JSON 文本
    ///       │           └─ (parse 3)
    ///       │              ├─ sessionInfo  → ptoken / loginAppId / cookieExpireTime
    ///       │              └─ userInfo     → yktk / ytid / nickname / avatar
    /// ```
    ///
    /// 字段归属：
    /// - `sessionInfo.ptoken`、`sessionInfo.loginAppId`、`sessionInfo.cookieExpireTime`
    /// - `userInfo.yktk`、`userInfo.ytid`、`userInfo.nickname`、`userInfo.avatar`
    ///
    /// 注意 `cookieExpireTime` 是**秒级** epoch。
    static func parse(_ returnValue: [String: Any]) -> YoukuCredentials {
        // 第 0 层：returnValue.data 是字符串，parse 一次
        var root: [String: Any] = [:]
        if let dataString = returnValue["data"] as? String {
            root = (Self.jsonObject(dataString)) ?? [:]
        } else if let dataObject = returnValue["data"] as? [String: Any] {
            root = dataObject
        } else {
            root = returnValue
        }

        // 第 1 层：loginServiceExt 是对象；youkuExt 是字符串
        var youkuExt: [String: Any] = [:]
        if let serviceExt = root["loginServiceExt"] as? [String: Any] {
            if let raw = serviceExt["youkuExt"] as? String {
                youkuExt = Self.jsonObject(raw) ?? [:]
            } else if let obj = serviceExt["youkuExt"] as? [String: Any] {
                youkuExt = obj
            }
        } else if let serviceExtString = root["loginServiceExt"] as? String,
                  let serviceDict = Self.jsonObject(serviceExtString) {
            if let raw = serviceDict["youkuExt"] as? String {
                youkuExt = Self.jsonObject(raw) ?? [:]
            } else if let obj = serviceDict["youkuExt"] as? [String: Any] {
                youkuExt = obj
            }
        }

        // 第 2 层：content 是字符串
        var content: [String: Any] = [:]
        if let raw = youkuExt["content"] as? String {
            content = Self.jsonObject(raw) ?? [:]
        } else if let obj = youkuExt["content"] as? [String: Any] {
            content = obj
        }

        // 兜底：某些版本少一层
        if content.isEmpty {
            content = youkuExt
        }
        if content.isEmpty {
            content = root
        }

        let session = (content["sessionInfo"] as? [String: Any]) ?? [:]
        let user = (content["userInfo"] as? [String: Any]) ?? [:]

        return YoukuCredentials(
            ytid: user["ytid"] as? String
                ?? (root["ytid"] as? String ?? ""),
            ptoken: session["ptoken"] as? String
                ?? (root["ptoken"] as? String ?? ""),
            loginAppId: session["loginAppId"] as? String ?? "",
            yktk: user["yktk"] as? String
                ?? (root["yktk"] as? String ?? ""),
            nickname: user["nickname"] as? String ?? "",
            avatarUrl: user["avatar"] as? String
                ?? (user["avatarUrl"] as? String ?? ""),
            cookieExpireTime: YoukuLoginClient.intValue(session["cookieExpireTime"])
        )
    }

    /// 解析 JSON 文本为字典。
    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
