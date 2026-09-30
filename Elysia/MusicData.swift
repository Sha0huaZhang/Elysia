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
        let script = """
        tell application "Music"
            try
                set currentID to persistent ID of current track
                set pos to player position
                set dur to duration of current track
            on error
                set currentID to ""
                set pos to 0
                set dur to 0
            end try
            set stateStr to (player state as string)
            return currentID & "|||" & stateStr & "|||" & pos & "|||" & dur
        end tell
        """

        let result = runAppleScriptSync(script)
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 4 else {
            return PlayerStatus(persistentID: nil, isPlaying: false, isStopped: true, position: 0, duration: 0)
        }

        let pid = parts[0].isEmpty ? nil : parts[0]
        let state = parts[1]
        let position = Double(parts[2]) ?? 0
        let duration = Double(parts[3]) ?? 0

        return PlayerStatus(
            persistentID: pid,
            isPlaying: state == "playing",
            isStopped: state == "stopped",
            position: position,
            duration: duration
        )
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

    /// 强制把 Apple Music 的循环模式设为 off（启动时调用）
    static func forceRepeatOff() {
        scriptQueue.async {
            _ = runAppleScriptSync("""
            tell application "Music"
                set song repeat to off
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
