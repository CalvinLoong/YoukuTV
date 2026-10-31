import Foundation

/// 集成验证工具（macOS 命令行）。
///
/// 复用 App 里**同一份** Swift 源码，在开发机上直接跑真实网络请求。
/// 目的：装机前就把「协议错」和「UI 错」分开定位。
///
/// 覆盖：
/// 1. `MTopQuery` 严格百分号编码（`+` 必须变成 `%2B`）
/// 2. `YoukuSSR` 解析（含字符串内大括号、JavaScript `undefined`）
/// 3. `YoukuUpsClient` 真实取流（验证播放报错已修）
/// 4. `YoukuHomeClient` 真实首页推荐
/// 5. `YoukuHistoryStore` 读写
///
/// 运行：`bash tools/集成验证/跑验证.sh`

// MARK: - 断言

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)  \(detail)")
    }
}

// MARK: - 1. 编码

print("\n=== 1. MTopQuery 严格百分号编码 ===")
let ckey = UpsCredential.builtinCkeyForTest
check(ckey.contains("+"), "内置 ckey 确实含 `+`（编码问题的触发条件）")
let encoded = MTopQuery.encode(ckey)
check(!encoded.contains("+"), "编码后不再有裸 `+`", encoded.prefix(60).description)
check(encoded.contains("%2B"), "`+` 被编码成 `%2B`")
check(MTopQuery.encode("a b") == "a%20b", "空格编码成 %20 而不是 +")
check(MTopQuery.encode("a/b=c&d") == "a%2Fb%3Dc%26d", "保留字符全部转义")

let url = MTopQuery.url(host: "h", api: "a", version: "1.0", items: [("data", ckey)])
let raw = url?.absoluteString ?? ""
check(!raw.contains("+"), "完整查询串里没有裸 `+`", raw.prefix(120).description)
check(raw.contains("%2B"), "完整查询串里有 %2B")

// 对照：URLComponents.queryItems 的行为（这是旧代码的写法）
var legacy = URLComponents(string: "https://h/p")!
legacy.queryItems = [.init(name: "data", value: ckey)]
check(legacy.percentEncodedQuery?.contains("+") == true,
      "对照：URLComponents.queryItems 确实会漏掉 `+` 的编码（旧代码的病根）")

// MARK: - 2. SSR 解析

print("\n=== 2. YoukuSSR 解析 ===")
let sample = """
{"a":"含 } 和 { 的字符串","b":undefined,"c":{"d":[1,2,3]},"e":"undefined 不是 null"}
"""
let cleaned = YoukuSSR.replacingUndefinedOutsideStrings(sample)
check(cleaned.contains("\"b\":null"), "字符串外的 undefined → null")
check(cleaned.contains("\"e\":\"undefined 不是 null\""), "字符串内的 undefined 不被动")
let obj = YoukuSSR.extractInitialData("<script>window.__INITIAL_DATA__ = \(sample);</script>")
check(obj != nil, "能从 HTML 中提取并解析 __INITIAL_DATA__")
check((obj?["c"] as? [String: Any])?["d"] as? [Int] == [1, 2, 3], "嵌套结构完整")

// MARK: - 3. ups 取流

print("\n=== 3. YoukuUpsClient 真实取流（验证播放报错已修）===")
let vid = "XNjU3MDkzMzMyOA=="   // 优酷首页当前推荐的 vid
let ups = YoukuUpsClient()
do {
    let list = try await ups.playback(for: vid)
    check(!list.isEmpty, "取到播放地址", "list.count=\(list.count)")
    if let best = list.first {
        print("     · 首选清晰度：\(best.quality.rawValue)  类型：\(best.streamType)")
        print("     · 地址：\(best.url.absoluteString.prefix(100))")
    }
    // 主播放列表是落盘的本地文件（file://），所以单独挑一条 http 流来验
    if let http = list.first(where: { $0.url.scheme == "http" }) {
        print("     · 直连流：\(http.quality.rawValue)  \(http.url.absoluteString.prefix(90))")
        var request = URLRequest(url: http.url)
        for (k, v) in http.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        check(code == 200, "直连流 HTTP 200", "code=\(code)")
        let text = String(data: data.prefix(64), encoding: .utf8) ?? ""
        check(text.contains("#EXTM3U"), "返回的是 m3u8 清单", text.prefix(40).description)
    } else {
        check(false, "取到可直连的 http 流")
    }
    // 主播放列表（落盘文件）里的变体地址必须是绝对路径，否则 AVPlayer 加载不了
    if let master = list.first(where: { $0.url.isFileURL }) {
        let body = (try? String(contentsOf: master.url, encoding: .utf8)) ?? ""
        // ★ 注意：Swift 里 "\r\n" 是**一个** Character（CRLF 图形簇），
        //   用 split(separator: "\n") 在 CRLF 边界上切不开 —— 必须用
        //   CharacterSet.newlines 才能按行拆。
        let variants = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http") }
        check(!variants.isEmpty, "主播放列表里有变体流", "count=\(variants.count)")
        if let first = variants.first, let vurl = URL(string: String(first)) {
            var request = URLRequest(url: vurl)
            for (k, val) in master.headers { request.setValue(val, forHTTPHeaderField: k) }
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            check(code == 200, "变体流 HTTP 200", "code=\(code)")
        }
    }
} catch {
    check(false, "取流失败", "\(error)")
}

