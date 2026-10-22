import Foundation

// MARK: - 专辑
//
// 专辑是 Apple Music 资料库自带的信息，Elysia 只读不写：同一张专辑按「专辑名 +
// 专辑歌手」归到一起，曲目按碟号、曲目号排成唱片上的顺序。曲目本身仍以资料库为准，
// 所以资料库里删掉的曲目会自动消失，不会留下空行。
struct Album: Identifiable, Hashable {
    /// 专辑名与专辑歌手的组合。两组精选集同名不同歌手时不会被并成一张。
    let id: String
    let title: String
    /// 专辑歌手；资料库里没填时退回曲目歌手
    let artist: String
    /// 专辑内的曲目，已按碟号、曲目号排好
    let songs: [Song]
}

/// 把资料库曲目归成专辑。纯函数，便于单独测。
enum AlbumLibrary {
    /// 按专辑分组，再按专辑名排序（中文按拼音）。
    ///
    /// 专辑名为空的曲目不进「专辑」页——它们在资料库里本来就没有归属，
    /// 硬凑成一张「未知专辑」只会把列表撑长；这些曲目在「歌曲」页仍然都在。
    static func albums(from songs: [Song]) -> [Album] {
        var groups: [String: (title: String, artist: String, songs: [(order: Int, song: Song)])] = [:]

        for (order, song) in songs.enumerated() {
            let title = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let artist = artistName(of: song)
            let key = id(title: title, artist: artist)
            groups[key, default: (title: title, artist: artist, songs: [])]
                .songs.append((order, song))
        }

        return groups.map { key, group in
            Album(id: key, title: group.title, artist: group.artist, songs: ordered(group.songs))
        }
        .sorted { a, b in
            let byTitle = a.title.localizedStandardCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return a.artist.localizedStandardCompare(b.artist) == .orderedAscending
        }
    }

    /// 专辑列表的搜索：每个检索词都要出现在专辑名或专辑歌手里。
    ///
    /// 与歌曲搜索同一套规则（`SongSearch`），因此两处输入框的行为一致。
    static func filter(_ albums: [Album], query: String) -> [Album] {
        let terms = SongSearch.terms(in: query)
        guard !terms.isEmpty else { return albums }

        return albums.filter { album in
            terms.allSatisfy { term in
                album.title.localizedStandardContains(term)
                    || album.artist.localizedStandardContains(term)
            }
        }
    }

    /// 专辑的歌手：优先专辑歌手，没填时用曲目歌手
    private static func artistName(of song: Song) -> String {
        let albumArtist = song.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard albumArtist.isEmpty else { return albumArtist }
        return song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func id(title: String, artist: String) -> String {
        // 用不可见字符分隔，避免「A / B」这类名字被拼出一样的键
        title + "\u{1F}" + artist
    }

    /// 碟号、曲目号小的在前；读不出编号的（0）排到后面。
    ///
    /// 编号相同时按它在资料库里的先后排：`sorted` 不保证稳定，所以自己带上序号。
    private static func ordered(_ items: [(order: Int, song: Song)]) -> [Song] {
        items.sorted { a, b in
            let discA = a.song.discNumber > 0 ? a.song.discNumber : Int.max
            let discB = b.song.discNumber > 0 ? b.song.discNumber : Int.max
            if discA != discB { return discA < discB }

            let trackA = a.song.trackNumber > 0 ? a.song.trackNumber : Int.max
            let trackB = b.song.trackNumber > 0 ? b.song.trackNumber : Int.max
            if trackA != trackB { return trackA < trackB }

            return a.order < b.order
        }
        .map(\.song)
    }
}
