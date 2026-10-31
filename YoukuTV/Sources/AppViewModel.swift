import SwiftUI

/// 应用状态机与数据编排。
///
/// ## 数据通道
///
/// - **搜索与推荐**：`search.youku.com/api/search`（免签名，已实测返回真实数据）
/// - **播放地址**：`un-acs.youku.com` 的 `mtop.youku.play.ups.appinfo.get`
///   （经实测：ckey 不绑定 vid，同一份凭据可取任意视频的播放地址）
/// - **扫码登录**：`acs.youku.com` 的 Havana 链路
///   （`mtop.taobao.commonuse.mloginService.genQrCode` / `.qrcodelogin`）
@MainActor
final class AppViewModel: ObservableObject {
    /// 导航目标。必须是 `Hashable` 才能放进 `NavigationStack` 的 path。
    enum Route: Hashable {
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

    /// 导航栈。系统据此渲染层级，遥控器返回键由系统接管。
    @Published var path: [Route] = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var playbacks: [PlaybackInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEpisodes = false
    @Published private(set) var isLoadingPlayback = false
    @Published var errorMessage: String?
    @Published var searchKeyword = ""

    /// 登录态
    @Published private(set) var credentials: YoukuCredentials?
    @Published private(set) var isLoginSheetPresented = false
    /// 扫码登录页的当前阶段，用于显示不同提示
    @Published private(set) var loginStage: LoginStage = .idle

    /// 扫码登录的阶段。
    enum LoginStage: Equatable {
        /// 未开始
        case idle
        /// 正在生成二维码
        case preparing
        /// 等待用户扫码
        case waitingScan(qrText: String)
        /// 已扫码，等待手机确认
        case scanned
        /// 登录成功
        case success
        /// 出错
        case failed(String)
    }

    /// 当前节目的总集数（来自详情页）。
    private(set) var episodeTotal: Int = 0
    /// 当前节目的 vid（来自详情页，用于直接播放首集）。
    private(set) var currentVideoId: String = ""
    /// 是否成功取到选集列表（区分"取不到"与"确实没有选集"）。
    private(set) var hasEpisodeList: Bool = false

    private let web = YoukuWebClient()
    private let ups = YoukuUpsClient()
    private let episodeClient = YoukuEpisodeClient()
    private let loginClient = YoukuLoginClient()

    /// 播放器引用，由 ContentView 注入。
    @MainActor weak var player: PlayerController?

    /// 登录凭据的本地持久化 key
    private static let credentialsKey = "youku.credentials"

    init() {
        // 恢复上次的登录态
        if let data = UserDefaults.standard.data(forKey: Self.credentialsKey),
           let saved = try? JSONDecoder().decode(YoukuCredentials.self, from: data),
           saved.isValid {
            credentials = saved
        }
    }

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

    /// 打开详情页。
    func openDetail(_ item: VideoItem) {
        // 已在详情页时不要重复压栈
        if case .detail(let current) = path.last, current == item { return }
        path.append(.detail(item))
    }

    /// 从播放页回到详情页。
    func goBackToDetail() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    // MARK: - 登录

    /// 是否已登录。
    var isLoggedIn: Bool { credentials?.isValid == true }

    /// 打开登录面板。
    func presentLogin() {
        isLoginSheetPresented = true
        loginStage = .preparing
    }

    /// 关闭登录面板。
    func dismissLogin() {
        isLoginSheetPresented = false
        loginStage = .idle
    }

    /// 退出登录。
    func logout() {
        credentials = nil
        UserDefaults.standard.removeObject(forKey: Self.credentialsKey)
    }

    /// 生成二维码并开始轮询。
    func startQRLogin() async {
        loginStage = .preparing
        do {
            let qr = try await loginClient.generateQRCode()
            loginStage = .waitingScan(qrText: qr.url)
            await pollUntilFinished(token: qr.pollToken)
        } catch {
            loginStage = .failed((error as? YoukuError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// 轮询登录状态，直到成功、超时或出错。
    private func pollUntilFinished(token: String) async {
        // 最多轮询 5 分钟（二维码有效期通常 3~5 分钟）
        let deadline = Date().addingTimeInterval(300)
        var interval = 3.0

        while Date() < deadline {
            // 二维码需要用户在手机上确认，等待间隔由服务端给出（3 秒）
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            do {
                let result = try await loginClient.pollLogin(token: token)
                switch result {
                case .waiting:
                    loginStage = .waitingScan(qrText: "")
                case .scanned:
                    loginStage = .scanned
                case .success(let creds):
                    credentials = creds
                    if let data = try? JSONEncoder().encode(creds) {
                        UserDefaults.standard.set(data, forKey: Self.credentialsKey)
                    }
                    loginStage = .success
                    // 登录成功后把凭据同步给 ups 客户端，让会员内容可播
                    await ups.apply(credentials: creds)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    dismissLogin()
                    return
                }
            } catch {
                // 单次轮询失败不终止整体流程（可能是网络抖动），继续重试
                loginStage = .failed((error as? YoukuError)?.errorDescription ?? error.localizedDescription)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        if loginStage != .success {
            loginStage = .failed("二维码已过期，请重新获取")
        }
    }

    // MARK: - 选集与播放

    /// 加载剧集列表。
    ///
    /// 数据来源：优酷 H5 播放页内嵌的 `window.__INITIAL_DATA__`，
    /// 剧集在 `type == 10013` 的选集组件里，每条 item 的 `action_value` 就是 vid。
    ///
    /// **注意**：优酷对 HTML 页面访问有风控，频繁请求会返回验证码页
    /// （`window._config_.action == "captcha"`）。因此这条路径是**补充**而非必需：
    /// 播放本身不依赖它 —— 搜索接口的 `leftButtonDTO` 已经带了 vid，
    /// 拿不到选集也照样能播放当前集。
    func loadEpisodes(for item: VideoItem) async {
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        do {
            let detail = try await episodeClient.detail(showId: item.showId)
            episodes = detail.episodes
            hasEpisodeList = detail.hasEpisodeList
            // 记录当前集 vid，供直接播放使用
            currentVideoId = detail.videoId
            if detail.episodeTotal > 0 {
                episodeTotal = detail.episodeTotal
            }
        } catch {
            // 拿不到选集不影响播放：搜索结果里已经带了 vid
            episodes = []
            hasEpisodeList = false
        }
    }

    /// 发起播放：解析播放地址并交给播放器。
    func play(item: VideoItem, episode: Episode?) async {
        // 压入播放页（若已在播放页则不重复压栈）
        if case .player(let curItem, _) = path.last, curItem == item {
            // 已经在播放页，仅切换剧集
        } else {
            path.append(.player(item, episode))
        }
        isLoadingPlayback = true
        playbacks = []
        errorMessage = nil
        player?.errorMessage = nil
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
            } else if item.badge == "VIP" || item.badge == "付费" || episode?.isVip == true {
                // 实测：会员内容在未登录状态下接口返回 SUCCESS 但 stream 为空，
                // 服务端校验会员权益后才下发地址。登录后即可正常播放。
                errorMessage = isLoggedIn
                    ? "「\(item.title)」需要开通优酷会员才能播放"
                    : "「\(item.title)」为会员内容，请先登录优酷账号"
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
