import SwiftUI
import AVKit

/// 应用主视图：NavigationStack 驱动的多级导航。
///
/// ## 为什么要用 NavigationStack 的 path
///
/// tvOS 遥控器上的「返回 / Menu」键，只有当视图栈是 SwiftUI 的
/// `NavigationStack` 时才会生效 —— 系统需要知道「栈里还有上一页可以弹」。
///
/// 之前的实现用自定义的 `route` 枚举在根视图里 `switch`，
/// 看上去是「三个页面」，实际上**只有一个视图**，
/// 遥控器按返回键时系统发现没有可弹出的目标，于是毫无反应 —— 表现为
/// 「进入视频页后回不去首页」。
///
/// 现在改成：
/// - `@State private var path: [Route]` 持有导航栈
/// - `NavigationStack(path: $path)` 由系统接管推入/弹出
/// - 详情页与播放页通过 `.navigationDestination` 注册
///
/// 这样遥控器的返回键由系统自动处理，无需手写。
struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @StateObject private var player = PlayerController()
    /// 搜索框焦点（tvOS 上用遥控器唤起键盘）
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack(path: $model.path) {
            ZStack {
                Palette.background.ignoresSafeArea()
                homeView
            }
            .navigationDestination(for: AppViewModel.Route.self) { route in
                switch route {
                case .home:
                    // 根页面不会出现在栈顶，占位以满足编译器
                    Color.clear
                case .detail(let item):
                    DetailView(item: item, model: model, player: player)
                case .player(let item, let episode):
                    PlayerView(item: item, episode: episode, player: player, model: model)
                }
            }
        }
        .task { await model.bootstrap() }
        .onAppear { model.player = player }
        // 登录面板用 overlay 实现而不是 sheet：
        // tvOS 的 sheet 在遥控器上的焦点行为与 iOS 不同，
        // overlay 可以完全掌控焦点，不会出现「焦点跑丢、按钮点不动」。
        .overlay {
            if model.isLoginSheetPresented {
                LoginSheet(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isLoginSheetPresented)
    }

    // MARK: - 首页

    private var homeView: some View {
        VStack(spacing: 0) {
            topBar

            if let error = model.errorMessage, model.rows.isEmpty {
                ErrorView(message: error) { Task { await model.bootstrap() } }
            } else if model.isLoading && model.rows.isEmpty {
                LoadingView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(model.rows) { row in
                            PosterRow(title: row.title, items: row.items) { item in
                                model.openDetail(item)
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.accent)
                Text("Youku TV")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.primaryText)
            }

            // 分类快捷入口（走已验证可用的优酷 H5 搜索通道）
            ForEach(YoukuWebClient.hotKeywords, id: \.title) { entry in
                Button {
                    model.searchKeyword = entry.keyword
                    Task { await model.performSearch() }
                } label: {
                    Text(entry.title)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Palette.secondaryText)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // 登录入口
            AccountButton(model: model)

            // 搜索输入
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.tertiaryText)
                TextField("搜索影片", text: $model.searchKeyword)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.primaryText)
                    .focused($isSearchFocused)
                    .onSubmit { Task { await model.performSearch() } }
                if !model.searchKeyword.isEmpty {
                    Button {
                        model.searchKeyword = ""
                        Task { await model.performSearch() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.surface)
            .clipShape(Capsule())
            .frame(width: 320)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 22)
    }
}

/// 详情页。
struct DetailView: View {
    let item: VideoItem
    @ObservedObject var model: AppViewModel
    @ObservedObject var player: PlayerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 30) {
                    poster

                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.title)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(Palette.primaryText)

                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.system(size: 18))
                                .foregroundStyle(Palette.secondaryText)
                        }

                        HStack(spacing: 14) {
                            // 权益角标（VIP / 付费 / 独播 / 预告）
                            if !item.badge.isEmpty {
                                Text(item.badge)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Palette.accentWarm)
                                    .clipShape(Capsule())
                            }

                            Button {
                                Task { await model.play(item: item, episode: nil) }
                            } label: {
                                Label("播放", systemImage: "play.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .padding(.horizontal, 26)
                                    .padding(.vertical, 12)
                                    .background(Palette.accent)
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Text(item.sourceName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Palette.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Palette.surfaceRaised)
                                .clipShape(Capsule())
                        }

                        if model.isLoadingEpisodes {
                            ProgressView().controlSize(.small)
                        } else if model.episodes.isEmpty {
                            HStack(spacing: 16) {
                                Text(model.hasEpisodeList
                                     ? "本节目暂无选集"
                                     : "选集列表加载失败")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Palette.tertiaryText)
                                // 优酷的 SSR 数据是间歇性返回的，重试有机会拿到
                                if !model.hasEpisodeList {
                                    Button("重试") {
                                        Task { await model.loadEpisodes(for: item) }
                                    }
                                    .font(.system(size: 15, weight: .medium))
                                    .buttonStyle(.bordered)
                                    .tint(Palette.accent)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text("剧集 · \(model.episodes.count)")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Palette.primaryText)
                                // 播放页声明的总集数可能大于实际解析出的数量
                                if model.episodeTotal > model.episodes.count {
                                    Text("共 \(model.episodeTotal) 集")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Palette.tertiaryText)
                                }
                            }
                        }
                    }
                }

                if !model.episodes.isEmpty {
                    EpisodeGrid(episodes: model.episodes) { ep in
                        Task { await model.play(item: item, episode: ep) }
                    }
                }
            }
            .padding(60)
        }
        .task { await model.loadEpisodes(for: item) }
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised)
            if let url = URL(string: item.poster), !item.poster.isEmpty {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(Palette.tertiaryText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(Palette.tertiaryText)
            }
        }
        .frame(width: 300, height: 169)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 播放页。原生 AVPlayer 直连优酷 m3u8。
