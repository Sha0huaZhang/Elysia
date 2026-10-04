import Foundation
import AppKit

// MARK: - 歌曲数据模型
struct Song: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    /// 这首歌在 Apple Music 资料库中的位置（1 起）。0 表示读不出位置。
    ///
    /// 用的是 Apple Music 自己给出的位置，不显示在界面上，但日志里的「第 N 位」和
    /// ~/Library/Logs/Elysia-list.txt 里的位置都用它，因此核对时可以和 Apple Music 的
    /// 列表逐行对上。资料库里读不出属性的坏条目会占掉一个位置却不出现在列表里，
    /// 位置在那里就会出现空缺——空缺本身就是「这里少了一首」的提示。
    let libraryPosition: Int

    /// 日志里的位置标识，与诊断清单里的位置完全一致
    var positionText: String { libraryPosition > 0 ? "第\(libraryPosition)位" : "位置未知" }

    /// 是否已下载到本机——决定了离线时能不能播。
    ///
    /// 判据是 Apple Music 能否给出这首歌的本地文件位置：已下载的读得到（订阅下载是
    /// `.movpkg` 本地包，购买或导入的是普通音频文件），云端未下载的读不到、会报错。
    /// 不用 `kind` 判断，那是本地化文字（中文系统显示「HLS媒体」，英文系统是别的），
    /// 换语言就会失效。
    let isDownloaded: Bool
}

// MARK: - 播放状态
struct PlayerStatus {
    let persistentID: String?
    let isPlaying: Bool
    let isStopped: Bool
    let position: Double
    let duration: Double
    /// 当前曲目名（没有曲目时为 nil）
    let title: String?
    /// 当前曲目歌手
    let artist: String?
    /// Apple Music 的循环模式（off / all / one）。随状态一起读取，
    /// 使界面上的循环图标始终反映 Music 的真实状态，而不是 Elysia 自己的记忆。
    let repeatRaw: String?

    static let idle = PlayerStatus(
        persistentID: nil, isPlaying: false, isStopped: true,
        position: 0, duration: 0, title: nil, artist: nil, repeatRaw: nil
    )

    /// 解析状态脚本的 "|||" 分隔输出。
    ///
    /// 字段顺序：persistentID、播放状态、进度、时长、曲名、歌手、循环模式。
    /// 循环模式为后加字段，只有 6 段时按缺失处理（返回 nil 而不是整体失败）。
    /// 输出不符合预期时退回 `idle`，让界面显示为「未在播放」而不是崩溃。
    static func parse(_ output: String) -> PlayerStatus {
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 6 else { return .idle }

        return PlayerStatus(
            persistentID: parts[0].isEmpty ? nil : parts[0],
            isPlaying: parts[1] == "playing",
            isStopped: parts[1] == "stopped",
            position: Double(parts[2]) ?? 0,
            duration: Double(parts[3]) ?? 0,
            title: parts[4].isEmpty ? nil : parts[4],
            artist: parts[5].isEmpty ? nil : parts[5],
            repeatRaw: parts.count >= 7 && !parts[6].isEmpty ? parts[6] : nil
        )
    }
}

// MARK: - 音量同步
//
// Apple Music 的音量是异步生效的，而界面每两秒才轮询一次。松手后如果立刻
// 改用轮询值，滑块会先弹回旧音量、再跳回新值。这里保留用户设定值，直到
// Apple Music 跟上（或超时），从而避免这一跳。
enum VolumeSync {
    enum Outcome: Equatable {
        /// 继续显示用户设定值
        case keepPending
        /// 采用 Apple Music 报告的值，并清除待同步状态
        case acceptReported(Double)
        /// 无待同步值，沿用报告值
        case useReported(Double)
        /// 没有新数据，保持现状
        case noChange
    }

    static let tolerance: Double = 1.0
    static let timeout: TimeInterval = 1.5

    static func resolve(
        pending: Double?,
        reported: Double?,
        dragging: Bool,
        elapsed: TimeInterval,
        tolerance: Double = VolumeSync.tolerance,
        timeout: TimeInterval = VolumeSync.timeout
    ) -> Outcome {
        guard let reported else { return .noChange }

        guard let pending else {
            return dragging ? .noChange : .useReported(reported)
        }

        if abs(reported - pending) < tolerance {
            return .acceptReported(reported)
        }
        return elapsed > timeout ? .acceptReported(reported) : .keepPending
    }
}

// MARK: - 播放模式
enum RepeatMode: String {
    case off = "off"
    case all = "all"
    case one = "one"
}

