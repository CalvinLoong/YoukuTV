import Foundation

/// mtop 请求的查询串构造器。
///
/// ## 为什么不能用 `URLComponents.queryItems`（实测踩坑，重要）
///
/// `URLComponents.queryItems` 对**值**不做完整百分号编码 —— `+`、`/`、`:` 等
/// 字符会原样出现在查询串里。而 mtop 服务端按
/// `application/x-www-form-urlencoded` 解码查询串，其中 `+` 被解释成**空格**。
///
/// 内置的 ckey（防盗链签名）里含多个 `+`，于是形成致命的错位：
///
/// | 环节 | 拿到的 data 字符串 |
/// |---|---|
/// | 客户端算签名 | `ckey = 140#o8foFD6ezzWioQo2+bhu4pN8s9…`（含 `+`） |
/// | 服务端收到 | `ckey = 140#o8foFD6ezzWioQo2 bhu4pN8s9…`（`+` 变成空格） |
///
/// 签名自然对不上 → 服务端返回 `FAIL_SYS_ILLEGAL_ACCESS:非法请求`，
/// 表现为「点进视频一直转圈、播不出来」。
///
/// 实测 A/B（同一份 ckey、同一组参数，只改编码方式）：
///
/// - `+` 编码成 `%2B` → `SUCCESS::调用成功`，**10 条播放流**
/// - `+` 裸传（Swift `URLComponents.queryItems` 的行为）
///   → `FAIL_SYS_ILLEGAL_ACCESS::非法请求`，**0 条流**
///
/// 登录接口没暴露这个问题，是因为它的 data 里恰好没有 `+`。
enum MTopQuery {
    /// RFC 3986 的 unreserved 集合：字母数字 + `-` `.` `_` `~`。
    ///
    /// 这套字符在「按 query 编码」和「按 query 解码」两个方向上都是恒等的，
    /// 不会被服务端二次解释。
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// 严格百分号编码一个查询值。
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// 把若干键值对拼成查询串（已编码）。
    static func make(_ items: [(name: String, value: String)]) -> String {
        items
            .map { "\(encode($0.name))=\(encode($0.value))" }
            .joined(separator: "&")
    }

    /// 构造 mtop 的 H5（JSONP）请求地址。
    ///
    /// 路径形如 `https://<host>/h5/<api>/<version>/?…`
    static func url(
        host: String,
        api: String,
        version: String,
        items: [(name: String, value: String)]
    ) -> URL? {
        guard var components = URLComponents(
            string: "https://\(host)/h5/\(api)/\(version)/"
        ) else {
            return nil
        }
        // ★ 用 percentEncodedQuery 而不是 queryItems —— 后者不会编码 `+`。
        components.percentEncodedQuery = make(items)
        return components.url
    }
}
