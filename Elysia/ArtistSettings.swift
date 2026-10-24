import Foundation

// MARK: - 歌手的本地改动
//
// 屏蔽只存在 Elysia 里：Apple Music 的资料库一个曲目都不会动，被屏蔽的歌手只是从
// 「歌手」页收起来，他的歌曲仍在「歌曲」页、「专辑」页。
//
// 存的是歌手名的比较键（忽略大小写与首尾空白），所以资料库里写法变了也还认得。
struct ArtistSettings: Codable {
    /// 被屏蔽的歌手（比较键），顺序即屏蔽的先后
    var hidden: [String] = []
}

struct ArtistSettingsStore {
    static let defaultKey = "org.macwave.elysia.artistSettings"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = ArtistSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var settings: ArtistSettings {
        guard let text = defaults.string(forKey: key),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ArtistSettings.self, from: data) else {
            return ArtistSettings()
        }
        return decoded
    }

    /// 被屏蔽歌手的比较键集合
    var hiddenKeys: Set<String> { Set(settings.hidden) }

    func hide(_ names: [String]) {
        var current = settings
        for name in names {
            let key = ArtistLibrary.comparisonKey(name)
            guard !key.isEmpty, !current.hidden.contains(key) else { continue }
            current.hidden.append(key)
        }
        save(current)
    }

    func unhide(_ names: [String]) {
        var current = settings
        let restoring = Set(names.map(ArtistLibrary.comparisonKey))
        current.hidden.removeAll { restoring.contains($0) }
        save(current)
    }

    func unhideAll() {
        var current = settings
        current.hidden.removeAll()
        save(current)
    }

    private func save(_ settings: ArtistSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }
}
