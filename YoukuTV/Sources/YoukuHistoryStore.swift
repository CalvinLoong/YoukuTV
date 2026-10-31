import Foundation

/// 本地播放历史。
///
/// ## 为什么先做本地
///
/// 优酷 TV 端把观看记录同步到服务端，用的是
/// `mtop.yunos.tvpublic.user.playlog.pushuserplaylogv2` / `.listuserplaylogv2`。
/// 但那套接口走的是 mtop SDK 的 **native 签名**（SecurityGuard `libsgmainso`
/// 在 native 层算 `x-sign`），**Swift 无法复现**（实测卡在
/// `FAIL_SYS_ILEGEL_SIGN::非法请求签名`）。
///
/// 所以这一版先把历史记录**可靠地存在本机**：
/// - 观看的节目、进度、封面都留着
/// - 下次进 App 直接看到「继续观看」
/// - 登录态与接口打通后，可以把同一份数据再补传服务端
///
/// ## 存储
///
/// `UserDefaults`（JSON 数组），最多保留 100 条。
/// 之所以不用文件：`UserDefaults` 在 tvOS 上够用，读取是同步的，
/// 首页加载时不用等 IO。
actor YoukuHistoryStore {
    /// 一条观看记录。
    struct Entry: Identifiable, Hashable, Codable {
        /// showId（节目标识）
        let showId: String
        /// vid（可播放的视频标识）
        let videoId: String
        /// 节目名
        let title: String
        /// 海报
        let poster: String
        /// 副标题（集名等）
        let subtitle: String
        /// 播放进度（秒）
        var position: Int
        /// 总时长（秒）
        var duration: Int
        /// 最后观看时间
        var updatedAt: Date

        var id: String { showId.isEmpty ? videoId : showId }

        /// 进度比例（0~1）
        var progress: Double {
            guard duration > 0 else { return 0 }
            return min(1, Double(position) / Double(duration))
        }
    }

    private static let storageKey = "youku.watch.history"
    private static let maxEntries = 100

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取全部历史，按最近观看倒序。
    func all() -> [Entry] {
        Self.loadSynchronously()
    }

    /// 同步读取历史。
    ///
    /// `AppViewModel.init()` 里要用（初始化器不能 `await`），
    /// 而 `UserDefaults` 的读取本来就是同步的，直接读即可。
    nonisolated static func loadSynchronously(
        defaults: UserDefaults = .standard
    ) -> [Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 写入或更新一条记录。
    ///
    /// 同一个 `showId` 视为同一条（换集不新增行，只更新 vid 与进度）。
    func record(
        showId: String,
        videoId: String,
        title: String,
        poster: String,
        subtitle: String,
        position: Int,
        duration: Int
    ) {
        var entries = all()
        let now = Date()

        let entry = Entry(
            showId: showId,
            videoId: videoId,
            title: title,
            poster: poster,
            subtitle: subtitle,
            position: position,
            duration: duration,
            updatedAt: now
        )

        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }

        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save(entries)
    }

    /// 删除一条记录。
    func remove(_ entry: Entry) {
        var entries = all()
        entries.removeAll { $0.id == entry.id }
        save(entries)
    }

    /// 清空全部历史。
    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
