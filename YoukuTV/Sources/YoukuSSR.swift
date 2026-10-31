import Foundation

/// 优酷网页 SSR（`window.__INITIAL_DATA__`）解析工具。
///
/// ## 为什么需要单独一个文件
///
/// 优酷的网页把首屏数据以 SSR 形式内嵌在 HTML 里：
///
/// ```html
/// <script>window.__INITIAL_DATA__ = { ... 几十万字符 ... };</script>
/// ```
///
/// 这份数据同时是**首页推荐**和**播放页选集列表**的来源。
///
/// ## 两个实测踩过的坑
///
/// 1. **括号配平必须区分「字符串内」与「字符串外」**。
///    早期实现只按字符数 `{` / `}`，一旦 JSON 字符串里出现大括号
///    （优酷的 `trackInfo` 里就有），就会提前截断、解析出残缺 JSON。
///
/// 2. **数据里混着 JavaScript 的 `undefined`**（例如 `"PUM":undefined`）。
///    标准 JSON 解析器会直接报错 `Expecting value`。
///    必须先把**字符串之外**的 `undefined` 替换成 `null`。
///    注意不能全局替换 —— 字符串值里出现 "undefined" 是合法内容。
enum YoukuSSR {
    /// 从 HTML 中提取 `__INITIAL_DATA__` 并解析成字典。
    ///
    /// - Returns: 解析后的根对象；页面结构变化或数据不完整时返回 `nil`。
    static func extractInitialData(_ html: String) -> [String: Any]? {
        guard let marker = html.range(of: "__INITIAL_DATA__") else { return nil }
        guard let brace = html[marker.upperBound...].firstIndex(of: "{") else { return nil }
        guard let end = matchingBraceEnd(in: html, from: brace) else { return nil }

        let raw = String(html[brace..<end])
        let cleaned = replacingUndefinedOutsideStrings(raw)
        return try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any]
    }

    /// 找到与 `start` 处 `{` 配对的 `}` 的结束位置。
    ///
    /// 扫描时跟踪「是否在字符串内」与「是否被反斜杠转义」，
    /// 保证字符串里出现的大括号不会影响配平。
    static func matchingBraceEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return text.index(after: index)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 把**字符串之外**的 `undefined` 替换成 `null`。
    ///
    /// 用 UTF-8 字节处理而不是 Character 逐个遍历 —— 首页 SSR 有 60 万字符，
    /// 用字节数组快一个数量级。
    static func replacingUndefinedOutsideStrings(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)

        var i = 0
        var inString = false
        var escaped = false

        while i < bytes.count {
            let b = bytes[i]
            if inString {
                out.append(b)
                if escaped {
                    escaped = false
                } else if b == 0x5C {      // 反斜杠
                    escaped = true
                } else if b == 0x22 {      // 双引号
                    inString = false
                }
                i += 1
                continue
            }

            if b == 0x22 {                 // 进入字符串
                inString = true
                out.append(b)
                i += 1
                continue
            }

            // 匹配字面量 undefined
            if b == 0x75, i + 9 <= bytes.count,
               bytes[i] == 0x75,
               String(bytes: bytes[i..<(i + 9)], encoding: .utf8) == "undefined" {
                out.append(contentsOf: Array("null".utf8))
                i += 9
                continue
            }

            out.append(b)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
