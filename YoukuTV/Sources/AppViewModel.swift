import SwiftUI

/// 应用状态机与数据编排。
///
/// 数据通道说明：
/// - 搜索与推荐走优酷 H5 接口 `search.youku.com/api/search`（已实测返回真实数据，免设备指纹签名）
/// - mtop 通道保留用于 TV 端专有接口（已逆向出协议，但服务端要求 SecurityGuard 设备指纹，数据接口会返回空）
@MainActor
final class AppViewModel: ObservableObject {
    enum Route: Equatable {
        case home
        case detail(VideoItem)
        case player(VideoItem, Episode?)
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let items: [VideoItem]
    }

    // MARK: - 状态

    @Published var route: Route = .home
    @Published private(set) var rows: [Row] = []
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEpisodes = false
    @Published var errorMessage: String?
    @Published var searchKeyword = ""
    @Published var isSearchFocused = false

    private let web = YoukuWebClient()
    private let mtop = YoukuMTopClient()

    // MARK: - 启动

    /// 加载首页推荐。
    func bootstrap() async {
        guard rows.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var collected: [Row] = []
        for (title, keyword) in YoukuWebClient.hotKeywords {
            do {
                let items = try await web.search(keyword: keyword, page: 1)
                if !items.isEmpty {
                    collected.append(Row(id: keyword, title: title, items: items))
                }
            } catch {
                // 单行失败不影响其他行
                continue
            }
        }
        if collected.isEmpty {
            errorMessage = "无法连接优酷接口，请检查网络"
        } else {
            rows = collected
        }
    }

    /// 执行搜索。
    func performSearch() async {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            await bootstrap()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await web.search(keyword: keyword, page: 1)
            rows = [Row(id: "search-\(keyword)", title: "搜索 “\(keyword)”", items: items)]
            if items.isEmpty {
                errorMessage = "没有找到 “\(keyword)” 相关内容"
            }
        } catch {
            errorMessage = (error as? YoukuError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 导航

    func openDetail(_ item: VideoItem) {
        route = .detail(item)
    }

    func loadEpisodes(for item: VideoItem) async {
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        do {
            episodes = try await mtop.episodes(showId: item.showId, videoId: item.videoId)
        } catch {
            episodes = []
        }
    }

    /// 发起播放。
    func play(item: VideoItem, episode: Episode?) {
        route = .player(item, episode)
    }

    /// 解析播放地址。
    func resolvePlayback(for item: VideoItem, episode: Episode?) async -> PlaybackResolver.PlaybackInfo? {
        do {
            let data = try await mtop.playInfo(showId: item.showId, videoId: episode?.videoId ?? item.videoId)
            return PlaybackResolver.resolve(from: data)
        } catch {
            errorMessage = (error as? YoukuError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}
