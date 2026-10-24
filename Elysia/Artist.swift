import Foundation

// MARK: - 歌手
//
// 歌手来自 Apple Music 资料库里的曲目：同一歌手的曲目归到一起，按曲目在资料库里的
// 先后排列。Elysia 只读不写，也不改动资料库里的任何内容。
struct Artist: Identifiable, Hashable {
    /// 歌手名（去掉首尾空白后的原名）。屏蔽记录以它为准。
    let id: String
    /// 显示的歌手名
    let name: String
    /// 该歌手的曲目，按资料库中的先后
    let songs: [Song]
    /// 出现过的专辑张数（专辑名为空的曲目不算）
    let albumCount: Int
}

/// 把资料库曲目归成歌手。纯函数，便于单独测。
enum ArtistLibrary {
    /// 按歌手分组，再按歌手名排序（中文按拼音）。
    ///
    /// 歌手名为空的曲目不进「歌手」页——资料库里确实存在没有歌手信息的曲目，
    /// 把它们并成一个「未知歌手」只会多出一行没有意义的东西；这些曲目在「歌曲」页仍然都在。
    static func artists(from songs: [Song]) -> [Artist] {
        var groups: [String: (name: String, songs: [Song], albums: Set<String>)] = [:]
        var order: [String] = []

        for song in songs {
            let name = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let key = comparisonKey(name)
            if groups[key] == nil {
                groups[key] = (name: name, songs: [], albums: [])
                order.append(key)
            }
            groups[key]?.songs.append(song)

            let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            if !album.isEmpty { groups[key]?.albums.insert(album) }
        }

        return order.compactMap { key -> Artist? in
            guard let group = groups[key] else { return nil }
            return Artist(
                id: group.name,
                name: group.name,
                songs: group.songs,
                albumCount: group.albums.count
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 歌手列表的搜索：每个检索词都要出现在歌手名里。
    ///
    /// 与歌曲、专辑搜索同一套规则（`SongSearch.terms`），几处输入框的行为一致。
    static func filter(_ artists: [Artist], query: String) -> [Artist] {
        let terms = SongSearch.terms(in: query)
        guard !terms.isEmpty else { return artists }

        return artists.filter { artist in
            terms.allSatisfy { artist.name.localizedStandardContains($0) }
        }
    }

    /// 比较用的键：忽略大小写与首尾空白。
    ///
    /// 资料库里同一个歌手可能有「Adele」和「adele」两种写法，按字面分会变成两个歌手，
    /// 界面上看起来就像重复了。屏蔽记录也用同一个键，所以换了写法也还认得。
    static func comparisonKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
