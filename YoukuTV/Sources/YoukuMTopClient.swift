import Foundation
import CryptoKit

/// 优酷 mtop (H5) 协议客户端。
///
/// 逆向来源：CIBN 酷喵 TV 客户端 `com.cibn.tv` v13.0.1.3
/// - 网关域名: `acs.youku.com` / `acs.m.taobao.com`  (证据: com.yunos.tv.dao.BusinessMTopDao.<clinit>)
/// - 签名算法: `sign = MD5(token & t & appKey & data)`
/// - token 来源: 服务端下发的 Cookie `_m_h5_tk` 的前 32 位
///   (证据: com.youku.passport.mtop.MtopHeaderFields 枚举 SIGN → "x-sign")
/// - appKey:  `23061772` (OTT/盒子) / `23164371` (TV 主) / `23058384` (DVB)
///   (证据: com.yunos.tv.config.BusinessMtopConst)
actor YoukuMTopClient {
    // MARK: - 常量（全部有逆向证据出处）

    /// OTT（机顶盒/智能电视）渠道 appKey
    static let ottAppKey = "23061772"
    /// 电视端主 appKey
    static let tvAppKey = "23164371"
    /// DVB 渠道 appKey
    static let dvbAppKey = "23058384"

    /// 优酷 mtop 网关
    static let gateway = "acs.youku.com"
    /// 淘宝 mtop 网关（备选）
    static let taobaoGateway = "acs.m.taobao.com"

    /// 业务通道标识
    static let ttid = "123@tvhomeshell_yunos_1.0.0"
    /// 设备业务 pid（资源 ykpid）
    static let pid = "e849fea79a704c06"

    /// mtop JavaScript 协议版本
    static let jsv = "2.7.2"

    // MARK: - 状态

    private var token: String = ""
    private var tokenExpiry: Date = .distantPast
    private var cookieStore: [String: String] = [:]
    private let session: URLSession
    private let appKey: String

    init(appKey: String = YoukuMTopClient.ottAppKey) {
        self.appKey = appKey
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Apple TV; CPU like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer": "https://www.youku.com/"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - 公开 API

    /// 搜索节目。
    /// 证据: com.yunos.tv.yingshi.boutique.bundle.search.app.data.SearchReq.fillParams
    /// 参数集: app / packageInfo / keyword / spell / page / pageSize / category / bizExt
    func search(keyword: String, page: Int = 1, pageSize: Int = 20) async throws -> [VideoItem] {
        let params: [String: Any] = [
            "keyword": keyword,
            "page": page,
            "pageSize": pageSize,
            "category": 0,
            "app": "com.yunos.tv.yingshi.boutique",
            "packageInfo": packageInfoJSON(),
            "spell": false,
            "bizExt": "{}"
        ]
        let property: [String: Any] = [
            "params": params,
            "app_style": 1,
            "layout_version": "1.0"
        ]
        let data = try await call(
            "mtop.tvmagellan.main.search",
            version: "1.0",
            payload: ["property": jsonString(property)]
        )
        return parseSearch(data)
    }

    /// 获取节目详情。
    /// 证据: com.yunos.tv.yingshi.boutique.bundle.search.base.mtop.MTopReq.buildParams
    func videoInfo(showId: String) async throws -> VideoItem? {
        let property: [String: Any] = ["params": ["showId": showId, "vids": showId]]
        let data = try await call(
            "mtop.wenyu.video.info",
            version: "1.0",
            payload: ["property": jsonString(property)]
        )
        return parseVideoInfo(data)
    }

    /// 获取剧集列表。
    /// 证据: com.yunos.tv.casual.entity.ESequenceList 请求 `mtop.wenyu.video.episode`
    func episodes(showId: String, videoId: String = "") async throws -> [Episode] {
        let data = try await call(
            "mtop.wenyu.video.episode",
            version: "1.0",
            payload: ["showId": showId, "video_id": videoId]
        )
        return parseEpisodes(data)
    }

    /// 节目列表（按节点）。
    /// 证据: com.yunos.tv.dao.CatalogMTopDao → `mtop.wenyu.video.show.list` v5.0
    func showList(nodeId: String, page: Int = 1, pageSize: Int = 30) async throws -> [VideoItem] {
        let data = try await call(
            "mtop.wenyu.video.show.list",
            version: "5.0",
            payload: [
                "nodeId": nodeId,
                "page": page,
                "pageSize": pageSize,
                "type": "0",
                "property": jsonString(defaultProperty())
            ]
        )
        return parseShowList(data)
    }

    /// 首页导航标签。
    /// 证据: com.yunos.tv.dao.BusinessMTopDao 请求 `mtop.tvdesktop.tabs.list`
    func tabs(scope: Int = 1) async throws -> [TabItem] {
        let data = try await call(
            "mtop.tvdesktop.tabs.list",
            version: "1.0",
            payload: [
                "tabListScope": scope,
                "iconScope": scope,
                "scope": scope,
                "tabCustomized": "0",
                "disableSmartMode": "1",
                "property": jsonString(defaultProperty(layoutVersion: "11"))
            ]
        )
        return parseTabs(data)
    }

    // MARK: - 底层协议

    /// 获取播放信息（含 m3u8 地址）。
    ///
    /// 逆向证据:
    /// - API 名与网关: `a.f.m.f.d.playc` → `mtop.youku.play.ups.appinfo.get` v1.1，网关 `un-acs.youku.com`
    /// - 业务参数字段: `a.f.m.f.playb` → vid / showid / ckey / play_ability / preferClarity /
    ///   drm_type / key_index / master_m3u8 / player_type / extag / spdl / skh / hdcp
    func playInfo(showId: String, videoId: String) async throws -> [String: Any] {
        let vid = videoId.isEmpty ? showId : videoId
        let bizParams: [String: Any] = [
            "vid": vid,
            "showid": showId,
            "ccode": "0532",
            "play_ability": 16782592,
            "preferClarity": 4,
            "drm_type": 0,
            "master_m3u8": 1,
            "player_type": "yunos",
            "extag": "EXT-X-PRIVINF",
            "app_ver": "2.1.63"
        ]
        return try await call(
            "mtop.youku.play.ups.appinfo.get",
            version: "1.1",
            payload: ["biz_params": jsonString(bizParams)],
            host: "un-acs.youku.com"
        )
    }

    /// 发起一次 mtop 请求，完成「取 token → 签名 → 请求」两段式流程。
    private func call(
        _ api: String,
        version: String,
        payload: [String: Any],
        host: String = YoukuMTopClient.gateway
    ) async throws -> [String: Any] {
        let data = jsonString(payload)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))

        // 第一段：无有效 token 时先请求一次，让服务端下发 _m_h5_tk
        if token.isEmpty || tokenExpiry < Date() {
            try await primeToken(api: api, version: version, host: host)
        }

        // 第二段：MD5(token & t & appKey & data)
        let sign = Self.md5Hex("\(token)&\(timestamp)&\(appKey)&\(data)")

        var components = URLComponents(
            string: "https://\(host)/h5/\(api)/\(version)/"
        )!
        components.queryItems = [
            .init(name: "jsv", value: Self.jsv),
            .init(name: "appKey", value: appKey),
            .init(name: "t", value: timestamp),
            .init(name: "sign", value: sign),
            .init(name: "api", value: api),
            .init(name: "v", value: version),
            .init(name: "type", value: "json"),
            .init(name: "dataType", value: "json"),
            .init(name: "data", value: data),
            .init(name: "ttid", value: Self.ttid),
            .init(name: "x-pid", value: Self.pid)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in cookieStore { request.setValue(v, forHTTPHeaderField: "Cookie-\(k)") }

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
        // mtop 业务错误码在 ret 数组里
        if let ret = json["ret"] as? [String], let first = ret.first, !first.hasPrefix("SUCCESS") {
            throw YoukuError.mtop(first)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    /// 触发服务端下发 `_m_h5_tk` Cookie。
    private func primeToken(api: String, version: String, host: String) async throws {
        var components = URLComponents(
            string: "https://\(host)/h5/\(api)/\(version)/"
        )!
        components.queryItems = [
            .init(name: "jsv", value: Self.jsv),
            .init(name: "appKey", value: appKey),
            .init(name: "api", value: api),
            .init(name: "v", value: version)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, _) = try? await session.data(for: request)
        // 响应头里的 Set-Cookie 已由 captureCookies 收走
        if token.isEmpty {
            throw YoukuError.tokenUnavailable
        }
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
                let cval = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    .split(separator: ";").first.map(String.init) ?? ""
                guard !cname.isEmpty else { continue }
                cookieStore[cname] = cval
                if cname == "_m_h5_tk" {
                    // token 是 cookie 值中 "_" 之前的部分
                    let raw = cval.split(separator: "_").first.map(String.init) ?? cval
                    token = String(raw.prefix(32))
                    tokenExpiry = Date().addingTimeInterval(300)
                }
            }
        }
    }

    // MARK: - 组装辅助

    /// 设备环境信息。证据: com.yunos.tv...search.app.data.SearchReq.packageInfo
    private func packageInfoJSON() -> String {
        jsonString([
            "com.yunos.tv.yingshi.boutique": Int.random(in: 100_000_000...999_999_999),
            "com.yunos.tv.appstore": "2101407008"
        ])
    }

    /// 通用 property。证据: com.yunos.tv...search.base.mtop.MTopReq.customProperty
    private func defaultProperty(layoutVersion: String = "12.2") -> [String: Any] {
        var p: [String: Any] = [
            "device_box": "YUNOS",
            "device_brand": "apple",
            "isVisitor": "0"
        ]
        p["layout_version"] = layoutVersion
        return p
    }

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 响应解析

    private func parseSearch(_ data: [String: Any]) -> [VideoItem] {
        let groups = data["groups"] as? [[String: Any]] ?? []
        var items: [VideoItem] = []
        for group in groups {
            guard let cards = group["cards"] as? [[String: Any]] else { continue }
            for card in cards {
                let node = card["node"] as? [String: Any] ?? card
                guard let showId = node["showId"] as? String ?? node["show_id"] as? String else { continue }
                items.append(VideoItem(
                    showId: showId,
                    videoId: node["vid"] as? String ?? node["video_id"] as? String ?? "",
                    title: node["title"] as? String ?? node["name"] as? String ?? "未命名",
                    subtitle: node["subtitle"] as? String ?? node["subTitle"] as? String ?? "",
                    poster: node["img"] as? String ?? node["poster"] as? String ?? node["pic"] as? String ?? "",
                    duration: node["duration"] as? Int ?? 0
                ))
            }
        }
        return items
    }

    private func parseShowList(_ data: [String: Any]) -> [VideoItem] {
        var items: [VideoItem] = []
        let nodes = data["nodes"] as? [[String: Any]] ?? []
        for node in nodes {
            guard let showId = node["showId"] as? String ?? node["show_id"] as? String else { continue }
            items.append(VideoItem(
                showId: showId,
                videoId: node["vid"] as? String ?? "",
                title: node["title"] as? String ?? node["name"] as? String ?? "未命名",
                subtitle: node["subtitle"] as? String ?? "",
                poster: node["img"] as? String ?? node["poster"] as? String ?? "",
                duration: node["duration"] as? Int ?? 0
            ))
        }
        return items
    }

    private func parseVideoInfo(_ data: [String: Any]) -> VideoItem? {
        let node = data["node"] as? [String: Any] ?? data
        guard let showId = node["showId"] as? String ?? node["show_id"] as? String else { return nil }
        return VideoItem(
            showId: showId,
            videoId: node["vid"] as? String ?? "",
            title: node["title"] as? String ?? node["name"] as? String ?? "未命名",
            subtitle: node["subtitle"] as? String ?? "",
            poster: node["img"] as? String ?? node["poster"] as? String ?? "",
            duration: node["duration"] as? Int ?? 0
        )
    }

    private func parseEpisodes(_ data: [String: Any]) -> [Episode] {
        let list = data["list"] as? [[String: Any]] ?? data["episodes"] as? [[String: Any]] ?? []
        return list.enumerated().map { idx, item in
            Episode(
                index: item["index"] as? Int ?? idx,
                title: item["title"] as? String ?? item["name"] as? String ?? "第\(idx + 1)集",
                videoId: item["vid"] as? String ?? item["video_id"] as? String ?? "",
                duration: item["duration"] as? Int ?? 0,
                isVip: (item["vip"] as? Bool) ?? (item["isVip"] as? Bool) ?? false
            )
        }
    }

    private func parseTabs(_ data: [String: Any]) -> [TabItem] {
        let list = data["tabs"] as? [[String: Any]] ?? []
        return list.enumerated().map { idx, item in
            TabItem(
                id: item["id"] as? String ?? "\(idx)",
                title: item["name"] as? String ?? item["title"] as? String ?? "栏目",
                nodeId: item["nodeId"] as? String ?? item["node_id"] as? String ?? "-22"
            )
        }
    }
}

// MARK: - 数据模型

struct VideoItem: Identifiable, Hashable {
    let showId: String
    let videoId: String
    let title: String
    let subtitle: String
    let poster: String
    let duration: Int
    var id: String { showId }
}

struct Episode: Identifiable, Hashable {
    let index: Int
    let title: String
    let videoId: String
    let duration: Int
    let isVip: Bool
    var id: String { "\(index)-\(videoId)" }
}

struct TabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let nodeId: String
}

// MARK: - 错误

enum YoukuError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case decodingFailed(String)
    case mtop(String)
    case tokenUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "响应无效"
        case .httpStatus(let code): return "HTTP 错误 \(code)"
        case .decodingFailed(let s): return "解析失败: \(s)"
        case .mtop(let msg): return "接口错误: \(msg)"
        case .tokenUnavailable: return "无法获取 mtop token"
        }
    }
}