///
/// tvOS 自 9.0 起完全移除了 WebKit（无 WKWebView / SFSafariViewController），
/// 因此播放地址必须由 App 直接调用优酷 ups 接口获取。
struct PlayerView: View {
    let item: VideoItem
    let episode: Episode?
    @ObservedObject var player: PlayerController
    @ObservedObject var model: AppViewModel

    @State private var showQualityPicker = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = player.errorMessage ?? model.errorMessage {
                VStack(spacing: 24) {
                    ErrorView(message: error) {
                        Task { await model.play(item: item, episode: episode) }
                    }

                    // 返回详情页，避免用户卡在黑屏
                    Button {
                        model.goBackToDetail()
                    } label: {
                        Label("返回详情", systemImage: "chevron.left")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            } else {
                VideoPlayer(player: player.player)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                        if let episode {
                            Text(episode.title)
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    Spacer()

                    if model.isLoadingPlayback {
                        ProgressView().controlSize(.large)
                    }

                    // 清晰度选择
                    if !model.playbacks.isEmpty {
                        Button {
                            showQualityPicker.toggle()
                        } label: {
                            Label(
                                model.playbacks.first?.quality.rawValue ?? "清晰度",
                                systemImage: "slider.horizontal.3"
                            )
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 40)
                Spacer()
            }
        }
        .overlay {
            if showQualityPicker {
                qualitySheet
            }
        }
        .task {
            await model.play(item: item, episode: episode)
        }
    }

    private var qualitySheet: some View {
        VStack(spacing: 24) {
            Text("选择清晰度")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.primaryText)

            VStack(spacing: 12) {
                ForEach(model.playbacks) { info in
                    Button {
                        model.selectQuality(info)
                        showQualityPicker = false
                    } label: {
                        HStack {
                            Text(info.quality.rawValue)
                                .font(.system(size: 18, weight: .medium))
                            Spacer()
                            if info.streamType == "auto" {
                                Text("多码率")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            if model.playbacks.first?.id == info.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                        .foregroundStyle(Palette.primaryText)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .frame(width: 340)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.card)
                }
            }

            Button("取消") { showQualityPicker = false }
                .font(.system(size: 17))
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(50)
        .background(Palette.background.opacity(0.97))
    }
}
