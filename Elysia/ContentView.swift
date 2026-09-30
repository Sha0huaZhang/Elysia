import SwiftUI
import AppKit

// MARK: - 主视图
struct ContentView: View {
    @State private var nowPlayingID: String? = nil
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
                onTogglePlayPause: {
                    let newState = !isPlaying
                    isPlaying = newState
                    pendingPlayState = newState
                    pendingPlayStateTime = Date()
                    MusicData.togglePlayPause()
                },
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
        HStack(spacing: 20) {
            HStack(spacing: 20) {
                Button(action: onPrevious) {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)

                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)

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

            Text(formatTime(isDragging ? dragValue : position))
                .font(.caption)
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
            .frame(height: 12)

            Text(formatTime(duration))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()

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
            .frame(width: 50, height: 12)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
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
                List {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: song.id == nowPlayingID && isPlaying
                        )
                    }
                    .onMove { source, destination in
                        songs.move(fromOffsets: source, toOffset: destination)
                        onReorder(songs)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - 单行歌曲视图
struct SongRowView: View {
    let song: Song
    let isPlaying: Bool

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

            if isHovering {
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            MusicData.playSong(persistentID: song.id)
        }
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
