import SwiftUI
import AppKit

// MARK: - 歌曲列表
struct SongListView: View {
    let songs: [Song]
    let isLoading: Bool
    let nowPlayingID: String?
    let isPlaying: Bool
    /// 当前是否联网。离线时未下载的曲目播不了，列表里标灰
    let isOnline: Bool
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
                            isPlayable: isOnline || song.isDownloaded,
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
    /// 当前能否播放。离线且未下载时为 false，文字标灰提示播不了
    let isPlayable: Bool
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
                    .foregroundColor(isPlaying ? .red : (isPlayable ? .primary : .secondary))
                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(isPlayable ? .secondary : Color.secondary.opacity(0.6))
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
