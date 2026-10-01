import Foundation
import AppKit

// MARK: - 歌曲数据模型
struct Song: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
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

    /// 从 Apple Music 资料库获取所有歌曲
    static func fetchAllSongs() -> [Song] {
        let script = """
        tell application "Music"
            set songList to every track of library playlist 1
            set output to ""
            repeat with t in songList
                set output to output & (persistent ID of t) & "|||" & (name of t) & "|||" & (artist of t) & "\n"
            end repeat
            return output
        end tell
        """

        let result = runAppleScriptSync(script)
        var songs: [Song] = []
        for line in result.split(separator: "\n") {
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 3 else { continue }
            songs.append(Song(id: parts[0], title: parts[1], artist: parts[2]))
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
        // 每个字段各自 try：只要有一个属性读不出来（资料库里确实存在这种读不出任何
        // 属性的孤立条目），旧写法会让整个 try 跳到 on error，把 ID、曲名、歌手全部
        // 清空，界面就显示「未在播放」——而歌其实还在放。分开 try 后可降级为局部缺失。
        let script = """
        tell application "Music"
            set currentID to ""
            set pos to 0
            set dur to 0
            set trackName to ""
            set trackArtist to ""

            try
                set currentID to (persistent ID of current track) as text
            end try
            try
                set pos to player position
            end try
            try
                set dur to duration of current track
            end try
            try
                set trackName to (name of current track) as text
            end try
            try
                set trackArtist to (artist of current track) as text
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

    /// 让 Apple Music 自己执行循环（单曲 / 列表）。
    ///
    /// 循环交给 Music 原生处理，Elysia 就不必在曲末抢时间动手，那一整类竞态（与 Music
    /// 自己的曲末自动走歌互相打架）随之消失。Elysia 只负责在用户切换模式时下发一次。
    ///
    /// 注：`set song repeat to all` 让 Music 播到资料库末尾后回到开头继续，即列表循环；
    /// `to one` 即单曲循环。
    static func setRepeat(_ mode: RepeatMode) {
        Diagnostics.log("下发循环模式 = \(mode.rawValue)")
        scriptQueue.async {
            let echo = runAppleScriptSync("""
            tell application "Music"
                set song repeat to \(mode.rawValue)
                return song repeat as text
            end tell
            """)
            Diagnostics.log("下发循环模式 \(mode.rawValue) 后，Music 回读 = \(echo.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// 启动时只关掉随机播放。
    ///
    /// 随机播放会让 Music 自己往下走时挑随机的歌，与 Elysia 的顺序互相打架，必须关。
    ///
    /// 这里**不设置循环模式**。原先启动时会把 `song repeat` 强制设为 off，但那是异步的：
    /// 若用户在启动后立刻点循环按钮，点击会排在它前面下发，随后被它覆盖回去——表现为
    /// 「怎么点都像没开」。现在启动不写循环，改为由界面在第一次读到 Music 的循环模式时
    /// 采纳它（见 ContentView），两侧从一开始就同步，也不存在覆盖用户操作的窗口。
    static func disableShuffle() {
        scriptQueue.async {
            _ = runAppleScriptSync("""
            tell application "Music"
                set shuffle enabled to false
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