// MARK: - Music.app 数据访问
enum MusicData {

    private static let scriptQueue = DispatchQueue(label: "org.macwave.elysia.script")

    /// 从 Apple Music 资料库获取所有歌曲，按 Music 给出的位置排序。
    ///
    /// 不按 `track i` 逐个取：资料库里只要有一个读不出属性的坏条目，`count of tracks`
    /// 就会少报一个（实测 129，实际有 130 个位置），按下标取既指不到排在最后的那首，
    /// 又会让整张列表从坏条目处开始错位一格。改为枚举后读回 Music 自己给出的 `index`，
    /// 位置就不依赖计数：坏条目自然留下一个空缺，并被自动跳过。
    ///
    /// 同时记下每首歌是否已下载（见 `Song.isDownloaded`），供离线时把播不了的曲目标灰。
    static func fetchAllSongs() -> [Song] {
        let script = """
        tell application "Music"
            set songList to every track of library playlist 1
            set output to ""
            repeat with t in songList
                set pid to ""
                set nm to ""
                set ar to ""
                set idx to 0
                set dld to 0
                try
                    set pid to (persistent ID of t)
                end try
                try
                    set nm to (name of t)
                end try
                try
                    set ar to (artist of t)
                end try
                try
                    set idx to (index of t)
                end try
                try
                    set p to (location of t)
                    set dld to 1
                end try
                set output to output & idx & "|||" & pid & "|||" & nm & "|||" & ar & "|||" & dld & "\n"
            end repeat
            return output
        end tell
        """

        let result = runAppleScriptSync(script)
        var songs: [Song] = []
        var unpositioned = 0
        for line in result.split(separator: "\n") {
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 5 else { continue }
            // 坏条目连 persistent ID 都读不出，直接跳过（不放进列表）
            let id = parts[1].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }

            let position = Int(parts[0]) ?? 0
            if position <= 0 { unpositioned += 1 }
            songs.append(Song(
                id: id,
                title: parts[2],
                artist: parts[3],
                libraryPosition: position,
                isDownloaded: parts[4] == "1"
            ))
        }

