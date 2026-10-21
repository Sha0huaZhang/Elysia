import SwiftUI
import AppKit

// MARK: - 歌单选歌窗口
//
// 挑歌 + 起名，新建与编辑共用：编辑时只是把名字与已有曲目预先填好，其余完全一样。
// 歌单只存进 Elysia 内部，这里不会写入 Apple Music。
struct PlaylistSheet: View {
    /// 标题（新建歌单 / 编辑歌曲）
    let titleKey: LocalizedStringKey
    let songs: [Song]
    /// 该名字是否已被占用（同名歌单不允许重复；编辑时会把正在编辑的这个排除在外）
    let nameExists: (String) -> Bool
    /// 确认：带回名字与选中的曲目
    let onConfirm: (String, [String]) -> Void
    let onCancel: () -> Void

    /// 编辑前的曲目顺序，用来保留歌单里原有的先后
    private let initialOrder: [String]

    @State private var name: String
    @State private var query = ""
    @State private var selected: Set<String>
    /// 用户在没有名称时按过「确认」，据此提示需要填名字
    @State private var didAttemptWithoutName = false
    /// 各行的全局位置，用来把「指针拖到哪」换算成第几行
    @State private var rowFrames: [String: CGRect] = [:]
    /// 开始拖选那一刻已有的选中项，每次重新计算范围都以它为基准
    @State private var selectionBeforeDrag: Set<String>? = nil
    /// 拖选起点所在的行，拖动过程中不变
    @State private var dragAnchorIndex: Int? = nil

