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

            // ---- 过滤非优酷自有内容 ----
            //
            // 实测：搜索接口会混入外站内容（腾讯/咪咕等），它们的 showId
            // 是外站 ID。拿这种 showId 请求 list.youku.com 会**静默跳到
            // 完全不相干的其他节目**（搜「庆余年」打开是《知否知否》）。
            // isYouku == 1 表示优酷自有内容，0 表示外站，-1 表示来源未知。
            let isYouku = (cd["isYouku"] as? Int) == 1
            guard isYouku else { return nil }

            // ---- showId 有效性校验 ----
            //
            // 服务端偶尔返回损坏的 showId（实测「庆余年」的 showId 含
            // U+FFFD 替换字符 efbfbd），这类 ID 同样会跳到别的节目。
            // 优酷正常 showId 是 20 位小写十六进制。
            let rawShowId = cd["showId"] as? String ?? cd["realShowId"] as? String ?? ""
            guard Self.isValidShowId(rawShowId) else { return nil }

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

            let sourceName = cd["sourceName"] as? String ?? "优酷"

            return VideoItem(
                showId: rawShowId,
                videoId: "",
                title: title,
                subtitle: subtitle,
                poster: poster,
                duration: 0,
                sourceName: sourceName,
                isYouku: isYouku
            )
        }
    }

    /// 校验 showId 格式。
    ///
    /// 优酷正常 showId 是 20 位小写十六进制字符串。
    ///
    /// 但服务端有相当比例的条目返回**被 UTF-8 替换字符污染**的 ID
    /// （实测「动物世界」搜索结果 35 条优酷内容里有 9 条如此，形如
    /// `43efbfbd51efbfbdefbf`）。`efbfbd` 本身是合法十六进制字符，
    /// 所以单靠字符集判断拦不住，必须显式排除这个序列。
    /// 这类 ID 指向错误内容，必须丢弃。
    static func isValidShowId(_ id: String) -> Bool {
        guard id.count == 20 else { return false }
        guard !id.contains("efbfbd") else { return false }
        return id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
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
