import SwiftUI
import AVKit

/// 应用主视图：顶部 Tab 切换 + 内容区。
struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @StateObject private var player = PlayerController()
    /// 搜索框焦点（tvOS 上用遥控器唤起键盘）
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                switch model.route {
                case .home:
                    homeView
                case .detail(let item):
                    DetailView(item: item, model: model, player: player)
                case .player(let item, let episode):
                    PlayerView(item: item, episode: episode, player: player, model: model)
                }
            }
            .toolbar(model.route != .home ? .hidden : .visible, for: .navigationBar)
        }
        .task { await model.bootstrap() }
        .onAppear { model.player = player }
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

                            Text("showId: \(item.showId)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.tertiaryText)
                        }

                        if model.isLoadingEpisodes {
                            ProgressView().controlSize(.small)
                        } else if model.episodes.isEmpty {
                            Text("暂无剧集信息")
                                .font(.system(size: 15))
                                .foregroundStyle(Palette.tertiaryText)
                        } else {
                            Text("剧集 · \(model.episodes.count)")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Palette.primaryText)
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