    init(
        titleKey: LocalizedStringKey,
        songs: [Song],
        initialName: String = "",
        initialOrder: [String] = [],
        nameExists: @escaping (String) -> Bool,
        onConfirm: @escaping (String, [String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.titleKey = titleKey
        self.songs = songs
        self.initialOrder = initialOrder
        self.nameExists = nameExists
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _selected = State(initialValue: Set(initialOrder))
    }

    private var visibleSongs: [Song] { SongSearch.filter(songs, query: query) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { !trimmedName.isEmpty && nameExists(trimmedName) }
    private var needsName: Bool { didAttemptWithoutName && trimmedName.isEmpty }

    /// 选中曲目的顺序。规则见 Playlist.orderedSelection——原有序曲目保留歌单内的先后，
    /// 新选的按歌曲列表先后接上。
    private var orderedSelection: [String] {
        Playlist.orderedSelection(selected: selected, existingOrder: initialOrder, librarySongs: songs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            songList
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    // MARK: 顶部：名字 + 搜索
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey)
                .font(.headline)

            HStack(spacing: 8) {
                Text("playlists.name.label")
                    .foregroundColor(.secondary)
                TextField("playlists.name.placeholder", text: $name)
                    .textFieldStyle(.roundedBorder)
                    // 粘贴几万个字符时只保留上限内的内容：否则主线程要先排一次几万字符的
                    // 文字，界面直接卡住
                    .onChange(of: name) { newValue in
                        if newValue.count > LibraryLimits.playlistName {
                            name = String(newValue.prefix(LibraryLimits.playlistName))
                        }
                    }
            }

            if isDuplicate {
                Text("playlists.duplicate")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if needsName {
                Text("playlists.name.required")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            searchField
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("search.placeholder", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { query = "" }

            if !query.isEmpty {
                Button {
                    query = ""
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
    }

    // MARK: 歌曲列表
    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("songs.empty.title").foregroundColor(.secondary)
                Text("songs.empty.hint")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleSongs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("songs.noMatch.title").foregroundColor(.secondary)
                Text("songs.noMatch.hint")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visibleSongs) { song in
                PlaylistPickRow(
                    song: song,
                    isSelected: selected.contains(song.id),
                    onToggle: { toggle(song.id) },
                    onDragAcross: { startY, currentY in
                        extendSelection(startY: startY, currentY: currentY)
                    },
                    onDragEnded: endRangeSelection
                )
            }
            .listStyle(.plain)
            .onPreferenceChange(PickRowFramesKey.self) { rowFrames = $0 }
        }
    }

    // MARK: 底部：已选数量 + 取消 / 确认
    //
    // 两个按钮沿用歌单页那对按钮的样式：取消与「删除歌单」同为红色，确认与「新建歌单」
    // 同为蓝色，快捷键用同色更淡的一档。都不使用 .disabled——禁用态会把颜色一起调暗，
    // 看起来发灰；改成点按时在动作里判断，并按需要给出提示文字。
    private var footer: some View {
        HStack(spacing: 12) {
            Text(selectedCountText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Text("common.cancel").foregroundColor(.red)
                    // 快捷键提示用更柔和的红，不与按钮名抢眼；Esc 与 ⌘. 是等价的两种按法
                    Text("Esc").foregroundColor(Color.red.opacity(0.55))
                    Text("或").foregroundColor(Color.red.opacity(0.55))
                    Text("⌘.").foregroundColor(Color.red.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: confirm) {
                HStack(spacing: 4) {
                    Text("playlists.confirm").foregroundColor(.blue)
                    Text("⌘Enter").foregroundColor(Color.blue.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
        // ⌘. 是 macOS 上「取消」的另一种标准按法。一个按钮只能挂一个快捷键，所以另放
        // 一个零尺寸按钮承载它。放在 background 里是为了不参与上面的布局——夹在两个
        // 按钮之间的话，HStack 会在它两侧各留一份间距，把那两个按钮撑开一倍。
        // allowsHitTesting(false) 必不可少：opacity(0) 只是看不见，不影响命中测试，
        // 而 frame 又不裁剪，按钮会以自身尺寸叠在内容上，把点击吃掉。
        .background(
            Button(action: onCancel) { EmptyView() }
                .keyboardShortcut(".", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private var selectedCountText: String {
        let format = Bundle.main.localizedString(
            forKey: "playlists.selectedCount", value: nil, table: nil
        )
        return String(format: format, selected.count)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    // MARK: 按住拖动、一次选中一片

    /// 把起点行到当前指针行之间的行都选上。
    ///
    /// 每次都从「拖动开始时的选中项」重新算，而不是在现有选中项上累加：这样往回拖时
    /// 范围会跟着缩小，结果只取决于拖到哪里，来回晃动也不会越选越多。
    private func extendSelection(startY: CGFloat, currentY: CGFloat) {
        let frames = visibleSongs.map { rowFrames[$0.id] }
        guard let current = RowRangeSelect.index(atY: currentY, frames: frames) else { return }

        if selectionBeforeDrag == nil {
            selectionBeforeDrag = selected
            dragAnchorIndex = RowRangeSelect.index(atY: startY, frames: frames)
        }
        guard let anchor = dragAnchorIndex else { return }

        var next = selectionBeforeDrag ?? []
        for index in RowRangeSelect.span(anchor, current) {
            next.insert(visibleSongs[index].id)
        }
        if next != selected { selected = next }
    }

    private func endRangeSelection() {
        selectionBeforeDrag = nil
        dragAnchorIndex = nil
    }

    private func confirm() {
        guard !trimmedName.isEmpty else {
            didAttemptWithoutName = true
            return
        }
        guard !isDuplicate else { return }
        onConfirm(trimmedName, orderedSelection)
    }
}

// MARK: - 选歌行
//
// 选中时圆点、封面边框、文字一起变红（文字同时加粗），一眼能看出选了哪些。
private struct PlaylistPickRow: View {
    let song: Song
    let isSelected: Bool
    let onToggle: () -> Void
    /// 按住拖动时回调（起点 Y、当前 Y，均为全局坐标）
    let onDragAcross: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void

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
                    .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
            )
            .task { await loadArtwork() }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundColor(isSelected ? .red : .primary)
                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .red : .secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PickRowFramesKey.self,
                    value: [song.id: geo.frame(in: .global)]
                )
            }
        )
        .onTapGesture { onToggle() }
        // 与单击并存：只有移动超过 3pt 才算拖选，单击仍然是切换这一行
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    onDragAcross(value.startLocation.y, value.location.y)
                }
                .onEnded { _ in onDragEnded() }
        )
    }

    private func loadArtwork() async {
        guard artworkImage == nil else { return }
        let image = await MusicData.fetchArtwork(persistentID: song.id)
        await MainActor.run { self.artworkImage = image }
    }
}

/// 选歌窗口里各行的全局位置，供拖选时把指针换算成行号
private struct PickRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
