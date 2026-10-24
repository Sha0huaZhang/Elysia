import SwiftUI
import AppKit

// MARK: - 歌手
//
// 歌手来自 Apple Music 的资料库：Elysia 只读取，不写入，也不改动资料库里的任何内容。
// 屏蔽只记在 Elysia 自己这边（见 ArtistSettings），被屏蔽的歌手只是从这一页收起来，
// 他的歌曲仍在「歌曲」页、「专辑」页。
struct ArtistsView: View {
    /// 全部歌手（含被屏蔽的）
    let artists: [Artist]
    /// 被屏蔽歌手的比较键
    let hiddenKeys: Set<String>
    /// 侧边栏搜索框的文字
    let searchText: String
    /// 双击歌手：进入他/她的歌曲列表
    let onOpen: (Artist) -> Void
    let onHide: ([String]) -> Void
    let onUnhide: ([String]) -> Void
    let onUnhideAll: () -> Void

    /// 浏览时高亮的那一行
    @State private var highlighted: String? = nil
    /// 选择模式下勾选的歌手
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    /// 是否正在看「屏蔽的歌手」
    @State private var showingHidden = false

    private func isHidden(_ artist: Artist) -> Bool {
        hiddenKeys.contains(ArtistLibrary.comparisonKey(artist.name))
    }

    private var visibleArtists: [Artist] {
        ArtistLibrary.filter(artists.filter { !isHidden($0) }, query: searchText)
    }

    private var hiddenArtists: [Artist] {
        ArtistLibrary.filter(artists.filter(isHidden), query: searchText)
    }

