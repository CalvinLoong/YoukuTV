import SwiftUI

/// 应用主视图：顶部 Tab 切换 + 内容区。
struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @StateObject private var player = PlayerController()

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
                    PlayerView(item: item, episode: episode, player: player)
                }
            }
            .navigationBarHidden(model.route != .home)
        }
        .task { await model.bootstrap() }
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
                    .focused($model.isSearchFocused)
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
                                model.play(item: item, episode: nil)
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
                        model.play(item: item, episode: ep)
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

/// 播放页。tvOS 上用 VideoPlayer 承载 AVPlayer。
struct PlayerView: View {
    let item: VideoItem
    let episode: Episode?
    @ObservedObject var player: PlayerController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = player.errorMessage {
                ErrorView(message: error)
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
                    if player.isLoading { ProgressView().controlSize(.large) }
                }
                .padding(.horizontal, 60)
                .padding(.top, 40)
                Spacer()
            }
        }
    }
}
