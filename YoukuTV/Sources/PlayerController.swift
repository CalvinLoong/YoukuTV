import Foundation
import AVFoundation

/// 播放地址解析器。
///
/// 逆向来源：CIBN 酷喵 TV `com.cibn.tv`
/// - m3u8 播放地址形态证据: com.youku.tv.playerChecker.PlayerCheckerActivity_
///   `sys_1080p_h265|https://galitv.alicdn.com/ott/play_demo/...`
/// - 清晰度标识: `sys_4k` / `sys_1080p_h265` / `dna_1080p_h264` / `sys_1080p_h264`
///   (证据: PlayerCheckerActivity_ 与 PlayLabActivity_ 字符串表)
struct PlaybackResolver {
    /// 清晰度枚举，按 TV 端内置标识排序。
    enum Quality: String, CaseIterable, Identifiable {
        case fourK = "4K"
        case hd1080p = "1080P"
        case hd720p = "720P"
        case sd = "标清"

        var id: String { rawValue }

        /// TV 端清晰度标识（来自 PlayerCheckerActivity_ 字符串表）
        var playerToken: String {
            switch self {
            case .fourK: return "sys_4k"
            case .hd1080p: return "sys_1080p_h265"
            case .hd720p: return "sys_720p_h264"
            case .sd: return "sys_540p_h264"
            }
        }
    }

    struct PlaybackInfo {
        let url: URL
        let quality: Quality
        let headers: [String: String]
    }

    /// 构造播放请求头。TV 端对 CDN 播放会带鉴权与 UA。
    static func defaultHeaders(referer: String = "https://www.youku.com/") -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Apple TV; CPU like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer": referer,
            "Accept": "*/*"
        ]
    }

    /// 从 mtop 播放信息响应中解析出 m3u8 地址。
    ///
    /// 优酷播放信息结构里，地址以 `streamType|qualityToken|url` 形式出现在
    /// `data.stream[].stream[].segs` 或 `data.common.urlList[]` 中。
    static func resolve(from data: [String: Any]) -> PlaybackInfo? {
        // 1) 优先取 common.urlList（主地址）
        if let common = data["common"] as? [String: Any],
           let urlList = common["urlList"] as? [[String: Any]],
           let first = urlList.first,
           let raw = first["url"] as? String,
           let url = URL(string: raw) {
            let token = first["quality"] as? String ?? first["streamType"] as? String ?? ""
            return PlaybackInfo(
                url: url,
                quality: quality(from: token),
                headers: defaultHeaders()
            )
        }

        // 2) 兜底：遍历 data 下的所有 m3u8 字符串
        //    注意：地址形如 playlist/m3u8?vid=...，m3u8 后可能带查询参数
        func findM3U8(_ any: Any) -> String? {
            if let s = any as? String, s.contains("m3u8") { return s }
            if let dict = any as? [String: Any] {
                for (_, v) in dict { if let r = findM3U8(v) { return r } }
            }
            if let arr = any as? [Any] {
                for v in arr { if let r = findM3U8(v) { return r } }
            }
            return nil
        }
        guard let raw = findM3U8(data), let url = URL(string: raw) else { return nil }
        return PlaybackInfo(url: url, quality: .hd1080p, headers: defaultHeaders())
    }

    private static func quality(from token: String) -> Quality {
        let t = token.lowercased()
        if t.contains("4k") { return .fourK }
        if t.contains("1080") { return .hd1080p }
        if t.contains("720") { return .hd720p }
        return .sd
    }
}

/// 播放器控制器。负责 AVPlayer 生命周期与 tvOS 焦点友好的播放控制。
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var currentTitle: String = ""

    let player = AVPlayer()

    private var timeObserver: Any?

    init() {
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
    }

    /// 播放一个已解析的播放源。
    func play(_ info: PlaybackResolver.PlaybackInfo, title: String) {
        errorMessage = nil
        currentTitle = title
        isLoading = true

        let asset = AVURLAsset(
            url: info.url,
            options: [AVURLAssetHTTPHeaderFieldsKey: info.headers]
        )
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        // 监听首帧可播，隐藏加载态
        let statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.player.play()
                    self.isPlaying = true
                case .failed:
                    self.isLoading = false
                    self.errorMessage = item.error?.localizedDescription ?? "播放失败"
                default:
                    break
                }
            }
        }
        // 保持 observer 存活
        objc_setAssociatedObject(item, "statusObs", statusObs, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
    }

    /// 快进 / 快退（秒）。
    func skip(_ seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 1)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
