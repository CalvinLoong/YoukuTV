import Foundation

/// 从优酷 H5 播放页提取节目详情与剧集列表。
///
/// 逆向/实测来源：
/// - 播放页地址 `https://list.youku.com/show/id_{showId}.html`
///   会 302 到 `https://v.youku.com/v_show/id_{vid}.html?s={showId}`
/// - 页面内嵌 `window.__INITIAL_DATA__`，含 `pageMap.extra`（节目元信息）
///   与 `moduleList[].components[]`（页面组件）
/// - 剧集列表在 `type == 10013` 的组件里（typeName: "Web播放页选集组件"），
///   每条 item 的 `action_value` 就是该集的 vid
///
/// 不需要任何签名或设备指纹，普通 HTTPS 请求即可。
actor YoukuEpisodeClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Apple TV; CPU like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer": "https://www.youku.com/",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        ]
        self.session = URLSession(configuration: config)
    }

    /// 节目详情。
    struct Detail {
        /// 节目当前集的 vid
        let videoId: String
        /// 节目名
        let showName: String
        /// 总集数
        let episodeTotal: Int
        /// 海报
        let poster: String
        /// 剧集列表
        let episodes: [Episode]
    }

    /// 加载节目详情与剧集列表。
    func detail(showId: String) async throws -> Detail {
        guard YoukuWebClient.isValidShowId(showId) else {
            throw YoukuError.decodingFailed("节目标识无效")
        }

        let url = URL(string: "https://list.youku.com/show/id_\(showId).html")!
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YoukuError.httpStatus(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw YoukuError.decodingFailed("页面编码异常")
        }

        let root = try Self.parseInitialData(html)
        let extra = (root["pageMap"] as? [String: Any])?["extra"] as? [String: Any] ?? [:]

        let videoId = extra["videoId"] as? String ?? ""
        let showName = extra["showName"] as? String ?? ""
        let episodeTotal = extra["episodeTotal"] as? Int ?? 0
        let posterDTO = extra["posterDTO"] as? [String: Any] ?? [:]
        let poster = posterDTO["vThumbUrl"] as? String
            ?? posterDTO["img"] as? String
            ?? ""

        let episodes = Self.parseEpisodes(root)
        return Detail(
            videoId: videoId,
            showName: showName,
            episodeTotal: episodeTotal,
            poster: poster,
            episodes: episodes
        )
    }

    // MARK: - 解析

    /// 提取页面内嵌的 `window.__INITIAL_DATA__`。
    ///
    /// 页面里是 `window.__INITIAL_DATA__ = {...};` 形式，
    /// 需要按括号配对截取（内容里有嵌套大括号，不能简单正则匹配）。
    static func parseInitialData(_ html: String) throws -> [String: Any] {
        guard let marker = html.range(of: "__INITIAL_DATA__") else {
            throw YoukuError.decodingFailed("页面结构已变更")
        }
        // 跳过 "__INITIAL_DATA__ = " 到第一个 '{'
        guard let brace = html[marker.upperBound...].firstIndex(of: "{") else {
            throw YoukuError.decodingFailed("页面结构已变更")
        }

        var depth = 0
        var endIndex: String.Index?
        var index = brace
        while index < html.endIndex {
            let ch = html[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = html.index(after: index)
                    break
                }
            }
            index = html.index(after: index)
        }
        guard let end = endIndex else {
            throw YoukuError.decodingFailed("页面结构已变更")
        }

        let raw = String(html[brace..<end])
        guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw YoukuError.decodingFailed("页面数据结构异常")
        }
        return object
    }

    /// 从 `moduleList` 里提取剧集列表。
    ///
    /// 剧集组件的类型码是 `10013`（typeName: "Web播放页选集组件"）。
    /// 结构：`moduleList[].components[]`，每个组件有 `type` 与 `itemList`。
    static func parseEpisodes(_ root: [String: Any]) -> [Episode] {
        var episodes: [Episode] = []

        let moduleList = root["moduleList"] as? [[String: Any]] ?? []
        for module in moduleList {
            let components = module["components"] as? [[String: Any]] ?? []
            for component in components {
                guard (component["type"] as? Int) == 10013 else { continue }
                let items = component["itemList"] as? [[String: Any]] ?? []
                for (offset, item) in items.enumerated() {
                    // action_value 是该集的 vid
                    let vid = item["action_value"] as? String ?? ""
                    guard !vid.isEmpty else { continue }

                    let stage = item["stage"] as? Int
                        ?? item["stageIndex"] as? Int
                        ?? (offset + 1)
                    let title = item["title"] as? String ?? "第\(stage)集"

                    // episodeInfo.benefitType != 0 表示会员内容
                    let episodeInfo = item["episodeInfo"] as? [String: Any] ?? [:]
                    let benefitType = episodeInfo["benefitType"] as? Int ?? 0
                    let isVip = benefitType != 0

                    episodes.append(Episode(
                        index: stage,
                        title: title,
                        videoId: vid,
                        duration: item["duration"] as? Int ?? 0,
                        isVip: isVip
                    ))
                }
            }
            if !episodes.isEmpty { break }
        }

        return episodes.sorted { $0.index < $1.index }
    }
}
