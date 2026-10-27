import Foundation

/// 优酷 H5 数据接口客户端。
///
/// 逆向来源：CIBN 酷喵 TV `com.cibn.tv` v13.0.1.3 + 优酷 H5 站点实测。
///
/// 与 mtop 协议不同，H5 侧接口不需要 SecurityGuard 设备指纹签名，
/// 因此可以在 Apple TV 上直接调用（已实测搜索接口返回真实数据）。
actor YoukuWebClient {
    private let session: URLSession
    private let base = "https://search.youku.com"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Apple TV; CPU like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer": "https://so.youku.com/",
            "Accept": "application/json, text/plain, */*"
        ]
        self.session = URLSession(configuration: config)
    }

    /// 搜索节目。
    /// GET /api/search?keyword=<kw>&page=<n>
    /// 实测返回结构: pageComponentList[].commonData
    func search(keyword: String, page: Int = 1) async throws -> [VideoItem] {
        var components = URLComponents(string: "\(base)/api/search")!
        components.queryItems = [
            .init(name: "keyword", value: keyword),
            .init(name: "page", value: String(page))
        ]
        let data = try await fetch(components.url!)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let list = root["pageComponentList"] as? [[String: Any]] else { return [] }

        return list.compactMap { component in
            guard let cd = component["commonData"] as? [String: Any] else { return nil }
            let showId = cd["showId"] as? String ?? cd["realShowId"] as? String ?? ""
            guard !showId.isEmpty else { return nil }

            // 标题在 titleDTO.displayName（实测 commonData 无顶层 title 字段）
            let titleDTO = cd["titleDTO"] as? [String: Any] ?? [:]
            let title = titleDTO["displayName"] as? String ?? cd["title"] as? String ?? "未命名"

            // 海报在 posterDTO.vThumbUrl
            let posterDTO = cd["posterDTO"] as? [String: Any] ?? [:]
            let poster = posterDTO["vThumbUrl"] as? String ?? cd["sourceImg"] as? String ?? ""

            // feature 形如 "2023 · 电视剧 · 中国 · 共30集"
            let feature = cd["feature"] as? String ?? ""
            let episodeTotal = cd["episodeTotal"] as? Int ?? 0
            var subtitle = feature
            if episodeTotal > 0 && !feature.contains("共") {
                subtitle = feature + " · 共\(episodeTotal)集"
            }
            if subtitle.isEmpty, let notice = cd["notice"] as? String {
                subtitle = notice
            }

            return VideoItem(
                showId: showId,
                videoId: "",
                title: title,
                subtitle: subtitle,
                poster: poster,
                duration: 0
            )
        }
    }

    /// 首页推荐使用的热门关键词。
    /// 优酷 H5 侧未开放免签名的推荐接口，这里用热门剧目关键词组合出推荐行。
    static let hotKeywords: [(title: String, keyword: String)] = [
        ("热播剧集", "热播"),
        ("电影", "电影"),
        ("纪录片", "纪录片"),
        ("综艺", "综艺"),
        ("动漫", "动漫"),
        ("电视剧", "电视剧")
    ]

    /// 抓取一个 JSON 接口。
    private func fetch(_ url: URL) async throws -> Data {        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YoukuError.httpStatus(http.statusCode)
        }
        // 服务端对非预期路径会返回 HTML，需要识别出来
        if let head = String(data: data.prefix(64), encoding: .utf8), head.contains("<!DOCTYPE") {
            throw YoukuError.decodingFailed("接口返回了网页而非数据")
        }
        return data
    }
}
