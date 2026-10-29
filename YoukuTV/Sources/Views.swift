import SwiftUI

/// tvOS 主题色板。深色为主，符合电视大屏观看习惯。
enum Palette {
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.13)
    static let surfaceRaised = Color(red: 0.15, green: 0.15, blue: 0.19)
    static let accent = Color(red: 0.16, green: 0.72, blue: 0.96)
    static let accentWarm = Color(red: 0.98, green: 0.55, blue: 0.20)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
}

/// 海报卡片。tvOS 使用 focus effect，缩放由系统处理，这里只做视觉。
struct PosterCard: View {
    let item: VideoItem
    var width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.surfaceRaised)
                if let url = URL(string: item.poster), !item.poster.isEmpty {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholder
                        default:
                            placeholder
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    placeholder
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Palette.tertiaryText)
            Text("优酷")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surfaceRaised)
    }
}

/// 横向滚动的一行节目。
struct PosterRow: View {
    let title: String
    let items: [VideoItem]
    var onSelect: (VideoItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.primaryText)
                .padding(.horizontal, 60)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 22) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            PosterCard(item: item)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// 剧集网格。
struct EpisodeGrid: View {
    let episodes: [Episode]
    var onSelect: (Episode) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
            ForEach(episodes) { ep in
                Button {
                    onSelect(ep)
                } label: {
                    HStack(spacing: 12) {
                        // index 已经是实际集号（从播放页的 stage 字段取），不要再 +1
                        Text("\(ep.index)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 34, height: 34)
                            .background(Palette.surfaceRaised)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(ep.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Palette.primaryText)
                                .lineLimit(1)
                            if ep.duration > 0 {
                                Text("\(ep.duration / 60) 分 \(ep.duration % 60) 秒")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.tertiaryText)
                            }
                        }
                        Spacer(minLength: 0)
                        if ep.isVip {
                            Text("VIP")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Palette.accentWarm)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.card)
            }
        }
    }
}

/// 加载中的骨架屏。
struct LoadingView: View {
    var text: String = "加载中…"

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 错误提示。
struct ErrorView: View {
    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Palette.accentWarm)
            Text(message)
                .font(.system(size: 18))
                .foregroundStyle(Palette.primaryText)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }
}
