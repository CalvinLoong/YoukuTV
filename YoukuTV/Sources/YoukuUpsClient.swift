import Foundation

/// 优酷播放地址（ups）接口客户端。
///
/// ## 逆向来源（全部经实测验证）
///
/// - 接口：`mtop.youku.play.ups.appinfo.get` v1.1
/// - 网关：`un-acs.youku.com`（播放专用，区别于通用 mtop 网关 `acs.youku.com`）
/// - appKey：`24679788`（PC Web 渠道）
/// - 签名：`sign = MD5(token & t & appKey & data)`
///   - `token` = 服务端下发的 Cookie `_m_h5_tk` 前 32 位
///   - `data`  = 紧凑 JSON（无空格）
/// - 传输：`type=jsonp&dataType=jsonp&callback=mtopjsonp1`
///   响应形如 `mtopjsonp1({...})`，需剥离包装后解析
///
/// ## ckey（防盗链）
///
/// `steal_params.ckey` 是优酷的设备级签名，由阿里 AWSC（Web SecurityGuard）
/// 在浏览器环境生成。经实测确认其性质：
///
/// - **不绑定 vid**：同一个 ckey 可用于任意视频（实测三体/庆余年2 均成功）
/// - **绑定 utid**：改了 utid 即失效
/// - **有效期较长**：实测 2 天前生成的 ckey 仍然有效
///
/// 因此 App 内置一份 ckey + utid 即可覆盖所有视频的播放地址获取。
///
/// ## 为什么 tvOS 用不了浏览器现场生成
///
/// tvOS 自 9.0 起完全移除了 WebKit（没有 WKWebView / SFSafariViewController），
/// AWSC 又依赖 canvas 指纹，JavaScriptCore 无 canvas，故无法在设备端生成。
/// ckey 由 `Tools/更新ckey.swift` 的配套脚本在开发机上用真实浏览器生成后内置。
actor YoukuUpsClient {
    // MARK: - 常量

    static let appKey = "24679788"
    static let host = "un-acs.youku.com"
    static let api = "mtop.youku.play.ups.appinfo.get"
    static let version = "1.1"

    /// 业务通道标识
    static let ttid = "123@tvhomeshell_yunos_1.0.0"

    /// User-Agent。用桌面 Chrome 的 UA，服务端据此判定为 PC Web 渠道。
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // MARK: - 状态

    private var token: String = ""
    private var tokenExpiry: Date = .distantPast
    private var cookieStore: [String: String] = [:]
    private let session: URLSession

    /// ckey 提供器。默认用内置的固定值；可通过 `update` 换成新值。
    private var credential: UpsCredential

    init(credential: UpsCredential = UpsCredential.builtin) {
        self.credential = credential
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: config)
    }

    /// 更新 ckey（用于服务端轮换后的自愈）。
    func update(credential: UpsCredential) {
        self.credential = credential
    }

    // MARK: - 公开 API

    /// 获取指定视频的播放地址。
    ///
    /// - Parameters:
    ///   - vid: 视频 ID（形如 `XODM5OTI3Njky` 或 `XNTkzNDc4MDI2OA==`）
    ///   - showId: 剧集 ID（可选，用于 `current_showid`）
    /// - Returns: 可直接交给 AVPlayer 的播放信息列表，按清晰度从高到低
    func playback(for vid: String, showId: String = "") async throws -> [PlaybackInfo] {
        let data = try await request(vid: vid, showId: showId)
        guard let streams = data["stream"] as? [[String: Any]] else { return [] }

        var results: [PlaybackInfo] = []
        for stream in streams {
            guard let rawURL = stream["m3u8_url"] as? String, !rawURL.isEmpty else { continue }

            // stream_type 形如 cmfv4sd / cmfv4hd2 / cmfv4hd3 / auto
            let type = stream["stream_type"] as? String ?? ""
            let width = stream["width"] as? Int ?? 0
            let height = stream["height"] as? Int ?? 0

            // `auto` 这条不是 URL，而是**主播放列表的内容**（以 #EXTM3U 开头），
            // 内含多条 EXT-X-STREAM-INF 变体流与音轨。实测其内部 URI 都是绝对地址，
            // 因此可以落盘成临时 m3u8 交给 AVPlayer，从而获得自动码率切换能力。
            if rawURL.hasPrefix("#EXTM3U") {
                guard let localURL = Self.writeMasterPlaylist(rawURL, vid: vid) else { continue }
                results.append(
                    PlaybackInfo(
                        url: localURL,
                        quality: .master,
                        streamType: "auto",
                        headers: Self.defaultHeaders
                    )
                )
                continue
            }

            guard let url = URL(string: rawURL) else { continue }
            results.append(
                PlaybackInfo(
                    url: url,
                    quality: Self.quality(for: type, width: width, height: height),
                    streamType: type,
                    headers: Self.defaultHeaders
                )
            )
        }

        // 主播放列表（auto）包含多码率，优先返回；其余按分辨率从高到低
        return results.sorted { lhs, rhs in
            if lhs.quality == .master { return true }
            if rhs.quality == .master { return false }
            return lhs.quality.order > rhs.quality.order
        }
    }

    /// 只取最高画质的地址（优先 master playlist）。
    func bestPlayback(for vid: String, showId: String = "") async throws -> PlaybackInfo? {
        try await playback(for: vid, showId: showId).first
    }

    // MARK: - 协议实现

    private func request(vid: String, showId: String) async throws -> [String: Any] {
        let payload = try buildPayload(vid: vid, showId: showId)
        let data = jsonString(payload)

        // 第一段：无有效 token 时先请求一次，让服务端下发 _m_h5_tk
        if token.isEmpty || tokenExpiry < Date() {
            try await primeToken()
        }

        // 第二段：MD5(token & t & appKey & data)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Self.md5Hex("\(token)&\(timestamp)&\(Self.appKey)&\(data)")

        var components = URLComponents(
            string: "https://\(Self.host)/h5/\(Self.api)/\(Self.version)/"
        )!
        components.queryItems = [
            .init(name: "jsv", value: "2.6.1"),
            .init(name: "appKey", value: Self.appKey),
            .init(name: "t", value: timestamp),
            .init(name: "sign", value: sign),
            .init(name: "api", value: Self.api),
            .init(name: "v", value: Self.version),
            .init(name: "timeout", value: "15000"),
            .init(name: "type", value: "jsonp"),
            .init(name: "dataType", value: "jsonp"),
            .init(name: "callback", value: "mtopjsonp1"),
            .init(name: "data", value: data),
            .init(name: "ttid", value: Self.ttid)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://v.youku.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        applyCookies(to: &request)

        let (response, body) = try await session.data(for: request)
        captureCookies(from: response)

        guard let http = response as? HTTPURLResponse else {
            throw YoukuError.invalidResponse
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw YoukuError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw YoukuError.decodingFailed(text.prefix(200).description)
        }

        // 剥离 JSONP 包装：mtopjsonp1({...})
        var payloadObject = json
        if let inner = Self.stripJSONP(text) {
            payloadObject = inner
        }

        if let ret = payloadObject["ret"] as? [String],
           let first = ret.first,
           !first.hasPrefix("SUCCESS") {
            throw YoukuError.mtop(first)
        }
        return payloadObject["data"] as? [String: Any] ?? [:]
    }

    /// 组装 ups 的三段式参数。
    private func buildPayload(vid: String, showId: String) throws -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970)

        let steal: [String: Any] = [
            "ccode": "0502",
            "utid": credential.utid,
            "version": "9.22.2",
            "ckey": credential.ckey,
            "client_ip": "192.168.1.1",
            "client_ts": String(now)
        ]

        var biz: [String: Any] = [
            "vid": vid,
            "local_vid": vid,
            "h265": 1,
            "preferClarity": -1,
            "media_type": "standard,subtitle",
            "app_ver": "9.22.2",
            "extag": "EXT-X-PRIVINF",
            "play_ability": 2164266240,   // 16782592 + 2^31
            "close_ability": 655360,       // 2^17 + 2^19
            "master_m3u8": 1,
            "drm_type": 3,
            "key_index": "web01",
            "encryptR_client": credential.encryptRClient,
            "skh": 1,
            "start_point_ms": 0,
            "last_clarity": -1,
            "wdm": 1,
            "pn": "com.youku.pcweb",
            "playMode": "normal",
            "enc_ver": 2,
            "local_time": String(now)
        ]
        if !showId.isEmpty {
            biz["current_showid"] = showId
        }

        let ad: [String: Any] = [
            "vs": "1.0",
            "pver": "9.22.2",
            "sver": "2.0",
            "site": 1,
            "aw": "w",
            "fu": 0,
            "d": 0,
            "bt": "pc",
            "os": "mac",
            "osv": "",
            "dq": "auto",
            "atm": "",
            "partnerid": "null",
            "wintype": "interior",
            "isvert": 0,
            "vip": 0,
            "p": 1,
            "rst": "mp4",
            "needbf": 2,
            "avs": "1.0",
            "needad": 1
        ]

        // 三段各自序列化成字符串（注意：不是嵌套对象）
        return [
            "steal_params": jsonString(steal),
            "biz_params": jsonString(biz),
            "ad_params": jsonString(ad)
        ]
    }

    /// 触发服务端下发 `_m_h5_tk`。
    private func primeToken() async throws {
        var components = URLComponents(
            string: "https://\(Self.host)/h5/\(Self.api)/\(Self.version)/"
        )!
        components.queryItems = [
            .init(name: "appKey", value: Self.appKey),
            .init(name: "api", value: Self.api),
            .init(name: "v", value: Self.version)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        applyCookies(to: &request)
        let (_, _) = try? await session.data(for: request)
        if token.isEmpty {
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
                    // token 是 cookie 值中 "_" 之前的部分
                    let rawToken = cval.split(separator: "_").first.map(String.init) ?? cval
                    token = String(rawToken.prefix(32))
                    tokenExpiry = Date().addingTimeInterval(300)
                }
            }
        }
    }

    // MARK: - 工具

    /// 剥离 JSONP 包装。
    static func stripJSONP(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") == false,
              let open = trimmed.firstIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = String(trimmed[trimmed.index(after: open)..<close])
        return try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any]
    }

    /// stream_type → 清晰度标识。
    /// 根据 stream_type 与分辨率判断清晰度。
    ///
    /// 优先用实际分辨率（实测最准），stream_type 作为兜底。
    /// 实测映射：`cmfv4sd`=640x360、`cmfv4hd`=864x486、`cmfv4hd2`=1280x720、
    /// `cmfv4hd3`=1920x1080。
    static func quality(for streamType: String, width: Int = 0, height: Int = 0) -> Quality {
        let t = streamType.lowercased()
        if t.contains("auto") { return .master }

        // 有分辨率信息时以分辨率为准
        if height > 0 {
            switch height {
            case 2160...: return .uhd
            case 1080...: return .fhd
            case 720...: return .hd
            case 360...: return .sd
            default: break
            }
        }

        if t.contains("5hd") || t.contains("4k") { return .uhd }
        if t.contains("hd3") || t.contains("hd2") { return .fhd }
        if t.contains("hd") { return .hd }
        if t.contains("sd") { return .sd }
        return .unknown
    }

    /// 把主播放列表内容落盘为临时 m3u8 文件。
    ///
    /// ups 响应里 `stream_type == "auto"` 的那一条，`m3u8_url` 字段装的
    /// **不是 URL 而是清单内容**（以 `#EXTM3U` 开头），内含多条
    /// `EXT-X-STREAM-INF` 变体流（1920x1080 / 1280x720 / 864x486 / 640x360）
    /// 以及独立的音轨。
    ///
    /// 实测清单内部的 URI 全是绝对地址，因此落盘后 AVPlayer 能正常加载，
    /// 并可自行按带宽做**自动码率切换** —— 这是单一清晰度地址做不到的。
    static func writeMasterPlaylist(_ content: String, vid: String) -> URL? {
        // 清理掉同名的旧文件
        let sanitized = vid.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let name = "yk_master_\(sanitized).m3u8"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        // 内容里的换行是字面量 "\n"（两字符），需还原成真实换行
        let normalized = content
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")

        do {
            try normalized.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static let defaultHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Referer": "https://v.youku.com/"
    ]

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ckey 凭据

/// 一组 ups 接口凭据（ckey + utid + encryptR_client）。
///
/// 这三者由优酷的 AWSC 设备指纹模块一并产出，必须配套使用。
/// 生成方式见 `Tools/生成ckey.swift`（需在有浏览器的开发机上跑一次）。
struct UpsCredential: Codable, Equatable {
    /// 防盗链签名，形如 `140#...`
    let ckey: String
    /// 设备标识，形如 `LV1nI+ibplkCAavdUaZ3x8To`
    let utid: String
    /// 客户端加密参数
    let encryptRClient: String
    /// 生成时间，便于判断是否需要更新
    let generatedAt: Date

    init(ckey: String, utid: String, encryptRClient: String, generatedAt: Date = Date()) {
        self.ckey = ckey
        self.utid = utid
        self.encryptRClient = encryptRClient
        self.generatedAt = generatedAt
    }

    /// 内置的默认凭据。
    ///
    /// 数据来源：由真实浏览器访问优酷播放页时 AWSC 生成，经实测可用
    /// （同一天内可取任意 vid 的播放地址）。
    /// 当服务端轮换导致失效时，App 会提示更新；凭据可通过网络配置下发更新。
    static let builtin = UpsCredential(
        ckey: "140#o8foFD6ezzWioQo2+bhu4pN8s9DfVoO52wuS/WRX/zGIMrMVf7dtiRzmxLATDWpY4FiWlp1zzRn0a2/SGFzxSx8za3h/zzrb22U3lp1xzCQiVXE/tFzx2Dc33b/BeHmijDapVrMn3rNmgkYEG5R5hPU4n8fKJKz0pKziPLYJIk1oX2QDQBoq3uz3pNJtDTp+wlAAJzY7a7oluQAA9ORe8Sk54uGspJd4oAqJKt6+jyGmx7j1Q/exmOk1UNGBkAOA80quTu/lBy2YR2j+9gFgjrHwuZVlN2162HflgwbOoyP/9DDGY60zrA6QEmMT+J7aVaXv+sUoBtcHXL7wyk0Hn9oTOcR8nqH9VTCfDHIHXLSYitT+OtVps49ybWAYQ/3LR0tOzh14nuweR69asPm0QRbSwqtEOzQ68vkO+1K6ieM509aqaxu8dQIwSxf5b95zz6m/dMDdEBKRba/sGR9LqDebjhcf5nT6WuSdeNJFOXWmWa9myBdjrWObmaEopgMYRWcxQJnfmnEN7vqdhwIPeQ3ExmrriutZ3aZh6uSuaOEDr+ZhNvY38yaDg/4E5v8gJ4CbQmY37wSnz3Py2R5Qvl4hIHEUXsFkicYkff82iTrfGSYQF8/s4tG7ZSr1fzcYPbZITZIjwiaJ+UWbcSy5nB+WG7afir+ULOCB6F/bcf0py5mgUyM5JodiH8vRFNgD3ElWpr5CBMXTarIhmbB57QSphuaGCdSJ8ki+TV+PtpsHUbviG6UVUopMeQxNcyeMkN0ddgdNFgC3huHE",
        utid: "Dg5qI8+GsDsCAavdUaZcHoaR",
        encryptRClient: "+UklxYpCot0pHeJOAcTh4A==",
        generatedAt: Date(timeIntervalSince1970: 1793269837)
    )
}

// MARK: - 数据模型

/// 播放信息。
struct PlaybackInfo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let quality: Quality
    let streamType: String
    let headers: [String: String]
}

/// 清晰度。
enum Quality: String, CaseIterable, Identifiable, Comparable {
    case master = "主播放列表"
    case uhd = "超清"
    case fhd = "1080P"
    case hd = "720P"
    case sd = "标清"
    case unknown = "未知"

    var id: String { rawValue }

    static func < (lhs: Quality, rhs: Quality) -> Bool {
        lhs.order < rhs.order
    }

    /// 排序权重，数值越大清晰度越高。
    var order: Int {
        switch self {
        case .master: return 5
        case .uhd: return 4
        case .fhd: return 3
        case .hd: return 2
        case .sd: return 1
        case .unknown: return 0
        }
    }
}
