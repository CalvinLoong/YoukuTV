import Foundation

/// 从优酷 H5 播放页提取节目详情与剧集列表。
///
/// ## 数据来源
///
/// 播放页地址 `https://list.youku.com/show/id_{showId}.html`
/// 会 302 跳到 `https://v.youku.com/v_show/id_{vid}.html?&s={showId}`。
///
/// 跳转后的页面内嵌 `window.__INITIAL_DATA__`，含：
/// - `pageMap.extra` —— 节目元信息（videoId / showName / episodeTotal / poster）
/// - `moduleList[].components[]` —— 页面组件，其中 `type == 10013`
///   的「Web播放页选集组件」装着完整剧集列表，每条 item 的 `action_value`
///   就是该集的 vid
///
/// ## SSR 数据的两个坑（均经实测）
///
/// 1. **带 Referer 会拿不到 SSR 数据**。服务端只对「无 Referer + 常规浏览器 UA」
///    的请求做服务端渲染；带 Referer 或用 Bot UA 会返回 1.5KB 的骨架页
///    （数据靠页内 JS 运行时加载，而 tvOS 没有 JS 引擎可用）。
///    实测：不带 Referer 时 57 万字符带 `__INITIAL_DATA__`，
///    带 Referer 时只有 1549 字符且没有该字段。
///
/// 2. **即使不带 Referer，SSR 也只是间歇性返回**（实测同 URL 8 次请求里
///    只有 2 次带完整数据）。所以必须重试，并且要有兜底路径。
///
/// ## 兜底：从跳转 URL 取 vid
///
/// 即使完全拿不到 SSR 数据，302 跳转后的 URL 里也一定含 vid
/// （`/v_show/id_{vid}.html`），实测 100% 可用。至少保证「能播第一集」。
actor YoukuEpisodeClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.httpShouldSetCookies = false
        // 注意：这里**故意不设置 Referer**。
        // 实测带 Referer 会让优酷返回不含 __INITIAL_DATA__ 的骨架页。
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
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
        /// 剧集列表（SSR 不可用时为空）
        let episodes: [Episode]
        /// 是否拿到了完整剧集列表
        let hasEpisodeList: Bool
    }

    /// 加载节目详情与剧集列表。
    ///
    /// 策略：先尝试拿 SSR 完整数据（重试若干次，因为服务端只是间歇性返回），
    /// 拿不到就退回「只用跳转 URL 里的 vid」，此时只能播放当前集、没有选集列表。
    func detail(showId: String) async throws -> Detail {
        guard YoukuWebClient.isValidShowId(showId) else {
            throw YoukuError.decodingFailed("节目标识无效")
        }

        let url = URL(string: "https://list.youku.com/show/id_\(showId).html")!

        // 最多尝试 4 次：SSR 只是间歇性返回
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                let (data, response) = try await session.data(from: url)

                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw YoukuError.httpStatus(http.statusCode)
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    throw YoukuError.decodingFailed("页面编码异常")
                }

                // 兜底：跳转 URL 里一定有 vid
                let redirectVid = Self.videoId(fromFinalURL: response.url)

                if let root = try? Self.parseInitialData(html) {
                    let detail = Self.buildDetail(from: root, fallbackVid: redirectVid)
                    if detail.hasEpisodeList || !detail.videoId.isEmpty {
                        return detail
                    }
                }

                // 只有 vid 也能播
                if !redirectVid.isEmpty {
                    return Detail(
                        videoId: redirectVid,
                        showName: "",
                        episodeTotal: 0,
                        poster: "",
                        episodes: [],
                        hasEpisodeList: false
                    )
                }
                lastError = YoukuError.decodingFailed("页面结构已变更")
            } catch {
                lastError = error
            }

            // 退避后重试
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(600_000_000 * UInt64(attempt + 1)))
            }
        }

        throw lastError ?? YoukuError.decodingFailed("无法获取节目详情")
    }

    // MARK: - 解析

    /// 从跳转后的 URL 里提取 vid。
    ///
    /// `https://v.youku.com/v_show/id_XMzcxNDY5ODQ4.html?&s=...`
    static func videoId(fromFinalURL url: URL?) -> String {
        guard let url else { return "" }
        let path = url.path
        guard let range = path.range(of: "/v_show/id_") else { return "" }
        let rest = path[range.upperBound...]
        guard let dot = rest.firstIndex(of: ".") else { return "" }
        return String(rest[..<dot])
    }

    /// 组装详情（从 `__INITIAL_DATA__`）。
    static func buildDetail(from root: [String: Any], fallbackVid: String) -> Detail {
        let extra = (root["pageMap"] as? [String: Any])?["extra"] as? [String: Any] ?? [:]

        let videoId = extra["videoId"] as? String ?? fallbackVid
        let showName = extra["showName"] as? String ?? ""
        let episodeTotal = extra["episodeTotal"] as? Int ?? 0
        let posterDTO = extra["posterDTO"] as? [String: Any] ?? [:]
        let poster = posterDTO["vThumbUrl"] as? String
            ?? posterDTO["img"] as? String
            ?? ""

        let episodes = parseEpisodes(root)
        return Detail(
            videoId: videoId,
            showName: showName,
            episodeTotal: episodeTotal,
            poster: poster,
            episodes: episodes,
            hasEpisodeList: !episodes.isEmpty
        )
    }

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

                    // episodeInfo.benefitType 标识内容权益类型。
                    // 实测：0 与 1 均可正常播放；5 表示会员内容（取不到地址）。
                    let episodeInfo = item["episodeInfo"] as? [String: Any] ?? [:]
                    let benefitType = episodeInfo["benefitType"] as? Int ?? 0
                    let isVip = benefitType == 5

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
