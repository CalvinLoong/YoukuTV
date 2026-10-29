import Foundation
import AVFoundation
import AVKit

/// 播放器控制器。负责 AVPlayer 生命周期与 tvOS 焦点友好的播放控制。
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var currentTitle: String = ""

    let player = AVPlayer()

    /// 状态观察者，用强引用保活（KVO 的 observer 不会被自动持有）。
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let obs = statusObservation {
            player.currentItem?.removeObserver(obs)
        }
    }

    /// 播放一个已解析的播放源。
    func play(_ info: PlaybackInfo, title: String) {
        errorMessage = nil
        currentTitle = title
        isLoading = true

        let asset = AVURLAsset(
            url: info.url,
            options: [AVURLAssetHTTPHeaderFieldsKey: info.headers]
        )
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        // 观察播放状态：就绪则起播，失败则报错
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
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
