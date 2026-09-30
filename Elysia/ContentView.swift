import SwiftUI
import AppKit

// MARK: - 主视图
struct ContentView: View {
    @State private var nowPlayingID: String? = nil
    @State private var isPlaying: Bool = false
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var repeatMode: RepeatMode = .off

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
            SidebarView()
        } detail: {
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
                    songs: songs,
                    isLoading: isLoading,
                    nowPlayingID: nowPlayingID,
                    isPlaying: isPlaying
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task {
            MusicData.forceRepeatOff()
            await initialLoad()
            let v = await MusicData.fetchVolume()
            await MainActor.run { self.volume = v }
            await startPolling()
        }
    }

    private func initialLoad() async {
        let fetched = await Task.detached(priority: .userInitiated) {
            MusicData.fetchAllSongs()
        }.value
        await MainActor.run {
            self.songs = fetched
            self.isLoading = false
        }
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
}

// MARK: - 侧边栏
struct SidebarView: View {
    @State private var selectedItem: String? = "歌曲"

    var body: some View {
        List(selection: $selectedItem) {
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
    let songs: [Song]
    let isLoading: Bool
    let nowPlayingID: String?
    let isPlaying: Bool

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

#Preview {
    ContentView()
}
