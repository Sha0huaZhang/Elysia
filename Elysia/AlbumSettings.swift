import Foundation

// MARK: - 专辑的本地改动
//
// 改名与屏蔽都只存在 Elysia 里：Apple Music 的资料库、专辑名、曲目一个都不会变。
// 存的是 JSON 文本（UTF-8）放在 defaults 里，和歌单一样，`defaults read` 就能直接看。
//
// 键始终是专辑的原始标识（Apple Music 的原专辑名 + 专辑歌手），所以改过名字之后
// 仍然认得是哪一张；屏蔽也只是把这张专辑从「专辑」页收起来，歌曲还在「歌曲」页。
struct AlbumSettings: Codable {
    /// 专辑 id → 显示用的名字
    var renamed: [String: String] = [:]
    /// 被屏蔽的专辑 id
    var hidden: [String] = []
}

struct AlbumSettingsStore {
    static let defaultKey = "org.macwave.elysia.albumSettings"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = AlbumSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var settings: AlbumSettings {
        guard let text = defaults.string(forKey: key),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AlbumSettings.self, from: data) else {
            return AlbumSettings()
        }
        return decoded
    }

    /// 逐张写入改名结果。
    ///
    /// 名字为空、或与 Apple Music 里的原名相同时，删掉覆盖，等于恢复原名——
    /// 这样清空输入框就能撤销改名，也不会在 defaults 里留下没用的记录。
    func rename(_ changes: [(id: String, original: String, name: String)]) {
        var current = settings
        for change in changes {
            let name = LibraryLimits.normalized(change.name, limit: LibraryLimits.albumName)
            if name.isEmpty || name == change.original {
                current.renamed.removeValue(forKey: change.id)
            } else {
                current.renamed[change.id] = name
            }
        }
        save(current)
    }

    func hide(_ ids: [String]) {
        var current = settings
        for id in ids where !current.hidden.contains(id) {
            current.hidden.append(id)
        }
        save(current)
    }

    func show(_ ids: [String]) {
        var current = settings
        let restoring = Set(ids)
        current.hidden.removeAll { restoring.contains($0) }
        save(current)
    }

    func showAll() {
        var current = settings
        current.hidden.removeAll()
        save(current)
    }

    private func save(_ settings: AlbumSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }
}