    private var listedArtists: [Artist] { showingHidden ? hiddenArtists : visibleArtists }
    private var selectedArtists: [Artist] { listedArtists.filter { selection.contains($0.id) } }
    private var isSearching: Bool { SongSearch.isActive(searchText) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onChange(of: showingHidden) { _ in endSelecting() }
        // 浏览模式下的快捷键；选择模式里由工具条上的同名按钮接管，这里让开，免得同键两处
        .background {
            Group {
                Button { hideOrUnhideHighlighted() } label: { EmptyView() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            .opacity(0)
            // opacity(0) 只是看不见，按钮仍会挡住下面的点击，必须真的关掉命中测试
            .allowsHitTesting(false)
            .disabled(isSelecting || showingHidden)
            .accessibilityHidden(true)
        }
    }

    // MARK: 顶部工具条

    private var toolbar: some View {
        HStack(spacing: 0) {
            if isSelecting {
                Text(String(format: countFormat("artists.selectedCount"), selection.count))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if showingHidden {
                if isSelecting {
                    button("artists.unhideSelected", shortcut: "⌘I", color: .blue) {
                        guard !selection.isEmpty else { return }
                        onUnhide(selectedArtists.map(\.name))
                        endSelecting()
                    }
                } else {
                    button("artists.unhideAll", shortcut: nil, color: .blue) {
                        onUnhideAll()
                    }
                }
                spacerCharacter()
                button("artists.select", shortcut: "⌘B", color: .blue) {
                    toggleSelecting()
                }
                spacerCharacter()
                button("artists.back", shortcut: nil, color: .blue) {
                    showingHidden = false
                }
            } else {
                if isSelecting {
                    button("artists.hide", shortcut: "⌘I", color: .red) {
                        guard !selection.isEmpty else { return }
                        onHide(selectedArtists.map(\.name))
                        endSelecting()
                    }
                    spacerCharacter()
                    button(isSelecting ? "artists.select.done" : "artists.select", shortcut: "⌘B", color: .blue) {
                        toggleSelecting()
                    }
                    spacerCharacter()
                } else {
                    button("artists.select", shortcut: "⌘B", color: .blue) {
                        toggleSelecting()
                    }
                    spacerCharacter()
                }
                Button {
                    selection = []
                    highlighted = nil
                    showingHidden = true
                } label: {
                    // 红色：这是一个「收起 / 隐藏」的动作，与蓝色的正常操作区分开
                    Text(hiddenEntryTitle)
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.red, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 「屏蔽的歌手」：有被屏蔽的歌手时带上数量，一眼知道里面有没有东西
    private var hiddenEntryTitle: String {
        guard !hiddenKeys.isEmpty else {
            return Bundle.main.localizedString(forKey: "artists.hidden", value: nil, table: nil)
        }
        return String(format: countFormat("artists.hiddenCount"), hiddenCount)
    }

    /// 被屏蔽的歌手数量按**当前资料库里存在的**算：屏蔽过但已经不在资料库里的不算，
    /// 否则按钮上的数字会对不上列表
    private var hiddenCount: Int {
        artists.filter(isHidden).count
    }

    private func button(
        _ title: LocalizedStringKey,
        shortcut: String?,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).foregroundColor(color)
                if let shortcut {
                    Text(shortcut).foregroundColor(color.opacity(0.55))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .modifier(ArtistShortcut(shortcut: shortcut))
    }

    /// 屏幕上「一个文字」的宽度，让两个按钮之间不会挤在一起
    private func spacerCharacter() -> some View {
        Text("字").font(.body).hidden()
    }

    private func toggleSelecting() {
        if isSelecting {
            endSelecting()
        } else {
            selection = []
            isSelecting = true
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if listedArtists.isEmpty {
            emptyState
        } else if isSelecting {
            List {
                ForEach(listedArtists) { artist in
                    ArtistPickRow(
                        artist: artist,
                        isSelected: selection.contains(artist.id),
                        onToggle: { toggle(artist.id) }
                    )
                }
            }
            .listStyle(.plain)
        } else {
            List(selection: $highlighted) {
                ForEach(listedArtists) { artist in
                    ArtistRow(
                        artist: artist,
                        onOpen: {
                            highlighted = artist.id
                            if showingHidden {
                                Diagnostics.log("解除屏蔽歌手《\(artist.name)》")
                                onUnhide([artist.name])
                            } else {
                                Diagnostics.log("进入歌手《\(artist.name)》，\(artist.songs.count) 首")
                                onOpen(artist)
                            }
                        },
                        onSelect: { highlighted = artist.id }
                    )
                    .tag(artist.id)
                    .contextMenu {
                        if showingHidden {
                            Button("artists.unhide") {
                                Diagnostics.log("解除屏蔽歌手《\(artist.name)》")
                                onUnhide([artist.name])
                            }
                            .keyboardShortcut("i", modifiers: .command)
                        } else {
                            Button("artists.hide", role: .destructive) {
                                Diagnostics.log("屏蔽歌手《\(artist.name)》")
                                onHide([artist.name])
                            }
                            .keyboardShortcut("i", modifiers: .command)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyIcon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(emptyTitle).foregroundColor(.secondary)
            Text(emptyHint)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 可见的歌手全被屏蔽了：空状态要说清楚去哪里找回来，而不是「还没有歌手」
    private var allHidden: Bool {
        !showingHidden && !isSearching && visibleArtists.isEmpty && hiddenCount > 0
    }

    private var emptyIcon: String {
        if isSearching { return "magnifyingglass" }
        if allHidden { return "eye.slash" }
        return showingHidden ? "eye.slash" : "music.mic"
    }

    private var emptyTitle: LocalizedStringKey {
        if isSearching { return "artists.noMatch.title" }
        if allHidden { return "artists.allHidden.title" }
        return showingHidden ? "artists.hidden.empty.title" : "artists.empty.title"
    }

    private var emptyHint: LocalizedStringKey {
        if isSearching { return "artists.noMatch.hint" }
        if allHidden { return "artists.allHidden.hint" }
        return showingHidden ? "artists.hidden.empty.hint" : "artists.empty.hint"
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    /// 浏览模式下被选中（高亮）的那个歌手
    private var highlightedArtist: Artist? {
        guard let highlighted else { return nil }
        return listedArtists.first { $0.id == highlighted }
    }

    /// ⌘I：屏蔽高亮的歌手；在「屏蔽的歌手」里则是解除屏蔽。
    private func hideOrUnhideHighlighted() {
        guard let artist = highlightedArtist else {
            Diagnostics.log("未选中歌手，\(showingHidden ? "解除屏蔽" : "屏蔽")已忽略")
            return
        }
        if showingHidden {
            Diagnostics.log("解除屏蔽歌手《\(artist.name)》")
            onUnhide([artist.name])
        } else {
            Diagnostics.log("屏蔽歌手《\(artist.name)》")
            onHide([artist.name])
            highlighted = nil
        }
    }

    private func countFormat(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// 快捷键可有可无：`keyboardShortcut` 不接受 nil，只能整个修饰符按需挂上
private struct ArtistShortcut: ViewModifier {
    let shortcut: String?

    func body(content: Content) -> some View {
        switch shortcut {
        case "⌘I":
            content.keyboardShortcut("i", modifiers: .command)
        case "⌘B":
            content.keyboardShortcut("b", modifiers: .command)
        default:
            content
        }
    }
}

// MARK: - 歌手行
//
// 与专辑行同一套样式（封面 + 名称 + 副标题），三个页面看起来是一家人。
private struct ArtistRow: View {
    let artist: Artist
    let onOpen: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtistArtwork(artist: artist)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // 与专辑行一致：点箭头进入，双击整行也能进入
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("artists.open")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // List 自己的选中判定会和双击手势抢同一次单击，用同时手势自己处理单击
        .onTapGesture(count: 2) { onOpen() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
    }

    private var subtitle: String {
        let albums = String(format: countFormat("artists.albumCount"), artist.albumCount)
        let songs = String(format: countFormat("artists.songCount"), artist.songs.count)
        return albums + " · " + songs
    }

    private func countFormat(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// 选择模式下的歌手行：同一份内容 + 行尾的选中标记
private struct ArtistPickRow: View {
    let artist: Artist
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtistArtwork(artist: artist)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(String(format: countFormat("artists.songCount"), artist.songs.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .red : .secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private func countFormat(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// 歌手封面：取他/她第一首有封面的曲目，与专辑共用同一份缓存
private struct ArtistArtwork: View {
    let artist: Artist

    @State private var artworkImage: NSImage? = nil

    var body: some View {
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
        .task(id: artist.songs.first?.id) {
            guard let first = artist.songs.first else {
                artworkImage = nil
                return
            }
            let image = await MusicData.artwork(for: first.artworkKey, persistentID: first.id)
            guard !Task.isCancelled else { return }
            artworkImage = image
        }
    }
}
