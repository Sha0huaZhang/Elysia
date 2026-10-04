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

extension Playlist {
    /// 把 `items` 从 `fromOffsets` 移到 `toOffset`，与 SwiftUI 的 `onMove` 语义一致。
    ///
    /// 自己实现而不用 `Array.move(fromOffsets:toOffset:)`：那个来自 SwiftUI，而这个文件
    /// 只依赖 Foundation，放在这里也能单独测。越界的参数按边界取值，不抛错。
    static func moved(_ ids: [UUID], fromOffsets: IndexSet, toOffset: Int) -> [UUID] {
        let moving = fromOffsets.filter { ids.indices.contains($0) }.map { ids[$0] }
        guard !moving.isEmpty else { return ids }

        var rest = ids
        for index in fromOffsets.sorted(by: >) where rest.indices.contains(index) {
            rest.remove(at: index)
        }
        // 目标位置要减去「被移走的、且位于目标之前」的个数，才是插入点
        let removedBefore = fromOffsets.filter { $0 < toOffset }.count
        let insertAt = max(0, min(rest.count, toOffset - removedBefore))

        var result = rest
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }

    /// 选曲确认后写回的曲目顺序。
    ///
    /// 原本就在歌单里的曲目保留它们在歌单中的先后，新选的在后面按歌曲列表的先后接上：
    /// 只补选几首歌时不会把已有顺序打乱。新建时 `existingOrder` 为空，结果就是歌曲列表
    /// 的先后，与点击次序无关，同一个歌单每次建出来都一样。
    ///
    /// 资料库里已经没有的曲目会被丢掉：它本来就显示不出来，留着只会一直积在歌单里。
    static func orderedSelection(
        selected: Set<String>,
        existingOrder: [String],
        librarySongs: [Song]
    ) -> [String] {
        let inLibrary = Set(librarySongs.map(\.id))
        var result: [String] = []
        // seen 同时挡住原顺序里可能存在的重复项：显示端本就会去掉重复，写入端也一并去重，
        // 免得一份带重复的旧数据被原样写回、一直传下去
        var seen = Set<String>()
        for id in existingOrder where selected.contains(id) && inLibrary.contains(id) {
            if seen.insert(id).inserted { result.append(id) }
        }
        for song in librarySongs where selected.contains(song.id) && seen.insert(song.id).inserted {
            result.append(song.id)
        }
        return result
    }

    /// 歌单里能真正对上的曲目，按歌单内的顺序。
    ///
    /// 资料库里已经删掉的曲目、以及那个读不出属性的坏条目，在这里被丢掉。调用方拿到的
    /// 数量就是「实际能显示的曲目数」，据此编号与歌曲数都不会出现断号：编号按这个数组
    /// 的位置重新从 1 排，而不是用曲目在资料库中的位置——那个位置会因为坏条目留下空缺。
    ///
    /// 同一个 ID 重复出现时只保留第一次，避免同一首歌在歌单里出现两遍。
    func resolvedSongs(in index: [String: Song]) -> [Song] {
        var seen = Set<String>()
        return songIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return index[id]
        }
    }
}

extension Song {
    /// 按 persistent ID 建索引，供歌单把存的 ID 还原成曲目。
    static func index(_ songs: [Song]) -> [String: Song] {
        Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// 歌单存成 JSON 文本（UTF-8）放在 defaults 里。
    ///
    /// 用文本而不是二进制：`defaults read org.macwave.Elysia org.macwave.elysia.playlists`
    /// 就能直接看到内容，排查问题时不必再解码一遍。歌单名里的中文、emoji 都以 UTF-8
    /// 原样保存。
    var all: [Playlist] {
        guard let text = defaults.string(forKey: key),
              let data = text.data(using: .utf8),
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

    /// 按给定顺序重排歌单。
    ///
    /// 只接受与现有歌单集合完全一致的顺序：数量不符、含重复 ID、含未知 ID 都原样返回。
    /// 这里必须挡住重复——只查数量的话，传入三个相同的 ID 会通过检查，然后把所有歌单都
    /// 变成同一个，等于把数据毁掉。
    func reorder(ids: [UUID]) {
        let list = all
        guard ids.count == list.count, Set(ids).count == list.count else { return }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = ids.compactMap { byID[$0] }
        guard reordered.count == list.count else { return }
        save(reordered)
    }

    /// 编辑歌单：改名与改曲目。
    ///
    /// 名字为空、或与**别的**歌单同名时返回 nil。编辑时要把正在编辑的这个排除在重名
    /// 检查之外，否则不改名也会被判成与自己重名。
    func update(id: UUID, name: String, songIDs: [String]) -> Playlist? {
        let stored = Self.trimmed(name)
        guard !stored.isEmpty, !contains(name: stored, excluding: id) else { return nil }

        var list = all
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        list[index].name = stored
        list[index].songIDs = songIDs
        save(list)
        return list[index]
    }

    /// 是否已有同名歌单。`excluding` 用于编辑时跳过自己。
    ///
    /// 比较时忽略首尾空白与大小写：用户在列表里看到的「UTF-8」和输入「utf-8」是同一个
    /// 名字，按字面区分只会建出两个看起来一样的歌单。比较用的规整只用于比较，
    /// 不影响实际存下来的名字。
    func contains(name: String, excluding id: UUID? = nil) -> Bool {
        let target = Self.comparisonKey(name)
        return all.contains { $0.id != id && Self.comparisonKey($0.name) == target }
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
        guard let data = try? JSONEncoder().encode(list),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }
}
