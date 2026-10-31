import Foundation

/// YoukuLoginClient 依赖的 YoukuError。
///
/// App 里这个枚举定义在 YoukuMTopClient.swift，但那个文件还带一大堆
/// tvOS 侧的内容，为了让联调工具能单独编译，这里复制一份最小实现。
///
/// ⚠️ 改动时必须与 YoukuTV/Sources/YoukuMTopClient.swift 里的定义保持一致，
///    否则联调通过但 App 编译不过就白测了。
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
