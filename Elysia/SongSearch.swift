import Foundation

/// Song search, kept as pure functions so the matching rules can be exercised on
/// their own.
enum SongSearch {
    /// Songs matching every whitespace-separated term of `query`.
    ///
    /// A term matches when it appears in the title or the artist.
    /// `localizedStandardContains` is used so matching ignores case, diacritics
    /// and width, which is what people expect from a search field.
    ///
    /// A blank query returns the list untouched.
    static func filter(_ songs: [Song], query: String) -> [Song] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return songs }

        return songs.filter { song in
            terms.allSatisfy { matches(song, term: $0) }
        }
    }

    /// The terms a query is made of: trimmed, whitespace-separated, empties dropped.
    static func terms(in query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Whether a query narrows the list at all.
    static func isActive(_ query: String) -> Bool {
        !terms(in: query).isEmpty
    }

    private static func matches(_ song: Song, term: String) -> Bool {
        song.title.localizedStandardContains(term)
            || song.artist.localizedStandardContains(term)
    }
}
