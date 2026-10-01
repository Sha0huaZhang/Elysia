import SwiftUI
import AppKit

// MARK: - 主视图
struct ContentView: View {
    @State private var nowPlayingID: String? = nil
    @State private var nowPlayingTitle: String? = nil
    @State private var nowPlayingArtist: String? = nil
    @State private var nowPlayingArtwork: NSImage? = nil
    @State private var isPlaying: Bool = false
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var repeatMode: RepeatMode = .off
    @State private var selectedItem: SidebarItem? = .songs
    /// 侧边栏搜索框的文字
    @State private var searchText = ""

    /// Apple Music 资料库的原始顺序，用于恢复默认排序
    @State private var librarySongs: [Song] = []
    /// 当前是否使用用户自定义排序
    @State private var isCustomOrder = false
    /// 是否正在重新读取资料库
    @State private var isRefreshing = false
    /// 上次从 Apple Music 读取资料库的时间
    @State private var lastRefreshed: Date? = nil

    private let orderStore = SongOrderStore()

    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Double = 50

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    @State private var isDraggingVolume = false
    @State private var dragVolumeValue: Double = 0
    /// 用户设定、等待 Apple Music 跟上的音量（乐观值）
    @State private var pendingVolume: Double? = nil
    @State private var pendingVolumeSince: Date? = nil
    /// 上一次把音量下发给 Apple Music 的时间，用于限流
    @State private var lastVolumeApply: Date = .distantPast

    @State private var pendingSeekTarget: Double? = nil

    /// 用户按下播放/暂停后的乐观状态
    @State private var pendingPlayState: Bool? = nil
    /// 乐观状态的时间戳，用于超时回滚
    @State private var pendingPlayStateTime: Date? = nil

    /// 用户按下「上一首 / 下一首」或点选歌曲后，期望正在播放的那首歌。
    /// nowPlayingID 靠轮询更新（500ms 一次），连按「下一首」时会一直以同一个旧歌
    /// 为锚点，算出同一个目标，第二下看起来就没反应。这里把最近一次请求当作锚点。
    @State private var pendingSongID: String? = nil
    /// 上述请求的时间戳，用于超时放弃
    @State private var pendingSongIDTime: Date? = nil

    /// 上次「播完接管」的时刻。用来防止同一首被反复申请，兼作失败重试的计时。
    @State private var takenOverAt: Date? = nil

