import SwiftUI

/// 应用状态机与数据编排。
///
/// ## 数据通道
///
/// - **搜索与推荐**：`search.youku.com/api/search`（免签名，已实测返回真实数据）
/// - **播放地址**：`un-acs.youku.com` 的 `mtop.youku.play.ups.appinfo.get`
///   （经实测：ckey 不绑定 vid，同一份凭据可取任意视频的播放地址）
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
    @Published private(set) var playbacks: [PlaybackInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEpisodes = false
    @Published private(set) var isLoadingPlayback = false
    @Published var errorMessage: String?
    @Published var searchKeyword = ""

    /// 当前节目的总集数（来自详情页）。
    private(set) var episodeTotal: Int = 0
    /// 当前节目的 vid（来自详情页，用于直接播放首集）。
    private(set) var currentVideoId: String = ""

    private let web = YoukuWebClient()
    private let ups = YoukuUpsClient()
    private let episodeClient = YoukuEpisodeClient()
    private let mtop = YoukuMTopClient()

    /// 播放器引用，由 ContentView 注入。
    @MainActor weak var player: PlayerController?

    // MARK: - 首页

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

    /// 加载剧集列表。
    ///
    /// 数据来源：优酷 H5 播放页内嵌的 `window.__INITIAL_DATA__`，
    /// 剧集在 `type == 10013` 的选集组件里，每条 item 的 `action_value` 就是 vid。
    /// 这条路不需要任何设备签名，实测可直接取到完整剧集（如《甄嬛传》76 集）。
    func loadEpisodes(for item: VideoItem) async {
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        do {
            let detail = try await episodeClient.detail(showId: item.showId)
            episodes = detail.episodes
            // 记录当前集 vid，供直接播放使用
            currentVideoId = detail.videoId
            if detail.episodeTotal > 0 {
                episodeTotal = detail.episodeTotal
            }
        } catch {
            episodes = []
        }
    }

    /// 发起播放：解析播放地址并交给播放器。
    func play(item: VideoItem, episode: Episode?) async {
        route = .player(item, episode)
        isLoadingPlayback = true
        playbacks = []
        defer { isLoadingPlayback = false }

        // 优先用选集里的 vid；没有就回落到详情页拿到的当前集 vid
        var vid: String = ""
        if let episodeVid = episode?.videoId, !episodeVid.isEmpty {
            vid = episodeVid
        } else if !item.videoId.isEmpty {
            vid = item.videoId
        } else if !currentVideoId.isEmpty {
            vid = currentVideoId
        }

        // 剧集还没加载完用户就点了播放 —— 现取一次详情
        if vid.isEmpty {
            if let detail = try? await episodeClient.detail(showId: item.showId) {
                vid = detail.videoId
                if episodes.isEmpty { episodes = detail.episodes }
                currentVideoId = detail.videoId
                episodeTotal = detail.episodeTotal
            }
        }

        guard !vid.isEmpty else {
            errorMessage = "该内容暂无可播放资源"
            return
        }
        currentVideoId = vid

        do {
            let list = try await ups.playback(for: vid, showId: item.showId)
            playbacks = list
            if let best = list.first {
                player?.play(best, title: episode?.title ?? item.title)
            } else if episode?.isVip == true {
                // 实测：VIP 剧集接口返回 SUCCESS 但 stream 为空，
                // 服务端校验会员权益后才下发地址。本项目有意不做会员校验。
                errorMessage = "本集为优酷会员内容，需要会员账号才能播放"
            } else {
                errorMessage = "未找到可播放资源"
            }
        } catch {
            errorMessage = (error as? YoukuError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 切换清晰度。
    func selectQuality(_ info: PlaybackInfo) {
        player?.play(info, title: currentTitle)
    }

    private var currentTitle: String = ""
}
