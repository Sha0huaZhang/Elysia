import Foundation

/// Persists a user-defined song order on top of the natural Music library order.
///
/// Only persistent IDs are stored: the library stays the single source of truth
/// for the songs themselves. This keeps the saved order valid when the library
/// changes — songs that were removed are dropped, and songs that appear later go
/// back to the position the library gives them.
struct SongOrderStore {
    private static let defaultKey = "org.macwave.elysia.songOrder"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SongOrderStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The saved order, or `nil` when the library order is in effect.
    var savedIDs: [String]? {
        guard let ids = defaults.stringArray(forKey: key), !ids.isEmpty else { return nil }
        return ids
    }

    var isCustomized: Bool { savedIDs != nil }

    func save(_ songs: [Song]) {
        defaults.set(songs.map(\.id), forKey: key)
    }

    /// Drops the saved order so the natural library order applies again.
    func reset() {
        defaults.removeObject(forKey: key)
    }

    /// Applies the saved order to a freshly fetched library listing.
    ///
    /// Songs the saved order does not mention are put back where the library has
    /// them — directly after the nearest preceding song the user did arrange —
    /// instead of being parked at the bottom of the list. The bottom is not where
    /// the library puts a new song, so parking it there made 「下一首」 skip past
    /// the song the library actually has in between.
    func apply(to librarySongs: [Song]) -> [Song] {
        guard let savedIDs else { return librarySongs }

        var libraryByID: [String: Song] = [:]
        libraryByID.reserveCapacity(librarySongs.count)
        for song in librarySongs where libraryByID[song.id] == nil {
            libraryByID[song.id] = song
        }
        let savedSet = Set(savedIDs)

        // 用户排列过的曲目，按保存的顺序；已从资料库移除的自然被丢掉
        var seen = Set<String>()
        var ordered: [Song] = []
        for id in savedIDs where seen.insert(id).inserted {
            if let song = libraryByID[id] { ordered.append(song) }
        }
        // 保存的顺序与资料库已经对不上时，直接退回资料库顺序
        guard !ordered.isEmpty else { return librarySongs }

        // 保存顺序里没有的曲目：跟在「它前面最近的一首已排列曲目」之后；
        // 排在所有已排列曲目之前的，放在列表最前
        var arrivals: [String: [Song]] = [:]
        var leading: [Song] = []
        var anchor: String? = nil
        for song in librarySongs {
            if savedSet.contains(song.id) {
                anchor = song.id
            } else if let previousAnchor = anchor {
                arrivals[previousAnchor, default: []].append(song)
            } else {
                leading.append(song)
            }
        }

        var result = leading
        result.reserveCapacity(librarySongs.count)
        for song in ordered {
            result.append(song)
            result.append(contentsOf: arrivals[song.id] ?? [])
        }
        return result
    }
}

/// Pure reordering maths, kept apart from the view so it can be exercised on its own.
enum SongReorder {
    /// Moves `draggedID` into `slot`, where slots are the gaps between songs:
    /// slot 0 sits above the first song and slot `songs.count` below the last.
    static func moving(_ draggedID: String, toSlot slot: Int, in songs: [Song]) -> [Song] {
        guard let from = songs.firstIndex(where: { $0.id == draggedID }) else { return songs }

        var result = songs
        let dragged = result.remove(at: from)
        // Removing the dragged song shifts every later gap up by one.
        let clamped = max(0, min(slot, songs.count))
        let adjusted = clamped > from ? clamped - 1 : clamped
        result.insert(dragged, at: max(0, min(adjusted, result.count)))
        return result
    }

    /// The slot a drag of `draggedID` should land in.
    ///
    /// Judged purely by the dragged card's centre line: the card lands in the gap
    /// it is hovering, i.e. however many row centres sit above its centre. Dropping
    /// between the centres of rows 2 and 3 therefore inserts between rows 2 and 3.
    ///
    /// Ties go to the row above: a centre line that has not passed a row's centre
    /// is treated as resting above that row.
    static func slot(forDraggedCentreY y: CGFloat, rowCentres: [CGFloat]) -> Int {
        rowCentres.filter { $0 < y }.count
    }

    /// Where the pointer sat inside the row when the drag began.
    static func grabOffset(pointerStartY: CGFloat, rowMinY: CGFloat) -> CGFloat {
        pointerStartY - rowMinY
    }

    /// Top of the floating drag card, in the container's coordinate space.
    ///
    /// Derived from the pointer alone rather than from a measured row frame: a
    /// measured frame can disagree with the pointer's coordinate space by a
    /// constant, which would shift the card away from the cursor for the whole
    /// drag even though the drop logic (which only compares frames with each
    /// other) stays correct.
    static func dragCardTop(pointerY: CGFloat, grabOffsetY: CGFloat, containerMinY: CGFloat) -> CGFloat {
        pointerY - grabOffsetY - containerMinY
    }
}