    /// 已经提示过使用须知的版本号。按版本记录，所以更新后还会再提示一次，日常启动不打扰。
    @AppStorage("promptedVersion") private var promptedVersion = ""
    @State private var isShowingWelcome = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem, searchText: $searchText)
        } detail: {
            detailView
        }
        .frame(minWidth: 800, minHeight: 600)
        // 首次安装或更新后提示一次使用须知
        .onAppear {
            isShowingWelcome = promptedVersion != AppVersion.current
        }
        .alert("welcome.title", isPresented: $isShowingWelcome) {
            Button("common.gotIt") {
                // 确认后才记录，避免弹窗未读就退出、下次不再提示
                promptedVersion = AppVersion.current
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("welcome.message")
        }
        .task(id: nowPlayingID) {
            await loadNowPlayingArtwork()
        }
        .task {
            MusicData.forceRepeatOff()
            await loadSongs()
            let v = await MusicData.fetchVolume()
            await MainActor.run { self.volume = v }
            await startPolling()
        }
    }

    // MARK: - 侧边栏栏目对应的详情内容
    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .settings:
            SettingsView(
                songCount: songs.count,
                isCustomOrder: isCustomOrder,
                isRefreshing: isRefreshing,
                lastRefreshed: lastRefreshed,
                onResetOrder: resetOrder,
                onRefresh: refreshLibrary
            )
        case .songs, nil:
            playerView
        case .playlists, .albums, .start:
            ComingSoonView(item: selectedItem ?? .songs)
        }
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            PlayerControlBar(
                isPlaying: isPlaying,
                repeatMode: repeatMode,
                title: nowPlayingTitle,
                artist: nowPlayingArtist,
                artwork: nowPlayingArtwork,
                position: $position,
                duration: duration,
                isDragging: $isDragging,
                dragValue: $dragValue,
                volume: $volume,
                isDraggingVolume: $isDraggingVolume,
                dragVolumeValue: $dragVolumeValue,
                onPrevious: { playOffset(-1) },
                onNext: { playOffset(1) },
                onToggleRepeat: { cycleRepeatMode() },
                onTogglePlayPause: { togglePlayPause() },
                onSeek: { seconds in
                    MusicData.seek(to: seconds)
                    pendingSeekTarget = seconds
                },
                onVolumeChange: { newVolume in
                    applyVolumeWhileDragging(newVolume)
                },
                onVolumeCommit: { newVolume in
                    commitVolume(newVolume)
                }
            )
            Divider()
            SongListView(
                songs: visibleSongs,
                isLoading: isLoading,
                nowPlayingID: nowPlayingID,
                isPlaying: isPlaying,
                // 搜索结果只是原列表的视图，拖动会打乱真实顺序，因此搜索时禁用
                isReorderEnabled: !isSearching,
                isSearching: isSearching,
                onPlay: playSong,
                onReorder: persistOrder
            )
        }
    }

    /// 从 Apple Music 读取资料库，并套用已保存的顺序
    private func loadSongs() async {
        let fetched = await Task.detached(priority: .userInitiated) {
            MusicData.fetchAllSongs()
        }.value
        await MainActor.run {
            self.librarySongs = fetched
            self.songs = orderStore.apply(to: fetched)
            self.isCustomOrder = orderStore.isCustomized
            self.isLoading = false
            self.isRefreshing = false
            self.lastRefreshed = Date()
        }
    }

    /// 载入在播歌曲的封面（歌曲变化时触发）
    private func loadNowPlayingArtwork() async {
        guard let id = nowPlayingID else {
            await MainActor.run { nowPlayingArtwork = nil }
            return
        }
        let image = await MusicData.fetchArtwork(persistentID: id)
        await MainActor.run { nowPlayingArtwork = image }
    }

    /// 拖动音量条时持续下发，但做限流：每次下发都是一次 AppleScript 调用，
    /// 不加限流会堆积在串行队列里，反而更卡。末尾值由 commitVolume 保证。
    private func applyVolumeWhileDragging(_ newValue: Double) {
        // 界面立即跟随，避免依赖轮询
        volume = newValue
        pendingVolume = newValue
        if pendingVolumeSince == nil { pendingVolumeSince = Date() }

        let now = Date()
        guard now.timeIntervalSince(lastVolumeApply) > 0.08 else { return }
        lastVolumeApply = now
        MusicData.setVolume(newValue)
    }

    /// 松手时下发最终值
    private func commitVolume(_ newValue: Double) {
        // 关键：同时更新显示值。否则松手后 isDraggingVolume 变 false，
        // 滑块会读到尚未刷新的轮询值，先弹回旧位置再跳回来。
        volume = newValue
        pendingVolume = newValue
        pendingVolumeSince = Date()
        lastVolumeApply = Date()
        MusicData.setVolume(newValue)
    }

    /// 重新读取资料库，用于用户在 Apple Music 中增删歌曲之后
    private func refreshLibrary() {
        guard !isRefreshing, !isLoading else { return }
        isRefreshing = true
        Task { await loadSongs() }
    }

    private func startPolling() async {
        var tick = 0
        while !Task.isCancelled {
            let fetchStart = Date()
            let status = await MusicData.fetchPlayerStatus()
            let fetchSeconds = Date().timeIntervalSince(fetchStart)

            var newVolume: Double? = nil
            if tick % 4 == 0 {
                newVolume = await MusicData.fetchVolume()
            }
            tick += 1

            // 接近曲末时轮询会加密，间隔由 TrackEnd 决定
            var nextSleep: TimeInterval = TrackEnd.base

            await MainActor.run {
                // 在本轮改动 nowPlayingID 之前先判断曲目是否变了
                let trackChanged = status.persistentID != self.nowPlayingID

                self.nowPlayingID = status.persistentID
                self.nowPlayingTitle = status.title
                self.nowPlayingArtist = status.artist

                // 用户请求的目标一旦被 Apple Music 采纳，锚点就完成使命；迟迟等不到
                // 则超时放弃，免得锚点永久停在一首已被跳过的歌上。
                if let pending = self.pendingSongID {
                    if status.persistentID == pending {
                        self.pendingSongID = nil
                        self.pendingSongIDTime = nil
                    } else if let t = self.pendingSongIDTime, Date().timeIntervalSince(t) > 2.0 {
                        self.pendingSongID = nil
                        self.pendingSongIDTime = nil
                    }
                }

                // 处理乐观播放/暂停状态
                if let expected = self.pendingPlayState {
                    if status.isPlaying == expected {
                        // Apple Music 跟上了
                        self.isPlaying = status.isPlaying
                        self.pendingPlayState = nil
                        self.pendingPlayStateTime = nil
                    } else {
                        // 还没跟上。检查是否超时
                        if let t = self.pendingPlayStateTime, Date().timeIntervalSince(t) > 1.0 {
                            // 超时了，回滚
                            self.isPlaying = status.isPlaying
                            self.pendingPlayState = nil
                            self.pendingPlayStateTime = nil
                        } else {
                            // 还在等待，保持乐观状态
                            self.isPlaying = expected
                        }
                    }
                } else {
                    self.isPlaying = status.isPlaying
                }

                // 已请求换曲、Music 还没跟上时，轮询报的仍是上一首的进度。
                // 此时进度条必须先显示 0，否则会被旧值顶回去。
                let awaitingSwitch = self.pendingSongID != nil && status.persistentID != self.pendingSongID

                switch PositionSync.resolve(
                    dragging: self.isDragging,
                    awaitingSwitch: awaitingSwitch,
                    trackChanged: trackChanged,
                    pendingSeek: self.pendingSeekTarget,
                    reported: status.position
                ) {
                case .dragging:
                    break
                case .reset:
                    self.position = 0
                case .useReported(let value):
                    self.position = value
                    self.pendingSeekTarget = nil
                case .keepPending(let target):
                    self.position = target
                }
                self.duration = status.duration

                // 音量：优先显示用户设定值，直到 Apple Music 跟上或超时
                if let v = newVolume {
                    let elapsed = self.pendingVolumeSince.map { Date().timeIntervalSince($0) } ?? 0
                    switch VolumeSync.resolve(
                        pending: self.pendingVolume,
                        reported: v,
                        dragging: self.isDraggingVolume,
                        elapsed: elapsed
                    ) {
                    case .keepPending:
                        self.volume = self.pendingVolume ?? v
                    case .acceptReported(let value), .useReported(let value):
                        self.pendingVolume = nil
                        self.pendingVolumeSince = nil
                        self.volume = value
                    case .noChange:
                        break
                    }
                }

                // 曲目快播完时主动接管，按 Elysia 自己的顺序申请下一首。
                // 不能等 player state 变成 stopped：从资料库播放后 Music 会自己往下
                // 播，状态一直是 playing，等到 stopped 时循环早就没生效了。
                let remaining = status.duration > 0 ? status.duration - status.position : nil

                // 离开曲末（重头播或换了歌）就作废上次接管记录，否则单曲循环只生效一次
                if !status.isPlaying || remaining == nil || remaining! > TrackEnd.lead {
                    self.takenOverAt = nil
                }

                if let id = status.persistentID, TrackEnd.shouldTakeOver(
                    remaining: remaining,
                    isPlaying: status.isPlaying,
                    secondsSinceTakeover: self.takenOverAt.map { Date().timeIntervalSince($0) }
                ) {
                    self.takenOverAt = Date()
                    self.handleSongEnded(endedID: id)
                }

                nextSleep = TrackEnd.pollInterval(
                    remaining: remaining,
                    isPlaying: status.isPlaying,
                    fetchSeconds: fetchSeconds
                )
            }
            try? await Task.sleep(nanoseconds: UInt64(nextSleep * 1_000_000_000))
        }
    }

    private func handleSongEnded(endedID: String) {
        switch repeatMode {
        case .one:
            playSong(endedID)
        case .all:
            playOffset(1, fromID: endedID)
        case .off:
            playOffset(1, fromID: endedID, stopAtEnd: true)
        }
    }

    /// 播放指定歌曲，并记下乐观锚点。
    ///
    /// 顺序一律以 Elysia 自己的列表为准（含用户拖拽后的自定义顺序），不使用
    /// Apple Music 的播放队列：一旦下发具体歌曲，后续「上一首 / 下一首」就都按
    /// Elysia 的列表推算，与拖拽排序保持一致。
    private func playSong(_ id: String) {
        pendingSongID = id
        pendingSongIDTime = Date()
        // 进度条立刻归零，不等下一次轮询；同时丢弃属于上一首的跳转目标，
        // 否则它会继续按旧目标校正，新歌的进度条会停在旧位置。
        position = 0
        pendingSeekTarget = nil
        MusicData.playSong(persistentID: id)
    }

    private func playOffset(_ offset: Int, fromID: String? = nil, stopAtEnd: Bool = false) {
        guard !songs.isEmpty else { return }

        // 锚点优先取本次调用显式指定的歌，其次是用户上一次请求的歌，最后才回落到
        // 轮询值。少了中间这一层，连按就会重复算出同一个目标。
        let anchorID = fromID ?? pendingSongID ?? nowPlayingID
        let anchorIndex = anchorID.flatMap { id in songs.firstIndex { $0.id == id } }

        guard let targetIndex = SongAdvance.targetIndex(
            anchorIndex: anchorIndex,
            count: songs.count,
            offset: offset,
            repeatAll: repeatMode == .all,
            stopAtEnd: stopAtEnd
        ) else { return }

        playSong(songs[targetIndex].id)
    }

    private func cycleRepeatMode() {
        switch repeatMode {
        case .off:  repeatMode = .all
        case .all:  repeatMode = .one
        case .one:  repeatMode = .off
        }
    }

    /// 播放 / 暂停（按钮与空格键共用）
    private func togglePlayPause() {
        let newState = !isPlaying
        isPlaying = newState
        pendingPlayState = newState
        pendingPlayStateTime = Date()
        MusicData.togglePlayPause()
    }

    /// 当前是否在搜索
    private var isSearching: Bool { SongSearch.isActive(searchText) }

    /// 列表实际显示的歌曲：搜索时是匹配结果，否则是完整列表
    private var visibleSongs: [Song] {
        SongSearch.filter(songs, query: searchText)
    }

    /// 拖动排序后保存新的顺序
    private func persistOrder(_ ordered: [Song]) {
        songs = ordered
        orderStore.save(ordered)
        isCustomOrder = true
    }

    /// 恢复 Apple Music 资料库的原始顺序
    private func resetOrder() {
        orderStore.reset()
        songs = librarySongs
        isCustomOrder = false
    }
}

