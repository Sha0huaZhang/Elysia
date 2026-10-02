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

    /// 把这次读库的结果写进日志：曲目数、位置范围、按自定义顺序补位的新歌、
    /// 以及被自动跳过的坏条目（表现为位置空缺）。
    private func logLibraryRead(_ fetched: [Song]) {
        let positions = fetched.map(\.libraryPosition).filter { $0 > 0 }.sorted()
        var text = "读取资料库 \(fetched.count) 首，位置 \(positions.first ?? 0)..\(positions.last ?? 0)"
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
                let canAct = self.repeatMode == .one || self.songs.contains { $0.id == status.persistentID }
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
                    if !canAct { why.append(self.songs.isEmpty ? "歌单还没读完" : "当前曲不在歌单里") }
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
        songs.first { $0.id == id }.map { "《\($0.title)》" } ?? "id:\(id.prefix(8))"
    }

    /// 日志里用位置标识曲目。位置与界面左侧显示的编号、诊断清单里的编号完全一致。
    private func rowLabel(of id: String) -> String {
        songs.first { $0.id == id }?.positionText ?? "不在歌单里"
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
        guard !songs.isEmpty else { return }

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
            guard let found = songs.firstIndex(where: { $0.id == id }) else {
                Diagnostics.log("advance 放弃：锚点 \(name(of: id)) 不在 Elysia 列表里（共 \(songs.count) 首）")
                return
            }
            anchorIndex = found
        } else {
            anchorIndex = nil
        }

        guard let targetIndex = SongAdvance.targetIndex(
            anchorIndex: anchorIndex,
            count: songs.count,
            offset: offset,
            repeatAll: repeatMode == .all
        ) else {
            Diagnostics.log("advance 放弃：锚点 \(anchorIndex.map { "第\($0 + 1)行" } ?? "无") offset=\(offset) 不产生目标")
            return
        }

        let anchorText = anchorID.map { "\(rowLabel(of: $0)) \(name(of: $0))" } ?? "无"
        let target = songs[targetIndex]
        Diagnostics.log("advance offset=\(offset) 锚点 \(anchorText) -> 目标 \(rowLabel(of: target.id)) 《\(target.title)》")
        playSong(songs[targetIndex].id)
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
            guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
            if index + 1 < songs.count {
                playSong(songs[index + 1].id)
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
                    Diagnostics.log("行内播放按钮：\(song.positionText) 《\(song.title)》")
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
            Diagnostics.log("双击行：\(song.positionText) 《\(song.title)》")
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
                    // 只显示版本号。构建号（CFBundleVersion，打包时写成时间戳）不进界面，
                    // 它用于内部辨认构建：见日志开头与「显示简介」。
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
