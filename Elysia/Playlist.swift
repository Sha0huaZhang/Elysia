import Foundation

// MARK: - Elysia 歌单
//
// 歌单只存在于 Elysia 内部：不写入 Apple Music，也不改动 Apple Music 的任何内容。
//
// 存的是一串 persistent ID 的有序列表。播放时按这个顺序逐个申请，因此顺序完全由
// Elysia 决定，与 Apple Music 自己的队列无关——资料库里那些读不出属性的坏条目也就
// 绕开了，不会让「下一首」跳错。
struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// 曲目的 persistent ID，按歌单内的顺序排列
    var songIDs: [String]

    init(id: UUID = UUID(), name: String, songIDs: [String] = []) {
        self.id = id
        self.name = name
        self.songIDs = songIDs
    }
}

/// 歌单的持久化。
///
/// 与 SongOrderStore 一样只存 ID，曲目本身仍以 Apple Music 资料库为准：曲目被删掉后
/// 会自然消失，不会留下指向不存在曲目的悬空条目。
struct PlaylistStore {
    private static let defaultKey = "org.macwave.elysia.playlists"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = PlaylistStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var all: [Playlist] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
        return list
    }

    /// 新建歌单。名字为空、或与已有歌单同名时返回 nil，调用方据此提示。
    func create(name: String, songIDs: [String]) -> Playlist? {
        // 存的是去掉首尾空白后的原名，不做大小写转换——用户输入的 "UTF-8" 就该是 "UTF-8"
        let stored = Self.trimmed(name)
        guard !stored.isEmpty, !contains(name: stored) else { return nil }

        var list = all
        let playlist = Playlist(name: stored, songIDs: songIDs)
        list.append(playlist)
        save(list)
        return playlist
    }

    func delete(id: UUID) {
        save(all.filter { $0.id != id })
    }

    /// 是否已有同名歌单。
    ///
    /// 比较时忽略首尾空白与大小写：用户在列表里看到的「UTF-8」和输入「utf-8」是同一个
    /// 名字，按字面区分只会建出两个看起来一样的歌单。比较用的规整只用于比较，
    /// 不影响实际存下来的名字。
    func contains(name: String) -> Bool {
        let target = Self.comparisonKey(name)
        return all.contains { Self.comparisonKey($0.name) == target }
    }

    /// 去掉首尾空白
    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 比较用的键：去掉首尾空白并忽略大小写
    private static func comparisonKey(_ name: String) -> String {
        trimmed(name).lowercased()
    }

    private func save(_ list: [Playlist]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
}