// MARK: - 侧边栏栏目
//
// 用稳定的枚举值作为选中标识，显示文字单独本地化，
// 这样切换语言不会影响选中状态与分支逻辑。
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case settings
    case songs
    case playlists
    case albums
    case start

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .settings:  return "sidebar.settings"
        case .songs:     return "sidebar.songs"
        case .playlists: return "sidebar.playlists"
        case .albums:    return "sidebar.albums"
        case .start:     return "sidebar.start"
        }
    }

    var systemImage: String {
        switch self {
        case .settings:  return "gearshape"
        case .songs:     return "music.note"
        case .playlists: return "music.note.list"
        case .albums:    return "square.stack"
        case .start:     return "play.circle"
        }
    }
}

// MARK: - 侧边栏
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
    }

    /// 列表上方的搜索框
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("search.placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { searchText = "" }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("search.clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - 顶部控制条
struct PlayerControlBar: View {
    let isPlaying: Bool
    let repeatMode: RepeatMode
    let title: String?
    let artist: String?
    let artwork: NSImage?
    @Binding var position: Double
    let duration: Double
    @Binding var isDragging: Bool
    @Binding var dragValue: Double
    @Binding var volume: Double
    @Binding var isDraggingVolume: Bool
    @Binding var dragVolumeValue: Double
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleRepeat: () -> Void
    let onTogglePlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onVolumeChange: (Double) -> Void
    let onVolumeCommit: (Double) -> Void

    var body: some View {
        // 左右两侧块等宽，中间的正在播放信息因此精确居中，且不会与两侧重叠
        HStack(spacing: 0) {
            transportControls
                .frame(width: 190, alignment: .leading)

            NowPlayingInline(
                title: title,
                artist: artist,
                artwork: artwork,
                isPlaying: isPlaying,
                position: $position,
                duration: duration,
                isDragging: $isDragging,
                dragValue: $dragValue,
                onSeek: onSeek
            )
            .frame(maxWidth: 400)

            volumeControls
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        // 略微加高：封面获得更大的上边距，内部内容仍整体垂直居中
        .frame(height: 66)
    }

    private var transportControls: some View {
        HStack(spacing: 20) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)

            Button(action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: onNext) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)

            Button(action: onToggleRepeat) {
                Image(systemName: repeatIcon)
                    .foregroundColor(repeatMode == .off ? .primary : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
    }

    private var volumeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .center)

            Slider(
                value: Binding(
                    get: { isDraggingVolume ? dragVolumeValue : volume },
                    set: { newValue in
                        dragVolumeValue = newValue
                        isDraggingVolume = true
                    }
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    if editing {
                        isDraggingVolume = true
                    } else {
                        // 松手：下发最终值并结束拖动状态
                        onVolumeCommit(dragVolumeValue)
                        isDraggingVolume = false
                    }
                }
            )
            // 拖动过程中持续下发，音量实时跟随
            .onChange(of: dragVolumeValue) { newValue in
                if isDraggingVolume {
                    onVolumeChange(newValue)
                }
            }
            .controlSize(.mini)
            .tint(.red)
            .frame(width: 80, height: 12)
        }
    }

    private var repeatIcon: String {
        switch repeatMode {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }

    private var volumeIcon: String {
        let v = isDraggingVolume ? dragVolumeValue : volume
        if v <= 0 { return "speaker.slash.fill" }
        if v < 33 { return "speaker.fill" }
        if v < 66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - 控制条中央的正在播放信息（无独立外框）
struct NowPlayingInline: View {
    let title: String?
    let artist: String?
    let artwork: NSImage?
    let isPlaying: Bool
    @Binding var position: Double
    let duration: Double
    @Binding var isDragging: Bool
    @Binding var dragValue: Double
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 封面、歌名、歌手视为一个整体
            HStack(spacing: 8) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? String(localized: "player.notPlaying"))
                        .font(.system(size: 12))
                        .fontWeight(isPlaying ? .bold : .semibold)
                        // 播放中红色；暂停或未播放时跟随系统前景色
                        .foregroundStyle(isPlaying ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(artist ?? "—")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // 进度条在他们下面，从左边缘起
            HStack(spacing: 6) {
                Text(formatTime(isDragging ? dragValue : position))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { isDragging ? dragValue : position },
                        set: { newValue in
                            dragValue = newValue
                            isDragging = true
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isDragging = true
                        } else {
                            // 松手必须把 isDragging 设回 false。少了这一步，拖过一次
                            // 进度条之后它就永远是 true，显示值会一直取 dragValue，
                            // 轮询也不再更新 position —— 换歌时进度条就不会归零。
                            onSeek(dragValue)
                            isDragging = false
                        }
                    }
                )
                .controlSize(.mini)
                .tint(.red)

                Text(formatTime(duration))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isPlaying)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


// MARK: - 歌曲列表
struct SongListView: View {
    let songs: [Song]
    let isLoading: Bool
    let nowPlayingID: String?
    let isPlaying: Bool
    let isReorderEnabled: Bool
    let isSearching: Bool
    let onPlay: (String) -> Void
    let onReorder: ([Song]) -> Void

    /// 正在拖动的歌曲 ID
    @State private var draggingID: String? = nil
    /// 按下时鼠标在行内的垂直偏移（全局坐标）
    @State private var dragGrabOffsetY: CGFloat? = nil
    /// 鼠标当前的全局 Y，卡片据此跟随
    @State private var dragPointerY: CGFloat? = nil
    /// 拖动中卡片的封面
    @State private var draggedArtwork: NSImage? = nil
    /// 各行在全局坐标系中的位置，用于计算中心线
    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        Group {
            if isLoading {
                ProgressView("songs.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty, isSearching {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("songs.noMatch.title").foregroundColor(.secondary)
                    Text("songs.noMatch.hint")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("songs.empty.title").foregroundColor(.secondary)
                    Text("songs.empty.hint")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                songList
            }
        }
    }

    private var songList: some View {
        GeometryReader { container in
            ZStack(alignment: .topLeading) {
                List {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRowView(
                            song: song,
                            isPlaying: song.id == nowPlayingID && isPlaying,
                            isDragging: draggingID == song.id,
                            isReorderEnabled: isReorderEnabled,
                            onPlay: onPlay,
                            onDragChanged: { pointerY, startY, artwork in
                                if draggingID != song.id {
                                    draggingID = song.id
                                    draggedArtwork = artwork
                                    dragGrabOffsetY = SongReorder.grabOffset(
                                        pointerStartY: startY,
                                        rowMinY: rowFrames[song.id]?.minY ?? startY
                                    )
                                }
                                dragPointerY = pointerY
                            },
                            onDragEnded: { pointerY, startY in
                                finishDrag(of: song, index: index, translation: pointerY - startY)
                            }
                        )
                    }
                }
                .listStyle(.plain)
                .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }

                if let id = draggingID, let frame = rowFrames[id],
                   let song = songs.first(where: { $0.id == id }),
                   let pointerY = dragPointerY, let grabOffset = dragGrabOffsetY {
                    SongDragCard(song: song, artwork: draggedArtwork)
                        .frame(width: frame.width, height: frame.height)
                        // 由鼠标全局坐标直接定位，不使用测量帧，避免坐标系偏差带来的固定错位
                        .offset(y: SongReorder.dragCardTop(
                            pointerY: pointerY,
                            grabOffsetY: grabOffset,
                            containerMinY: container.frame(in: .global).minY
                        ))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 落点对应的插槽：按拖动卡片的中心线判断
    private func targetSlot(for translation: CGFloat, frame: CGRect, index: Int) -> Int {
        let centreY = frame.midY + translation
        // 行高一致，未拖动时第 i 行的中心线可由拖动行的中心线推算
        let centres = songs.indices.map { frame.midY + CGFloat($0 - index) * frame.height }
        return SongReorder.slot(forDraggedCentreY: centreY, rowCentres: centres)
    }

    private func finishDrag(of song: Song, index: Int, translation: CGFloat) {
        defer {
            draggingID = nil
            dragGrabOffsetY = nil
            dragPointerY = nil
            draggedArtwork = nil
        }

        guard let frame = rowFrames[song.id] else { return }
        let slot = targetSlot(for: translation, frame: frame, index: index)
        let reordered = SongReorder.moving(song.id, toSlot: slot, in: songs)
        guard reordered != songs else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            onReorder(reordered)
        }
    }
}

/// 报告单行在列表坐标系中的位置
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 拖动时跟随鼠标的卡片
struct SongDragCard: View {
    let song: Song
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(.semibold)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

// MARK: - 拖动重排手势
//
// 只在启用重排时把拖动手势挂上去。
//
// 不能图省事写成 simultaneousGesture(..., including: .none) 来「关掉」拖动：
// 被屏蔽的手势依然留在视图树里参与命中测试，会把同一行的双击吃掉，症状就是
// 搜索时双击歌名不播放。整段不挂手势，双击才回得来。
private struct ReorderDragModifier: ViewModifier {
    let enabled: Bool
    let onChanged: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { onChanged($0.location.y, $0.startLocation.y) }
                    .onEnded { onEnded($0.location.y, $0.startLocation.y) }
            )
        } else {
            content
        }
    }
}

