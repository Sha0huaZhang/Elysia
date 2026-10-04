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

    /// 接管后的冷却截止时间。脚本是异步下发的，下一轮轮询可能还没看到效果而重复触发，
    /// 造成反复申请（实测出现同一首 0.07 秒内申请 5 次）。冷却可挡住这类重复。
    @State private var takeoverBlockedUntil: Date? = nil
    @State private var selectedItem: SidebarItem? = .songs
    /// 当前打开的 Elysia 歌单；nil 表示停在歌单列表
    @State private var openedPlaylist: Playlist? = nil
    /// 歌单详情页是否正在编辑歌曲
    @State private var isEditingSongs = false
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

    /// 已排定接管的曲目，以及应当接管下一首的时刻。
    /// 曲目开始时算一次，到点触发一次——不解读每次轮询的剩余时间，避免被滞后数据骗到。

    /// 连续两次观察到同一首才算「稳定曲目」，用来当锚点。
    ///
    /// 切歌过程中 Apple Music 处于过渡态：它会在几首之间来回报「当前曲目」（界面上
    /// 甚至同时给多首显示正在播放标识）。单次读数因此不可信，锚点会跟着乱跳，算出的
    /// 目标自然「毫无规律」。要求连续两轮一致，即可滤掉这种抖动。
    @State private var candidateTrackID: String? = nil
    @State private var stableTrackID: String? = nil

    /// 已经提示过使用须知的版本号。按版本记录，所以更新后还会再提示一次，日常启动不打扰。
    @AppStorage("promptedVersion") private var promptedVersion = ""
    @State private var isShowingWelcome = false

    /// 网络可达性：离线时只有已下载的曲目能播
    @StateObject private var network = NetworkMonitor()
    /// 点选了离线时播不了的曲目，弹出说明
    @State private var isShowingOfflineBlocked = false

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
        // 离线时点了未下载的曲目：说明为什么播不了，只有一个「知道了」
        .alert("offline.blocked.title", isPresented: $isShowingOfflineBlocked) {
            Button("common.gotIt") {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("offline.blocked.message")
        }
        .task(id: nowPlayingID) {
            await loadNowPlayingArtwork()
        }
        .task {
            Diagnostics.markSession()
            MusicData.forceSequentialPlayback()
            // 接管 F7/F8/F9，走与界面按钮完全相同的逻辑
            MediaKeys.install(
                onPrevious: { playOffset(-1) },
                onNext: { playOffset(1) },
                onTogglePlayPause: { togglePlayPause() }
            )
            await loadSongs()
            let v = await MusicData.fetchVolume()
            await MainActor.run { self.volume = v }
            await startPolling()
        }
        // 在 Apple Music 里增删歌曲后，切回 Elysia 立即重新读取，新歌直接出现在
        // 它在资料库中的位置，不必等到下次启动
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLibrary()
        }
        // 换到别的栏目时退出歌单，回来看到的是歌单列表而不是上次那个歌单
        .onChange(of: selectedItem) { _ in
            openedPlaylist = nil
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
        case .playlists:
            if openedPlaylist != nil {
                playlistDetailView
            } else {
                PlaylistsView(songs: songs, onOpen: { openedPlaylist = $0 })
            }
        case .albums, .start:
            ComingSoonView(item: selectedItem ?? .songs)
        }
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            songList(
                displayed: visibleSongs,
                // 搜索结果只是原列表的视图，拖动会打乱真实顺序，因此搜索时禁用
                isReorderEnabled: !isSearching,
                onReorder: persistOrder
            )
        }
    }

    /// 进入某个歌单后的详情页。
    ///
    /// 与「歌曲」页用同一个控制条和同一个歌曲列表，因此样式与操作完全一致；区别只有
    /// 列表来源，以及顶部多一条返回。
    private var playlistDetailView: some View {
        VStack(spacing: 0) {
            playlistDetailBar
            Divider()
            controlBar
            Divider()
            songList(
                displayed: visibleSongs,
                // 歌单的顺序调整留待后续；先把「歌曲」页的拖动挡在外面，避免改了这里却存不进歌单
                isReorderEnabled: false,
                onReorder: persistOrder
            )
        }
    }

    /// 歌单详情顶部：返回歌单（⌘[）+ 当前歌单名
    private var playlistDetailBar: some View {
        HStack(spacing: 0) {
            Button {
                openedPlaylist = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("playlists.back")
                    Text("⌘[").foregroundColor(Color.blue.opacity(0.55))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)

            // 一个文字的宽度
            Text("字").font(.body).hidden()

            Text(openedPlaylist?.name ?? "")
                .font(.title3)
                .foregroundColor(.primary)

            Spacer()

            Button { isEditingSongs = true } label: {
                HStack(spacing: 4) {
                    Text("playlists.edit").foregroundColor(.blue)
                    Text("⌘E").foregroundColor(Color.blue.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .sheet(isPresented: $isEditingSongs) { editSongsSheet }
    }

    /// 编辑歌曲：与新建歌单同一个窗口，只是名字与已有曲目都已经填好。
    @ViewBuilder
    private var editSongsSheet: some View {
        if let playlist = openedPlaylist {
            PlaylistSheet(
                titleKey: "playlists.edit.title",
                songs: songs,
                initialName: playlist.name,
                initialOrder: playlist.songIDs,
                nameExists: { PlaylistStore().contains(name: $0, excluding: playlist.id) },
                onConfirm: { name, songIDs in
                    isEditingSongs = false
                    guard let updated = PlaylistStore().update(id: playlist.id, name: name, songIDs: songIDs) else { return }
                    Diagnostics.log("编辑歌单《\(updated.name)》，共 \(songIDs.count) 首")
                    // 详情页读的是这份值拷贝，改完要换掉，否则界面还显示旧的曲目
                    openedPlaylist = updated
                },
                onCancel: { isEditingSongs = false }
            )
        }
    }

    /// 播放控制条。两个页面共用，保证操作与样式一致。
    private var controlBar: some View {
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
                // 关键：立刻把显示值也移到目标。否则松手瞬间 isDragging 变 false，
                // 显示值切回尚未更新的 position（旧位置），滑块先弹回去，等下一次
                // 轮询（最长 0.5s）才跳回来——看起来就是「跳一下」。
                position = seconds
                pendingSeekTarget = seconds
            },
            onVolumeChange: { newVolume in
                applyVolumeWhileDragging(newVolume)
            },
            onVolumeCommit: { newVolume in
                commitVolume(newVolume)
            }
        )
    }

    private func songList(
        displayed: [Song],
        isReorderEnabled: Bool,
        onReorder: @escaping ([Song]) -> Void
    ) -> some View {
        SongListView(
            songs: displayed,
            isLoading: isLoading,
            nowPlayingID: nowPlayingID,
            isPlaying: isPlaying,
            isOnline: network.isOnline,
            isReorderEnabled: isReorderEnabled,
            isSearching: isSearching,
            onPlay: playFromList,
            onReorder: onReorder
        )
    }

    /// 把这次读库的结果写进日志：曲目数、位置范围、按自定义顺序补位的新歌、
    /// 以及被自动跳过的坏条目（表现为位置空缺）。
    private func logLibraryRead(_ fetched: [Song]) {
        let positions = fetched.map(\.libraryPosition).filter { $0 > 0 }.sorted()
        var text = "读取资料库 \(fetched.count) 首，位置 \(positions.first ?? 0)..\(positions.last ?? 0)"
        text += "；其中 \(fetched.filter { !$0.isDownloaded }.count) 首未下载（离线时播不了）"
        if let saved = orderStore.savedIDs {
            text += "；其中 \(fetched.filter { !saved.contains($0.id) }.count) 首不在自定义顺序里，已插回资料库中的位置"
        }
        if let highest = positions.last {
            let gaps = (1...highest).filter { !positions.contains($0) }
            if !gaps.isEmpty {
                text += "；位置 \(gaps.map(String.init).joined(separator: "、")) 的条目在资料库里读不出来，已自动跳过"
            }
        }
        Diagnostics.log(text)
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
            Diagnostics.dumpList(self.songs)
            self.logLibraryRead(fetched)
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

            // 常规间隔轮询，临近曲末时贴着截止时刻醒
            var nextSleep: TimeInterval = TrackEnd.base

            await MainActor.run {
                // 在本轮改动 nowPlayingID 之前先判断曲目是否变了
                let trackChanged = status.persistentID != self.nowPlayingID

                // 曲目变了，但不是 Elysia 刚请求的那一首 —— 说明是外部改的
                // （Apple Music 自己的队列、或在 Music 窗口里的操作）。
                // 这类换曲 Elysia 无从阻止，但必须能看出来，否则「跳错歌」只能靠猜。
                if trackChanged, let newID = status.persistentID {
                    if self.pendingSongID == newID {
                        // 自己请求的，随后会清掉 pendingSongID
                    } else if let pending = self.pendingSongID {
                        Diagnostics.log("外部换曲：Elysia 请求的是 \(rowLabel(of: pending)) \(name(of: pending))，实际变为 \(rowLabel(of: newID)) \(name(of: newID))")
                    } else {
                        Diagnostics.log("外部换曲：变为 \(rowLabel(of: newID)) \(name(of: newID))（Elysia 未请求换曲）")
                    }
                }

                self.nowPlayingID = status.persistentID
                self.nowPlayingTitle = status.title
                self.nowPlayingArtist = status.artist

                // 把曲目发布给系统：认领「正在播放」位置后，F7/F8/F9 才会路由到 Elysia
                MediaKeys.update(
                    title: status.title,
                    artist: status.artist,
                    duration: status.duration,
                    position: status.position,
                    isPlaying: status.isPlaying
                )

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

                // 曲目结束时接管，按 Elysia 自己的顺序申请下一首。
                //
                // 连续两轮观察到同一首才认可为「稳定曲目」，用作「下一首」的锚点。
                // 切歌时 Music 会在几首之间来回报当前曲目，单次读数可能是过渡态。
                if let id = status.persistentID {
                    if id == self.candidateTrackID {
                        if self.stableTrackID != id {
                            self.stableTrackID = id
                            Diagnostics.log("曲目稳定 = \(self.rowLabel(of: id)) \(self.name(of: id))")
                        }
                    } else {
                        if self.stableTrackID != id {
                            Diagnostics.log("曲目候选 \(self.rowLabel(of: id)) \(self.name(of: id))（上一候选 \(self.candidateTrackID.map { self.name(of: $0) } ?? "无")），等下一轮确认")
                        }
                        self.candidateTrackID = id
                        // 曲目变了，之前确认过的稳定值已经过期，作废以免长期滞后一首
                        self.stableTrackID = nil
                    }
                }

                // 曲目结束时由 Elysia 接管（见 TrackEnd 的说明：Music 的循环对
                // `play <track>` 启动的播放全部失效，必须自己处理）。
                //
                // 每轮都按当前进度判断，而不是每首歌只算一次。进度会变：用户拖动进度条
                // 或跳转到别处之后，先前算出的时刻就过期了。每轮判断则始终对准。
                // 换曲 / 跳转在途时不动手：此刻读到的是旧位置，据此判断会误触发。
                let remaining = status.duration > 0 ? status.duration - status.position : nil
                let inFlight = self.pendingSongID != nil || self.pendingSeekTarget != nil
                let cooling = self.takeoverBlockedUntil.map { Date() < $0 } ?? false

                // 单曲循环不依赖歌单；列表循环 / 不循环必须能查到当前曲目才算得出下一首，
                // 因此歌单尚未读完时要明确跳过（并记录），否则会静默失效、被 Music 队列接走。
                let canAct = self.repeatMode == .one || self.activeSongs.contains { $0.id == status.persistentID }
                let due = TrackEnd.shouldTakeOver(remaining: remaining, isPlaying: status.isPlaying)
                if !inFlight, !cooling, let id = status.persistentID, canAct, due {
                    Diagnostics.log("曲末接管：\(self.rowLabel(of: id)) \(self.name(of: id)) 模式=\(self.repeatMode.rawValue) 剩余=\(String(format: "%.1f", remaining ?? -1))s")
                    self.takeoverBlockedUntil = Date().addingTimeInterval(2.0)
                    self.handleTrackEnded(id)
                } else if due {
                    // 到了该动手的时候却没动手：把原因记下来，免得只能靠猜
                    var why: [String] = []
                    if inFlight { why.append("有切歌/跳转在途") }
                    if cooling { why.append("冷却中") }
                    if !canAct { why.append(self.activeSongs.isEmpty ? "歌单还没读完" : "当前曲不在歌单里") }
                    Diagnostics.log("该接管却跳过：\(why.joined(separator: "、"))")
                }

                nextSleep = TrackEnd.sleepInterval(
                    remaining: remaining,
                    isPlaying: status.isPlaying,
                    fetchSeconds: fetchSeconds
                )
            }
            try? await Task.sleep(nanoseconds: TrackEnd.sleepNanoseconds(nextSleep))
        }
    }

    /// 用户在列表里点选某一首（双击行，或点行内的播放按钮）。
    ///
    /// 与自动接管、上一首/下一首分开：只有这里会替用户挡下「离线又没下载」的曲目并
    /// 给出说明。自动接管若也弹窗，切歌时会连续弹；「下一首」若也弹窗，连按就更糟。
    private func playFromList(_ id: String) {
        guard let song = activeSongs.first(where: { $0.id == id }) else { return }

        // 已经在播的这首：此时按钮是「暂停」，与能否离线播放无关，照旧放行
        if id == nowPlayingID { playSong(id); return }

        guard canPlay(song) else {
            Diagnostics.log("离线且未下载，未播放：\(song.positionText) 《\(song.title)》")
            isShowingOfflineBlocked = true
            return
        }
        playSong(id)
    }

    /// 这首歌当前能否播放。
    ///
    /// 联网时一律交给 Apple Music 决定——能否连通由它判断，界面不替用户下结论。
    /// 只有离线这一种确定的情况才拦截：此时未下载到本机的曲目必然播不了。
    private func canPlay(_ song: Song) -> Bool {
        network.isOnline || song.isDownloaded
    }

    /// 播放指定歌曲，并记下乐观锚点。
    ///
    /// 顺序一律以 Elysia 自己的列表为准（含用户拖拽后的自定义顺序），不使用
    /// Apple Music 的播放队列：一旦下发具体歌曲，后续「上一首 / 下一首」就都按
    /// Elysia 的列表推算，与拖拽排序保持一致。
    private func playSong(_ id: String) {
        Diagnostics.log("playSong 申请播放 \(rowLabel(of: id)) \(name(of: id))  id=\(id)")
        pendingSongID = id
        pendingSongIDTime = Date()
        // 进度条立刻归零，不等下一次轮询；同时丢弃属于上一首的跳转目标，
        // 否则它会继续按旧目标校正，新歌的进度条会停在旧位置。
        position = 0
        pendingSeekTarget = nil
        MusicData.playSong(persistentID: id)
    }

    /// 日志里显示歌名，便于人工核对（找不到就显示截断的 ID）
    private func name(of id: String) -> String {
        activeSongs.first { $0.id == id }.map { "《\($0.title)》" } ?? "id:\(id.prefix(8))"
    }

    /// 日志里用位置标识曲目。位置与界面左侧显示的编号、诊断清单里的编号完全一致。
    private func rowLabel(of id: String) -> String {
        activeSongs.first { $0.id == id }?.positionText ?? "不在歌单里"
    }

    /// 上一首 / 下一首。
    ///
    /// 锚点顺序：本次显式指定 → 上一次请求的歌 → **现场向 Apple Music 询问当前在播
    /// 哪首** → 轮询值。
    ///
    /// 中间那一步是关键。轮询最长滞后半秒，而 Apple Music 会在曲末自己顺着资料库
    /// 往下走，此时缓存的 nowPlayingID 已经过期，用它推算就会跳到错的那一首（甚至
    /// 往回跳）。所以按下的这一刻现问一次，确保锚点与 Music 的实际进度一致。
    private func playOffset(_ offset: Int, fromID: String? = nil) {
        guard !activeSongs.isEmpty else { return }

        if let anchorID = fromID ?? pendingSongID {
            advance(offset: offset, anchorID: anchorID)
            return
        }

        // 现场询问 Music 当前在播哪首：按下这一刻的真相，优先于滞后的轮询值
        Task {
            let live = await MusicData.fetchCurrentTrackID()
            await MainActor.run {
                let anchor = SongAdvance.fallbackAnchor(live: live, polled: stableTrackID)
                Diagnostics.log("按下 \(offset > 0 ? "下一首" : "上一首")：现场查询 = \(live.map { name(of: $0) } ?? "空")；稳定曲目 = \(stableTrackID.map { name(of: $0) } ?? "空")")
                guard let anchor else {
                    // 两者都取不到（例如 AppleScript 偶发失败）时宁可不动作。
                    // 若把 nil 当锚点，索引推算会从列表两端开始，跳到第一首毫不相干的歌。
                    Diagnostics.log("按下 \(offset > 0 ? "下一首" : "上一首")：取不到当前曲目，不动作")
                    return
                }
                advance(offset: offset, anchorID: anchor)
            }
        }
    }

    /// 按锚点算出目标歌并申请播放。顺序一律以 Elysia 自己的列表为准
    /// （含用户拖拽后的自定义顺序），不使用 Apple Music 的播放队列。
    private func advance(offset: Int, anchorID: String?) {
        let anchorIndex: Int?
        if let id = anchorID {
            // 知道有歌在播、却不在 Elysia 的列表里（例如正在播 Apple Music 目录里的
            // 曲目而非资料库曲目），就无从推算。此时宁可不动作——SongAdvance 对「锚点
            // 未知」的处理是从列表两端开始，那会跳到第一首毫不相干的歌，正是「跳错歌
            // 又找不出规律」的另一个来源。
            guard let found = activeSongs.firstIndex(where: { $0.id == id }) else {
                Diagnostics.log("advance 放弃：锚点 \(name(of: id)) 不在 Elysia 列表里（共 \(activeSongs.count) 首）")
                return
            }
            anchorIndex = found
        } else {
            anchorIndex = nil
        }

        guard let targetIndex = SongAdvance.targetIndex(
            anchorIndex: anchorIndex,
            count: activeSongs.count,
            offset: offset,
            repeatAll: repeatMode == .all
        ) else {
            Diagnostics.log("advance 放弃：锚点 \(anchorIndex.map { "第\($0 + 1)行" } ?? "无") offset=\(offset) 不产生目标")
            return
        }

        let anchorText = anchorID.map { "\(rowLabel(of: $0)) \(name(of: $0))" } ?? "无"
        let target = activeSongs[targetIndex]
        Diagnostics.log("advance offset=\(offset) 锚点 \(anchorText) -> 目标 \(rowLabel(of: target.id)) 《\(target.title)》")
        playSong(activeSongs[targetIndex].id)
    }

    private func cycleRepeatMode() {
        let previous = repeatMode
        switch repeatMode {
        case .off:  repeatMode = .all
        case .all:  repeatMode = .one
        case .one:  repeatMode = .off
        }
        Diagnostics.log("点击循环按钮：\(previous.rawValue) -> \(repeatMode.rawValue)")
    }

    /// 曲末接管：按当前模式决定下一步。
    ///
    /// 单曲循环用「把播放头绕回开头」（`play` 同一首是空操作，不会重新开始）；
    /// 其余两种模式申请目标曲目。
    private func handleTrackEnded(_ id: String) {
        switch repeatMode {
        case .one:
            // 单曲循环不需要歌单，因此启动后资料库尚未读完时也能正常工作
            MusicData.restartCurrentTrack()
        case .all:
            playOffset(1, fromID: id)
        case .off:
            guard let index = activeSongs.firstIndex(where: { $0.id == id }) else { return }
            if index + 1 < activeSongs.count {
                playSong(activeSongs[index + 1].id)
            } else {
                MusicData.pause()
            }
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

    /// 当前详情页的曲目：「歌曲」页是资料库列表，进入歌单后是这个歌单的曲目。
    ///
    /// 显示、搜索、编号、以及「上一首 / 下一首」都以它为准，所以「看到的列表就是会播放
    /// 的顺序」。歌单里对不上资料库的曲目（已被删除、或读不出属性的坏条目）在这里就被
    /// 丢掉，编号因此始终连续。
    private var activeSongs: [Song] {
        guard let playlist = openedPlaylist else { return songs }
        return playlist.resolvedSongs(in: Song.index(songs))
    }

    /// 列表实际显示的歌曲：搜索时是匹配结果，否则是完整列表
    private var visibleSongs: [Song] {
        SongSearch.filter(activeSongs, query: searchText)
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

#Preview {
    ContentView()
}
