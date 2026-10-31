import Foundation

/// 优酷首页推荐客户端。
///
/// ## 数据来源
///
/// `https://www.youku.com/` 的服务端渲染数据 `window.__INITIAL_DATA__`。
/// 结构（实测）：
///
/// ```
/// root
/// ├─ navList[]                    顶部频道导航（21 项：首页/电视剧/动漫/电影/综艺…）
/// │   ├─ nodeKey                  频道标识（WEBTV / WEBMOVIE / WEBVARIETY…）
/// │   ├─ title                    中文名
/// │   └─ category                 分类关键词（可作为搜索词）
/// └─ moduleList[]                 推荐模块
///    └─ components[]
///       ├─ title                  推荐行标题（"猜你在追" / "TA的故事·人物纪录片"）
///       ├─ typeName               组件类型（KU_FLIX_FEED_V_SCROLL_COMPONENT 等）
///       └─ itemList[]             该行的内容
///          ├─ title               节目名
///          ├─ img / hImg          海报（竖版 / 横版）
///          ├─ action_value         showId（20 位小写十六进制）
///          ├─ previewInfo.videoId  ★ vid，可直接拿去调 ups 取播放地址
///          ├─ desc                 简介
///          ├─ mark.text            权益角标（"限免中" / "VIP"…）
///          ├─ lbTexts              "剧・限免13集"
///          └─ subtitle             推荐理由（"电视剧热度榜·TOP1"）
/// ```
///
/// ## 三个实测要点
///
/// 1. **必须直连 `/ku/webhome`**：请求 `https://www.youku.com/` 会先 302
///    跳到 `/ku/webhome`，而这条 **302 链路会触发阿里 WAF 的惩罚页**
///    （响应头 `bxpunish: 1`，响应体只有 1397 字节，内容是
///    `_____tmd_____/punish?x5secdata=...` 的滑块验证页）。
///    实测：根 URL 走 302 → 5 次里 2 次被惩罚；直连 `/ku/webhome` → 6/6 正常。
/// 2. **被惩罚时不要密集重试**：惩罚 cookie 的 `Max-Age=20`，说明窗口约 20 秒。
///    退避太短（原来 0.7s 起）必然全撞在窗口里 → 必须拉长到秒级。
/// 3. **不能带 Referer**：服务端只对「无 Referer + 常规浏览器 UA」的请求做 SSR。
///    带 Referer 或用 Bot UA 会返回骨架页。
actor YoukuHomeClient {
    /// 顶部频道。
    struct Channel: Identifiable, Hashable {
        /// nodeKey，如 "WEBTV"
        let id: String
        /// 中文标题，如 "电视剧"
        let title: String
        /// 分类关键词，用作该频道的搜索词
        let category: String
        /// 是否是首页
        var isHome: Bool { id == "WEBHOME" }
    }

    /// 一行推荐。
    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [VideoItem]
    }

    /// 首页整体数据。
    struct Home {
        let channels: [Channel]
        let rows: [Row]
    }

    private let session: URLSession

    /// 优酷首页的真实落点。直连它可以绕开 302 链路上的阿里 WAF 惩罚页。
    static let homeURL = "https://www.youku.com/ku/webhome"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        // ★ 保留 cookie：优酷会下发 csrfToken / isI18n 等会话 cookie，
        //   带着它们请求更像真实浏览器，可显著降低被 WAF 惩罚的概率。
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        // 不要缓存：SSR 页面体积大（~1MB），且惩罚页不能被缓存住反复命中
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // ★ 故意不设置 Referer —— 带 Referer 会让优酷返回不含 SSR 数据的骨架页。
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        self.session = URLSession(configuration: config)
    }

    /// 加载首页。
    ///
    /// SSR 偶尔会被 WAF 惩罚，最多重试 5 次；每次之间按秒级退避。
    func loadHome() async throws -> Home {
        let root = try await fetchInitialData(url: Self.homeURL)
        return Self.buildHome(from: root)
    }

    // MARK: - 抓取

    private func fetchInitialData(url: String, attempts: Int = 5) async throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw YoukuError.decodingFailed("地址无效")
        }

        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(from: target)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw YoukuError.httpStatus(http.statusCode)
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    throw YoukuError.decodingFailed("页面编码异常")
                }

                // ★ 先识别「被阿里 WAF 惩罚」：响应头 bxpunish: 1，
                //   或响应体里出现 _____tmd_____/punish。
                //   这跟「SSR 没就绪」是两种完全不同的失败，必须分开报，
                //   否则上层会一直无脑重试，错误信息也没法指导用户。
                let http = response as? HTTPURLResponse
                let punished = http?.value(forHTTPHeaderField: "bxpunish") == "1"
                    || html.contains("_____tmd_____/punish")
                if punished {
                    throw YoukuError.decodingFailed("触发优酷风控（需等待约 20 秒后重试）")
                }

                if let root = YoukuSSR.extractInitialData(html) {
                    return root
                }
                lastError = YoukuError.decodingFailed("首页数据未就绪")
            } catch {
                lastError = error
            }
            // 退避：1s / 2s / 3s / 4s —— 必须拉长到秒级，
            // 否则重试会全落在 WAF 的 20 秒惩罚窗口内。
            if attempt < attempts - 1 {
                let seconds = UInt64(attempt + 1)
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
        throw lastError ?? YoukuError.decodingFailed("无法获取首页数据")
    }

    // MARK: - 解析

    /// 从 SSR 根对象构建首页数据。
    static func buildHome(from root: [String: Any]) -> Home {
        Home(
            channels: parseChannels(root),
            rows: parseRows(root)
        )
    }

    /// 解析顶部频道导航。
    static func parseChannels(_ root: [String: Any]) -> [Channel] {
        let navList = root["navList"] as? [[String: Any]] ?? []
        var result: [Channel] = []
        for nav in navList {
            let nodeKey = nav["nodeKey"] as? String ?? ""
            let title = nav["title"] as? String ?? ""
            guard !nodeKey.isEmpty, !title.isEmpty else { continue }
            let category = nav["category"] as? String ?? title
            result.append(Channel(id: nodeKey, title: title, category: category))
        }
        return result
    }

    /// 解析推荐行。
    static func parseRows(_ root: [String: Any]) -> [Row] {
        let moduleList = root["moduleList"] as? [[String: Any]] ?? []
        var rows: [Row] = []
        var seen = Set<String>()

        for (moduleIndex, module) in moduleList.enumerated() {
            let components = module["components"] as? [[String: Any]] ?? []
            for (componentIndex, component) in components.enumerated() {
                let rawItems = component["itemList"] as? [[String: Any]] ?? []
                guard !rawItems.isEmpty else { continue }

                let items = rawItems.compactMap { parseItem($0) }
                guard items.count >= 3 else { continue }

                // 行标题：组件自带 title（如"猜你在追"）；没有就用推荐理由兜底
                var title = component["title"] as? String ?? ""
                if title.isEmpty {
                    title = items.first?.subtitle ?? "推荐"
                }

                let id = "\(moduleIndex)-\(componentIndex)-\(title)"
                guard !seen.contains(id) else { continue }
                seen.insert(id)

                rows.append(Row(id: id, title: title, items: items))
            }
        }
        return rows
    }

    /// 把一条推荐 item 映射成 `VideoItem`。
    ///
    /// 关键字段：`previewInfo.videoId` 是**可直接播放的 vid**，
    /// 有了它就不必再走「302 跳转取 vid」那条慢路径。
    static func parseItem(_ item: [String: Any]) -> VideoItem? {
        let title = item["title"] as? String ?? ""
        guard !title.isEmpty else { return nil }

        let showId = item["action_value"] as? String ?? ""
        let previewInfo = item["previewInfo"] as? [String: Any] ?? [:]
        let videoId = previewInfo["videoId"] as? String ?? ""

        // showId 与 vid 至少要有一个，否则点了也播不了
        guard !showId.isEmpty || !videoId.isEmpty else { return nil }
        // showId 必须是合法的 20 位小写十六进制，否则详情页会跳到别的节目
        if !showId.isEmpty && !YoukuWebClient.isValidShowId(showId) {
            return nil
        }

        let poster = item["img"] as? String ?? item["hImg"] as? String ?? ""

        // 副标题：优先推荐理由，其次「剧・限免13集」这类标签，最后简介
        var subtitle = item["subtitle"] as? String ?? ""
        if subtitle.isEmpty {
            subtitle = item["lbTexts"] as? String ?? ""
        }
        if subtitle.isEmpty {
            let desc = item["desc"] as? String ?? ""
            subtitle = String(desc.prefix(28))
        }

        // 角标：mark.text 是权益标签（"限免中" / "VIP"…）
        var badge = (item["mark"] as? [String: Any])?["text"] as? String ?? ""
        if badge.isEmpty {
            let topLeft = item["topLeftMark"] as? [String: Any] ?? [:]
            badge = (topLeft["text"] as? [String: Any])?["title"] as? String ?? ""
        }

        return VideoItem(
            showId: showId,
            videoId: videoId,
            title: title,
            subtitle: subtitle,
            poster: poster,
            duration: 0,
            sourceName: "优酷",
            isYouku: true,
            badge: badge
        )
    }
}