// MARK: - 4. 首页推荐

print("\n=== 4. YoukuHomeClient 真实首页推荐 ===")
let home = YoukuHomeClient()
do {
    let result = try await home.loadHome()
    check(!result.channels.isEmpty, "拿到频道导航", "count=\(result.channels.count)")
    check(!result.rows.isEmpty, "拿到推荐行", "count=\(result.rows.count)")
    if let c = result.channels.first(where: { $0.title == "电视剧" }) {
        check(c.id == "WEBTV", "频道 id 正确", c.id)
    } else {
        check(false, "导航里有「电视剧」")
    }
    let total = result.rows.reduce(0) { $0 + $1.items.count }
    check(total > 20, "推荐内容总量充足", "total=\(total)")
    for row in result.rows.prefix(3) {
        print("     · \(row.title)：\(row.items.count) 项，首项「\(row.items.first?.title ?? "-")」")
    }
    // 关键：推荐项必须自带 vid，否则点开播不了
    let withVid = result.rows.flatMap(\.items).filter { !$0.videoId.isEmpty }
    check(!withVid.isEmpty, "推荐项自带可播 vid", "\(withVid.count) 个")
    // 海报
    let withPoster = result.rows.flatMap(\.items).filter { !$0.poster.isEmpty }
    check(!withPoster.isEmpty, "推荐项自带海报", "\(withPoster.count) 个")
} catch {
    check(false, "首页加载失败", "\(error)")
}

// MARK: - 5. 历史记录

print("\n=== 5. YoukuHistoryStore 读写 ===")
let store = YoukuHistoryStore()
await store.clear()
await store.record(showId: "abc123", videoId: "XVTEST", title: "测试节目",
                   poster: "http://x/y.jpg", subtitle: "第1集", position: 120, duration: 2400)
await store.record(showId: "def456", videoId: "XVTEST2", title: "另一个节目",
                   poster: "", subtitle: "", position: 0, duration: 0)
let entries = await store.all()
check(entries.count == 2, "写入两条历史", "count=\(entries.count)")
check(entries.first?.title == "另一个节目", "按最近观看倒序")
check(entries.contains { $0.id == "abc123" && $0.position == 120 }, "进度已保存")
await store.remove(entries[0])
check(await store.all().count == 1, "删除一条生效")
await store.clear()
check(await store.all().isEmpty, "清空生效")

// MARK: - 6. 端到端：首页推荐项 → 直接取流能播

print("\n=== 6. 端到端：首页推荐项直接取流 ===")
do {
    let result = try await home.loadHome()
    // 拿第一条推荐项的 vid —— 这就是用户在电视上点「播放」时走的那条路
    guard let firstItem = result.rows.flatMap(\.items).first(where: { !$0.videoId.isEmpty }) else {
        check(false, "首页有带 vid 的推荐项")
        throw YoukuError.decodingFailed("无可测推荐项")
    }
    print("     · 测项：「\(firstItem.title)」 vid=\(firstItem.videoId)")

    let list = try await ups.playback(for: firstItem.videoId, showId: firstItem.showId)
    check(!list.isEmpty, "首页推荐的 vid 直接取到播放地址", "count=\(list.count)")
    if let best = list.first {
        print("     · 首选：\(best.quality.rawValue)  \(best.streamType)  \(best.url.absoluteString.prefix(80))")
    }
    // 至少要有一条能被 AVPlayer 直接加载的地址（http 直连或本地主播放列表）
    let playable = list.first { $0.url.scheme == "http" || $0.url.isFileURL }
    check(playable != nil, "存在可直接交给 AVPlayer 的地址")
} catch {
    check(false, "端到端取流失败", "\(error)")
}

// MARK: - 汇总

print("\n" + String(repeating: "─", count: 60))
if failures == 0 {
    print("✅ 全部通过：\(checks) 项检查")
} else {
    print("❌ 失败 \(failures) / \(checks) 项")
}
exit(failures == 0 ? 0 : 1)