// MARK: - 单行歌曲视图
struct SongRowView: View {
    let song: Song
    let isPlaying: Bool
    let isDragging: Bool
    let isReorderEnabled: Bool
    let onPlay: (String) -> Void
    let onDragChanged: (CGFloat, CGFloat, NSImage?) -> Void
    let onDragEnded: (CGFloat, CGFloat) -> Void

    @State private var isHovering = false
    @State private var artworkImage: NSImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = artworkImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPlaying ? Color.red : Color.clear, lineWidth: 2)
            )
            .task {
                await loadArtwork()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(isPlaying ? .bold : .regular)
                    .foregroundColor(isPlaying ? .red : .primary)
                Text(song.artist)
                    .font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            if isHovering, !isDragging {
                Button(action: {
                    onPlay(song.id)
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFrameKey.self,
                    value: [song.id: geo.frame(in: .global)]
                )
            }
        )
        .opacity(isDragging ? 0.25 : 1)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            onPlay(song.id)
        }
        // 拖动与双击播放共存，互不抢占；搜索时不挂手势（原因见 ReorderDragModifier）
        .modifier(
            ReorderDragModifier(
                enabled: isReorderEnabled,
                onChanged: { onDragChanged($0, $1, artworkImage) },
                onEnded: onDragEnded
            )
        )
    }

    private func loadArtwork() async {
        guard artworkImage == nil else { return }
        let image = await MusicData.fetchArtwork(persistentID: song.id)
        await MainActor.run {
            self.artworkImage = image
        }
    }
}

