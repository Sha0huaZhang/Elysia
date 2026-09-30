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
    @State private var selectedItem: String? = "歌曲"

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

    @State private var pendingSeekTarget: Double? = nil

    /// 用户按下播放/暂停后的乐观状态
    @State private var pendingPlayState: Bool? = nil
    /// 乐观状态的时间戳，用于超时回滚
    @State private var pendingPlayStateTime: Date? = nil

    @State private var songEndedHandled = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem)
        } detail: {
            detailView
        }
        .frame(minWidth: 800, minHeight: 600)
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
        if selectedItem == "设置" {
            SettingsView(
                songCount: songs.count,
                isCustomOrder: isCustomOrder,
                isRefreshing: isRefreshing,
                lastRefreshed: lastRefreshed,
                onResetOrder: resetOrder,
                onRefresh: refreshLibrary
            )
        } else if selectedItem == "歌曲" || selectedItem == nil {
            playerView
        } else {
            ComingSoonView(title: selectedItem ?? "")
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
                    MusicData.setVolume(newVolume)
                }
            )
            Divider()
            SongListView(
                songs: $songs,
                isLoading: isLoading,
                nowPlayingID: nowPlayingID,
                isPlaying: isPlaying,
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

    /// 重新读取资料库，用于用户在 Apple Music 中增删歌曲之后
    private func refreshLibrary() {
        guard !isRefreshing, !isLoading else { return }
        isRefreshing = true
        Task { await loadSongs() }
    }

    private func startPolling() async {
        var tick = 0
        while !Task.isCancelled {
            let status = await MusicData.fetchPlayerStatus()

            var newVolume: Double? = nil
            if tick % 4 == 0 {
                newVolume = await MusicData.fetchVolume()
            }
            tick += 1

            await MainActor.run {
                if status.isPlaying {
                    self.songEndedHandled = false
                }

                self.nowPlayingID = status.persistentID
                self.nowPlayingTitle = status.title
                self.nowPlayingArtist = status.artist

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

                if self.isDragging {
                    // 拖动中
                } else if let target = self.pendingSeekTarget {
                    if abs(status.position - target) < 1.0 {
                        self.position = status.position
                        self.pendingSeekTarget = nil
                    } else {
                        self.position = target
                    }
                } else {
                    self.position = status.position
                }
                self.duration = status.duration

                if !self.isDraggingVolume, let v = newVolume {
                    self.volume = v
                }

                if status.isStopped, let id = status.persistentID, !self.songEndedHandled {
                    self.songEndedHandled = true
                    self.handleSongEnded(endedID: id)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func handleSongEnded(endedID: String) {
        switch repeatMode {
        case .one:
            MusicData.playSong(persistentID: endedID)
        case .all:
            playOffset(1, fromID: endedID)
        case .off:
            playOffset(1, fromID: endedID, stopAtEnd: true)
        }
    }

    private func playOffset(_ offset: Int, fromID: String? = nil, stopAtEnd: Bool = false) {
        guard !songs.isEmpty else { return }

        let anchorID = fromID ?? nowPlayingID
        let currentIndex: Int?
        if let id = anchorID {
            currentIndex = songs.firstIndex(where: { $0.id == id })
        } else {
            currentIndex = nil
        }

        var targetIndex: Int
        if let current = currentIndex {
            targetIndex = current + offset
        } else {
            targetIndex = offset > 0 ? 0 : songs.count - 1
        }

        if targetIndex < 0 {
            if repeatMode == .all {
                targetIndex = songs.count - 1
            } else {
                return
            }
        } else if targetIndex >= songs.count {
            if repeatMode == .all && !stopAtEnd {
                targetIndex = 0
            } else {
                return
            }
        }

        let targetSong = songs[targetIndex]
        MusicData.playSong(persistentID: targetSong.id)
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

    /// 拖动排序后保存新的顺序
    private func persistOrder(_ ordered: [Song]) {
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

// MARK: - 侧边栏
struct SidebarView: View {
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("设置", systemImage: "gearshape").tag("设置")
                Label("歌曲", systemImage: "music.note").tag("歌曲")
                Label("歌单", systemImage: "music.note.list").tag("歌单")
                Label("专辑", systemImage: "square.stack").tag("专辑")
                Label("开始", systemImage: "play.circle").tag("开始")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
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
                    if !editing {
                        onVolumeChange(dragVolumeValue)
                        isDraggingVolume = false
                    }
                }
            )
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
                    Text(title ?? "未在播放")
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
                        if !editing {
                            onSeek(dragValue)
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
    @Binding var songs: [Song]
    let isLoading: Bool
    let nowPlayingID: String?
    let isPlaying: Bool
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
                ProgressView("正在从 Apple Music 获取歌曲...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("没有找到歌曲").foregroundColor(.secondary)
                    Text("请确认 Apple Music 已登录并拥有资料库")
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
            songs = reordered
        }
        onReorder(songs)
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

// MARK: - 单行歌曲视图
struct SongRowView: View {
    let song: Song
    let isPlaying: Bool
    let isDragging: Bool
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
                    MusicData.playSong(persistentID: song.id)
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
            MusicData.playSong(persistentID: song.id)
        }
        // 用 simultaneousGesture 让拖动与双击播放共存，互不抢占
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    onDragChanged(value.location.y, value.startLocation.y, artworkImage)
                }
                .onEnded { value in
                    onDragEnded(value.location.y, value.startLocation.y)
                }
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

// MARK: - 设置
struct SettingsView: View {
    let songCount: Int
    let isCustomOrder: Bool
    let isRefreshing: Bool
    let lastRefreshed: Date?
    let onResetOrder: () -> Void
    let onRefresh: () -> Void

    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section("曲库") {
                LabeledContent("歌曲数量") {
                    Text("\(songCount)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("上次读取") {
                    Text(lastRefreshedText)
                        .foregroundStyle(.secondary)
                }
                Text("在 Apple Music 中新增或删除歌曲后，点按「刷新歌单」重新读取资料库。自定义排序会保留，新歌会追加到末尾。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("刷新歌单", action: onRefresh)
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(isRefreshing)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("歌曲排序") {
                LabeledContent("当前排序") {
                    Text(isCustomOrder ? "自定义排序" : "默认排序")
                        .foregroundStyle(.secondary)
                }
                Text("在「歌曲」列表中拖动任意歌曲即可调整顺序，新的顺序会自动保存。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("恢复默认排序…") {
                    isConfirmingReset = true
                }
                .disabled(!isCustomOrder)
            }
        }
        .formStyle(.grouped)
        .alert("要恢复默认排序吗？", isPresented: $isConfirmingReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认排序", role: .destructive, action: onResetOrder)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("歌曲将恢复为 Apple Music 资料库中的原始顺序。")
        }
    }

    private var lastRefreshedText: String {
        guard let lastRefreshed else { return "尚未读取" }
        return lastRefreshed.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - 尚未实现的栏目
struct ComingSoonView: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
            Text("该功能还在开发中")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
