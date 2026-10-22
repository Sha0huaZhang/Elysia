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

    /// 封面的缓存键：同一张专辑的曲目共用一张封面，所以按专辑算。
    /// 没有专辑名的曲目按曲目自己算，否则会共用一张别人的封面。
    var artworkKey: String {
        let name = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return id }
        return name + "\u{1F}" + albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否已下载到本机——决定了离线时能不能播。
    ///
    /// 判据是 Apple Music 能否给出这首歌的本地文件位置：已下载的读得到（订阅下载是
    /// `.movpkg` 本地包，购买或导入的是普通音频文件），云端未下载的读不到、会报错。
    /// 不用 `kind` 判断，那是本地化文字（中文系统显示「HLS媒体」，英文系统是别的），
    /// 换语言就会失效。
    let isDownloaded: Bool

    /// 专辑名。资料库里没填时为空串，这类曲目不出现在「专辑」页。
    let album: String

    /// 专辑歌手；资料库里没填时为空串，此时「专辑」页退回用曲目歌手分组。
    let albumArtist: String

    /// 碟号、曲目号（1 起，0 表示读不出）。「专辑」页据此把一张专辑排成唱片上的顺序。
    let discNumber: Int
    let trackNumber: Int

    init(
        id: String,
        title: String,
        artist: String,
        libraryPosition: Int,
        isDownloaded: Bool,
        album: String = "",
        albumArtist: String = "",
        discNumber: Int = 0,
        trackNumber: Int = 0
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.libraryPosition = libraryPosition
        self.isDownloaded = isDownloaded
        self.album = album
        self.albumArtist = albumArtist
        self.discNumber = discNumber
        self.trackNumber = trackNumber
    }
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
    /// 又会让整张列表从坏条目处开始错位一格。改为读回 Music 自己给出的 `index`，
    /// 位置就不依赖计数：坏条目自然留下一个空缺，并被自动跳过。
    ///
    /// 每个属性**整体读一次**（`get name of every track …`），而不是逐首读九个属性。
    /// 逐首读要走一万五千多次 Apple Event，实测 27 秒；整体读只要九次，同样一千七百多首
    /// 约 0.5 秒。读库期间轮询排在同一个串行队列后面，读多久界面就僵多久，所以这一项
    /// 直接决定了打开应用的手感。
    ///
    /// `isDownloaded` 也不逐首读 `location`：那样一格一格问文件系统，一千七百多首实测
    /// 18 秒。改用「哪些曲目是 file track」问一次（0.3 秒），本地文件在 Music 里就是
    /// file track，云端未下载的是 cloud track——与逐首读 `location` 的结果逐条比对过，
    /// 1575 首完全一致，一条不差。
    ///
    /// 返回 nil 表示这一次没读成：脚本出错（Apple Music 正忙、正在导入歌曲时都可能发生）
    /// 同样得不到任何输出，调用方据此保留原来的列表，而不是把界面清空。资料库确实是空的
    /// 时才返回空数组。
    static func fetchAllSongs() -> [Song]? {
        // 各属性读成同长度的列表，用控制字符分隔后一起送回：一条 Apple Event 换一列值。
        // 字段之间用 RS（0x1E），列内用 US（0x1F），这两个字符不会出现在曲目信息里。
        let script = """
        set fs to character id 31
        set rs to character id 30
        tell application "Music"
            set nameList to (get name of every track of library playlist 1)
            set artistList to (get artist of every track of library playlist 1)
            set albumList to (get album of every track of library playlist 1)
            set albumArtistList to (get album artist of every track of library playlist 1)
            set trackList to (get track number of every track of library playlist 1)
            set discList to (get disc number of every track of library playlist 1)
            set idList to (get persistent ID of every track of library playlist 1)
            set indexList to (get index of every track of library playlist 1)
            set localIDs to (get persistent ID of every file track of library playlist 1)
        end tell
        set AppleScript's text item delimiters to fs
        set output to (nameList as text)
        set output to output & rs & (artistList as text)
        set output to output & rs & (albumList as text)
        set output to output & rs & (albumArtistList as text)
        set output to output & rs & (trackList as text)
        set output to output & rs & (discList as text)
        set output to output & rs & (idList as text)
        set output to output & rs & (indexList as text)
        set output to output & rs & (localIDs as text)
        return output
        """

        let result = runAppleScriptSync(script)
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 输出为空有两种可能：资料库真的是空的，或者这一次脚本没跑成。
            // 问一句曲目数就能分清，只有确实是空的才返回空数组。
            let count = runAppleScriptSync("""
            tell application "Music" to return (count of tracks of library playlist 1)
            """).trimmingCharacters(in: .whitespacesAndNewlines)
            if (Int(count) ?? 0) > 0 {
                Diagnostics.log("读取资料库失败（Music 返回空列表，实际有 \(count) 首），保留原列表")
                return nil
            }
            return []
        }

        let columns = result
            .components(separatedBy: String(Character(UnicodeScalar(30))))
            .map { $0.components(separatedBy: String(Character(UnicodeScalar(31)))) }
        guard columns.count == 9 else {
            Diagnostics.log("读取资料库失败（返回 \(columns.count) 列，预期 9 列），保留原列表")
            return nil
        }

        // 各列长度理应相同；万一不等，按最短的一列对齐，宁少几首也不错位
        let counts = Set(columns.map(\.count))
        if counts.count > 1 {
            Diagnostics.log("读取资料库时各属性数量不一致 \(columns.map(\.count))，按 \(counts.min() ?? 0) 首对齐")
        }
        // 下载状态那一列与曲目列长度不同（本来就只有一部分曲目有本地文件），
        // 所以只对前八列要求对齐
        let n = columns.prefix(8).map(\.count).min() ?? 0
        guard n > 0 else { return [] }

        let (names, artists, albums, albumArtists, tracks, discs, ids, indexes) = (
            columns[0], columns[1], columns[2], columns[3],
            columns[4], columns[5], columns[6], columns[7]
        )
        let localIDs = Set(columns[8].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        var songs: [Song] = []
        songs.reserveCapacity(n)
        var unpositioned = 0
        for i in 0..<n {
            // 坏条目连 persistent ID 都读不出，直接跳过（不放进列表）
            let id = ids[i].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }

            let position = Int(indexes[i]) ?? 0
            if position <= 0 { unpositioned += 1 }
            songs.append(Song(
                id: id,
                title: names[i],
                artist: artists[i],
                libraryPosition: position,
                isDownloaded: localIDs.contains(id),
                album: albums[i],
                albumArtist: albumArtists[i],
                discNumber: Int(discs[i]) ?? 0,
                trackNumber: Int(tracks[i]) ?? 0
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

    // MARK: 封面
    //
    // 一张封面要走一趟 AppleScript（约 0.1 秒，还要在 Music 里把曲目线性找一遍）。
    // 一千多首的列表若每滑过一行就发一次查询，脚本队列会被塞满，轮询与播放状态跟着
    // 一起卡住——这正是「滑动歌曲最卡」的直接原因。因此这里做了三件事：
    //
    // 1. 按专辑缓存：同一张专辑的曲目共用一张封面，只取一次。
    // 2. 先给低分辨率：列表里只显示 40×40 点，64 像素的小图够用，缩放也快。
    // 3. 空闲时再慢慢换成清晰版：不滚动、不拖动之后，一张一张升级到 128 像素。

    /// 缓存封面的边长（像素）。列表里显示 40 点：Retina 下 80 像素，128 已经足够清晰，
    /// 也留了余量给拖动卡片与缩放屏；再大在格子里也看不出来，只会白占内存。
    private static let artworkSide: CGFloat = 128

    /// 缓存上限：200 张、合计 24 MB。低分辨率一张约 16 KB、清晰版约 64 KB，
    /// 正常浏览远达不到上限；到了也由 NSCache 先淘汰最久没用的。
    static func configureArtworkCache() {
        artworkCache.countLimit = 200
        artworkCache.totalCostLimit = 24 * 1024 * 1024
    }

    private static let artworkCache = NSCache<NSString, NSImage>()

    /// 确认没有封面的专辑。不记下来的话，每滚过一行都会把同一张空专辑再问一遍。
    private static var missingArtwork = Set<String>()
    /// 保护它：多个异步任务会同时碰
    private static let artworkLock = NSLock()

    /// 取一张封面。
    ///
    /// 缓存里有的直接返回（先给低分辨率也够用）；没有就等一个防抖窗口再问 Music。
    /// 取回来一次缩放成两档：低分辨率立刻交付给界面，清晰版同时存好，等用户停下滑动、
    /// 翻到这一行时格子里已经是清晰的。**不另做「后台再取一次清晰版」的流程**——
    /// 那等于每张封面都走两趟 AppleScript，实测会把 CPU 打满。
    ///
    /// 防抖是关键：快速滚动时行会很快消失，`.task` 随之取消，`Task.sleep` 直接抛出，
    /// 于是这次查询根本不会发生。只有停下来的、真正看得见的行才会去取。
    ///
    /// 标注 `@MainActor`：调用方都是界面侧（SwiftUI 的 `.task`），而 `NSImage` 不是
    /// Sendable，这样能明确表达封面的交付线程。实际读取仍发生在 `scriptQueue` 上。
    @MainActor
    static func artwork(for key: String, persistentID: String) async -> NSImage? {
        if let cached = artworkCache.object(forKey: key as NSString) { return cached }
        if isMissing(key) { return nil }

        try? await Task.sleep(nanoseconds: 60_000_000)
        if Task.isCancelled { return nil }
        if let cached = artworkCache.object(forKey: key as NSString) { return cached }

        return await loadArtwork(key: key, persistentID: persistentID)
    }

    /// 预取一批曲目的封面，离 `centre` 近的先取。
    ///
    /// 歌曲列表把可视区上下各 100 首交进来：滑到那里时封面已经就位，不会先看到一片
    /// 灰底再逐个亮起来。近的先取，所以即使这批没做完，用户滑到哪儿也都是现成的。
    ///
    /// 取封面是串行的 AppleScript，因此每取一张就让出 20 毫秒，轮询与播放状态照样能插进来。
    static func prefetchArtwork(for songs: [Song], centre: Int, limit: Int = 40) async {
        guard !songs.isEmpty else { return }
        let safeCentre = max(0, min(centre, songs.count - 1))
        let lower = max(0, safeCentre - 100)
        let upper = min(songs.count - 1, safeCentre + 100)
        guard lower <= upper else { return }

        // 由近及远：可视区周围先就位
        let window = Array(lower...upper).sorted { abs($0 - safeCentre) < abs($1 - safeCentre) }

        var seen = Set<String>()
        var attempts = 0
        for index in window {
            if Task.isCancelled || attempts >= limit { return }
            let song = songs[index]
            let key = song.artworkKey
            guard seen.insert(key).inserted else { continue }
            if artworkCache.object(forKey: key as NSString) != nil { continue }
            if isMissing(key) { continue }

            // 没有封面的专辑也占一次尝试，否则一遇到空专辑就可能把整批都问一遍
            attempts += 1
            _ = await loadArtwork(key: key, persistentID: song.id)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 预取一小组「代表曲目」的封面，用于专辑页。
    ///
    /// 与歌曲列表同一个缓存：专辑页取过的封面，回到歌曲页就是现成的。
    static func prefetchAlbumCovers(_ songs: [Song], limit: Int = 30) async {
        var attempts = 0
        for song in songs {
            if Task.isCancelled || attempts >= limit { return }
            let key = song.artworkKey
            if artworkCache.object(forKey: key as NSString) != nil { continue }
            if isMissing(key) { continue }

            attempts += 1
            _ = await loadArtwork(key: key, persistentID: song.id)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 真正去取一张封面：一次取回、缩到缓存尺寸、存好并返回。
    ///
    /// 只取一趟。曾经试过「先给低分辨率、空闲时再取一次清晰版」，那等于每张封面走两趟
    /// AppleScript，CPU 直接被打满（实测持续 100%）；而多缩一档的成本几乎为零，所以
    /// 一次取回就缩好、存好。
    private static func loadArtwork(key: String, persistentID: String) async -> NSImage? {
        guard let original = await fetchArtwork(persistentID: persistentID) else {
            markMissing(key)
            return nil
        }

        let scaled = scaledArtwork(original, side: artworkSide)
        store(scaled, key: key, side: artworkSide)
        return scaled
    }

    // MARK: 缓存内部

    private static func isMissing(_ key: String) -> Bool {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        return missingArtwork.contains(key)
    }

    private static func markMissing(_ key: String) {
        artworkLock.lock()
        missingArtwork.insert(key)
        artworkLock.unlock()
    }

    /// 存进缓存，按位图大小记成本，超过上限时由 NSCache 淘汰最久没用的那些。
    private static func store(_ image: NSImage, key: String, side: CGFloat) {
        let cost = Int(side * side * 4)
        artworkCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 把封面缩到指定边长。必须缩放后再缓存：原图是上千像素的位图，一张解压后好几 MB，
    /// 直接留着几百张就是几百 MB 内存，而且每帧还要重新采样。
    ///
    /// 用显式的 `NSBitmapImageRep` 而不是 `lockFocus()`：后者的后备位图会按屏幕缩放
    /// 分配（Retina 下就是四倍像素），缓存几百张时差出几十 MB；显式位图则严格是
    /// 边长 × 边长 × 4 字节。
    private static func scaledArtwork(_ image: NSImage, side: CGFloat) -> NSImage {
        let pixels = Int(side)
        guard pixels > 0 else { return image }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }

        // 位图是 pixels×pixels，逻辑尺寸按点数声明，界面上仍是 40×40 点
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: side, height: side))
        out.addRepresentation(rep)
        return out
    }

    static func fetchArtwork(persistentID: String) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                let image = fetchArtworkSync(persistentID: persistentID)
                continuation.resume(returning: image)
            }
        }
    }

    private static func fetchArtworkSync(persistentID: String) -> NSImage? {
        // 一张原图解码后有好几 MB：这一趟用完就让自动释放池收掉，别攒到下一次
        autoreleasepool {
            fetchArtworkOnce(persistentID: persistentID)
        }
    }

    private static func fetchArtworkOnce(persistentID: String) -> NSImage? {
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