// MARK: - 应用语言
//
// 用 macOS 标准机制：把选择写进本应用的 AppleLanguages，
// 系统在下次启动时据此挑选 Localizable.strings，因此需要重启才生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system:            return "settings.language.system"
        case .english:           return "settings.language.english"
        case .simplifiedChinese: return "settings.language.chinese"
        }
    }

    /// 写入 / 清除 AppleLanguages
    func apply() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// 当前生效的语言（用于恢复选择状态）
    static var current: AppLanguage {
        guard let code = Bundle.main.preferredLocalizations.first else { return .system }
        return AppLanguage(rawValue: code) ?? .system
    }
}

// MARK: - 设置
struct SettingsView: View {
    let songCount: Int
    let isCustomOrder: Bool
    let isRefreshing: Bool
    let lastRefreshed: Date?
    let onResetOrder: () -> Void
    let onRefresh: () -> Void

    @State private var isConfirmingReset = false
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var isConfirmingRestart = false

    @State private var isCheckingVersion = false
    @State private var versionOutcome: VersionCheck.Outcome? = nil

    var body: some View {
        Form {
            Section("settings.language") {
                Picker("settings.language", selection: $appLanguageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .onChange(of: appLanguageRawValue) { newValue in
                    (AppLanguage(rawValue: newValue) ?? .system).apply()
                    isConfirmingRestart = true
                }
            }

            Section("settings.library") {
                LabeledContent("settings.songCount") {
                    Text("\(songCount)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("settings.lastRead") {
                    Text(lastRefreshedText)
                        .foregroundStyle(.secondary)
                }
                Text("settings.library.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("settings.refresh", action: onRefresh)
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(isRefreshing)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.refreshing")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("settings.order") {
                LabeledContent("settings.order.current") {
                    Text(isCustomOrder ? LocalizedStringKey("settings.order.custom") : LocalizedStringKey("settings.order.default"))
                        .foregroundStyle(.secondary)
                }
                Text("settings.order.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("settings.order.restore") {
                    isConfirmingReset = true
                }
                .disabled(!isCustomOrder)
            }

            Section("settings.version") {
                LabeledContent("settings.version.current") {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("settings.version.check", action: checkForUpdates)
                        .disabled(isCheckingVersion)

                    if isCheckingVersion {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.version.checking")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                versionStatus
            }
        }
        .formStyle(.grouped)
        .alert("settings.order.restore.title", isPresented: $isConfirmingReset) {
            Button("common.cancel", role: .cancel) {}
            Button("settings.order.restore.confirm", role: .destructive, action: onResetOrder)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("settings.order.restore.message")
        }
        .alert("settings.language.restart.title", isPresented: $isConfirmingRestart) {
            Button("common.later", role: .cancel) {}
            Button("common.restart", action: relaunch)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("settings.language.restart.message")
        }
    }

    /// 查询结果：已是最新、有新版本（附安装指引）、或查询失败
    @ViewBuilder
    private var versionStatus: some View {
        if let outcome = versionOutcome {
            switch outcome {
            case .upToDate:
                Label("settings.version.upToDate", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .updateAvailable(let latest):
                VStack(alignment: .leading, spacing: 8) {
                    // 不用 "settings.version.available \(latest)"：字符串插值会生成带
                    // 占位符的查找键（settings.version.available %@），和 .strings 里的
                    // 键对不上，查不到就原样显示键名。这里显式取值再用 %@ 填充。
                    Label {
                        Text(verbatim: VersionCheck.availableMessage(latest: latest))
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .font(.callout)
                    .fontWeight(.semibold)
                    Text("settings.version.guide")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("settings.version.download") {
                        NSWorkspace.shared.open(UpdateChecker.downloadPage)
                    }
                }

            case .failed:
                Label("settings.version.failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checkForUpdates() {
        isCheckingVersion = true
        versionOutcome = nil
        Task {
            let tag = try? await UpdateChecker.latestTag()
            await MainActor.run {
                versionOutcome = VersionCheck.outcome(current: AppVersion.current, latestTag: tag)
                isCheckingVersion = false
            }
        }
    }

    /// 重新启动应用，让新的语言设置生效
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private var lastRefreshedText: String {
        guard let lastRefreshed else { return String(localized: "settings.lastRead.never") }
        return lastRefreshed.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - 尚未实现的栏目
struct ComingSoonView: View {
    let item: SidebarItem

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.title3)
            Text("comingSoon.message")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
