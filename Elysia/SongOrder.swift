import Foundation

/// Persists a user-defined song order on top of the natural Music library order.
///
/// Only persistent IDs are stored: the library stays the single source of truth
/// for the songs themselves. This keeps the saved order valid when the library
/// changes — songs that were removed are dropped, and songs that appear later
/// are appended in library order.
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
    func apply(to librarySongs: [Song]) -> [Song] {
        guard let savedIDs else { return librarySongs }

        var remaining = [String: Song](minimumCapacity: librarySongs.count)
        for song in librarySongs {
            remaining[song.id] = song
        }

        var ordered: [Song] = []
        ordered.reserveCapacity(librarySongs.count)
        for id in savedIDs {
            if let song = remaining.removeValue(forKey: id) {
                ordered.append(song)
            }
        }
        for song in librarySongs where remaining[song.id] != nil {
            ordered.append(song)
        }
        return ordered
    }
}