        // 按 Music 的位置排序；位置读不出的排在最后，宁可位置不准也不要丢掉这首歌
        songs.sort { a, b in
            if a.libraryPosition == 0 { return false }
            if b.libraryPosition == 0 { return true }
            return a.libraryPosition < b.libraryPosition
        }
        if unpositioned > 0 {
            Diagnostics.log("\(unpositioned) 首曲目读不出资料库位置，已放到列表末尾")
        }
        return songs
    }

    /// 获取当前播放状态（异步）
    static func fetchPlayerStatus() async -> PlayerStatus {
        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                let status = fetchPlayerStatusSync()
                continuation.resume(returning: status)
            }
        }
    }

    private static func fetchPlayerStatusSync() -> PlayerStatus {
        // 一次解析出 current track 并复用同一个引用，而不是每个字段各写一次
        // 「current track」。后者每次都是一次查找，一轮轮询要做六次，每秒十几次往返，
        // 白白加重 Apple Music 的负担；而且读取途中若正好切歌，各字段会取自不同的曲目
        // （曲名是新的、时长还是旧的），得到自相矛盾的状态。
        //
        // 每个字段仍各自 try：资料库里确实存在读不出任何属性的孤立条目，整体 try 会让它
        // 一抛错就把 ID、曲名、歌手全部清空，界面显示「未在播放」而歌其实还在放。
        let script = """
        tell application "Music"
            set currentID to ""
            set pos to 0
            set dur to 0
            set trackName to ""
            set trackArtist to ""

            try
                set theTrack to current track
                try
                    set currentID to (persistent ID of theTrack) as text
                end try
                try
                    set trackName to (name of theTrack) as text
                end try
                try
                    set trackArtist to (artist of theTrack) as text
                end try
                try
                    set dur to duration of theTrack
                end try
            end try
            try
                set pos to player position
            end try

            set stateStr to (player state as string)
            set repeatStr to ""
            try
                set repeatStr to (song repeat as text)
            end try
            return currentID & "|||" & stateStr & "|||" & pos & "|||" & dur & "|||" & trackName & "|||" & trackArtist & "|||" & repeatStr
        end tell
        """

        let result = runAppleScriptSync(script)
        return PlayerStatus.parse(result)
    }

    /// 现场读取当前正在播放曲目的 persistent ID（异步）。
    ///
    /// 与轮询缓存不同：按下「上一首 / 下一首」时现问现拿。轮询最长滞后半秒，而
    /// Apple Music 会在曲末自己顺着资料库往下走，用滞后的值当锚点会把目标算错一首
    /// ——表现就是「下一首」跳到不对的歌，甚至往回跳。
    static func fetchCurrentTrackID() async -> String? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                let result = runAppleScriptSync("""
                tell application "Music"
                    try
                        return persistent ID of current track
                    on error
                        return ""
                    end try
                end tell
                """)
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }

    /// 播放指定 persistent ID 的歌曲（异步）
    static func playSong(persistentID: String) {
        scriptQueue.async {
            let script = """
            tell application "Music"
                set theTrack to first track of library playlist 1 whose persistent ID is "\(persistentID)"
                play theTrack
            end tell
            """
            _ = runAppleScriptSync(script)
        }
    }

    /// 播放 / 暂停（异步）
    static func togglePlayPause() {
        scriptQueue.async {
            let script = """
            tell application "Music"
                if player state is playing then
                    pause
                else
                    play
                end if
            end tell
            """
            _ = runAppleScriptSync(script)
        }
    }

    /// 启动时把 Music 的循环与随机都关掉。
    ///
    /// Elysia 自己实现循环（Music 的循环对 `play <track>` 启动的播放本来就失效），
    /// 随机播放则会让 Music 自己往下走时挑随机的歌。两者都关掉，Music 就只在 Elysia
    /// 明确申请时才换曲。
    ///
    /// 这里写 Music 不会影响界面：循环模式是 Elysia 自己的状态，不读 Music 的值，
    /// 因此不存在「启动写入覆盖用户点击」的问题。
    static func forceSequentialPlayback() {
        scriptQueue.async {
            _ = runAppleScriptSync("""
            tell application "Music"
                set song repeat to off
                set shuffle enabled to false
            end tell
            """)
        }
    }

    /// 把当前曲目从头重播（单曲循环用）。
    ///
    /// 不能用「重新申请同一首」代替：`play <正在播放的曲目>` 是空操作，不会重新开始，
    /// 于是下一轮轮询仍看到听到曲末，会反复申请，最终被 Music 的队列接走（已实测）。
    static func restartCurrentTrack() {
        scriptQueue.async {
            _ = runAppleScriptSync("""
            tell application "Music"
                set player position to 0
            end tell
            """)
        }
    }

    /// 暂停（不循环模式播到最后一首时使用）
    static func pause() {
        scriptQueue.async {
            _ = runAppleScriptSync("""
            tell application "Music"
                pause
            end tell
            """)
        }
    }

    /// 跳转到指定秒数（异步）
    static func seek(to seconds: Double) {
        scriptQueue.async {
            _ = runAppleScriptSync("""
            tell application "Music"
                set player position to \(seconds)
            end tell
            """)
        }
    }

    /// 获取当前音量（0-100，异步）
    static func fetchVolume() async -> Double {
        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                let result = runAppleScriptSync("""
                tell application "Music"
                    return sound volume
                end tell
                """)
                continuation.resume(returning: Double(result) ?? 50)
            }
        }
    }

    /// 设置音量（0-100，异步）
    static func setVolume(_ volume: Double) {
        scriptQueue.async {
            let clamped = max(0, min(100, volume))
            _ = runAppleScriptSync("""
            tell application "Music"
                set sound volume to \(clamped)
            end tell
            """)
        }
    }

    /// 获取封面（异步）
    ///
    /// 标注 `@MainActor`：调用方都是界面侧（SwiftUI 的 `.task`），
    /// 而 `NSImage` 不是 Sendable，这样能明确表达封面的交付线程。
    /// 实际读取仍发生在 `scriptQueue` 上，不会阻塞界面。
    @MainActor
    static func fetchArtwork(persistentID: String) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                let image = fetchArtworkSync(persistentID: persistentID)
                continuation.resume(returning: image)
            }
        }
    }

    private static func fetchArtworkSync(persistentID: String) -> NSImage? {
        let script = """
        tell application "Music"
            set theTrack to first track of library playlist 1 whose persistent ID is "\(persistentID)"
            return data of artwork 1 of theTrack
        end tell
        """

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            print("AppleScript 错误: \(errorInfo)")
            return nil
        }

        let data = result.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private static func runAppleScriptSync(_ source: String) -> String {
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return "" }
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            print("AppleScript 错误: \(errorInfo)")
            return ""
        }

        return result.stringValue ?? ""
    }
}
