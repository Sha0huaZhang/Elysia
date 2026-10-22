import SwiftUI
import AppKit

// MARK: - 专辑
//
// 专辑来自 Apple Music 的资料库：Elysia 只读取，不写入，也不改动资料库里的任何内容。
// 改名与屏蔽只记在 Elysia 自己这边（见 AlbumSettings），Apple Music 里的专辑名不变，
// 被屏蔽的专辑也只是从这一页收起来，歌曲仍在「歌曲」页。
struct AlbumsView: View {
    /// 全部专辑（含被屏蔽的），名字已按用户的改动显示
    let albums: [Album]
    /// 被屏蔽的专辑 id
    let hiddenIDs: Set<String>
    /// 侧边栏搜索框的文字
    let searchText: String
    /// 双击专辑：进入它
    let onOpen: (Album) -> Void
    /// 确认改名：带回每张专辑的 id、原名与新名字
    let onRename: ([(id: String, original: String, name: String)]) -> Void
    let onHide: ([String]) -> Void
    let onRestore: ([String]) -> Void
    let onRestoreAll: () -> Void

    /// 浏览时高亮的那一行
    @State private var highlighted: String? = nil
    /// 选择模式下勾选的专辑
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    /// 是否正在看「屏蔽的专辑」
    @State private var showingHidden = false
    /// 正在改名的专辑（空数组表示不显示改名窗口）
    @State private var renaming: [Album] = []

    private var visibleAlbums: [Album] {
        AlbumLibrary.filter(albums.filter { !hiddenIDs.contains($0.id) }, query: searchText)
    }

    private var hiddenAlbums: [Album] {
        AlbumLibrary.filter(albums.filter { hiddenIDs.contains($0.id) }, query: searchText)
    }

    private var listedAlbums: [Album] { showingHidden ? hiddenAlbums : visibleAlbums }
    private var selectedAlbums: [Album] { listedAlbums.filter { selection.contains($0.id) } }
    private var isSearching: Bool { SongSearch.isActive(searchText) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onChange(of: showingHidden) { _ in endSelecting() }
        .sheet(isPresented: isRenaming) {
            AlbumRenameSheet(albums: renaming) { changes in
                renaming = []
                onRename(changes)
            } onCancel: {
                renaming = []
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { !renaming.isEmpty }, set: { if !$0 { renaming = [] } })
    }

    // MARK: 顶部工具条

    private var toolbar: some View {
        HStack(spacing: 0) {
            if isSelecting {
                Text(String(format: countFormat("albums.selectedCount"), selection.count))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if showingHidden {
                if isSelecting {
                    button("albums.restoreSelected", shortcut: "⌘R", color: .blue) {
                        guard !selection.isEmpty else { return }
                        onRestore(Array(selection))
                        endSelecting()
                    }
                } else {
                    button("albums.restoreAll", shortcut: nil, color: .blue) {
                        onRestoreAll()
                    }
                }
                spacerCharacter()
                button(isSelecting ? "albums.select.done" : "albums.select", shortcut: "⌘B", color: .blue) {
                    toggleSelecting()
                }
                spacerCharacter()
                button("albums.back", shortcut: nil, color: .blue) {
                    showingHidden = false
                }
            } else {
                if isSelecting {
                    button("albums.rename", shortcut: "⌘R", color: .blue) {
                        guard !selection.isEmpty else { return }
                        renaming = selectedAlbums
                    }
                    spacerCharacter()
                    button("albums.hide", shortcut: "⌘⌫", color: .red) {
                        guard !selection.isEmpty else { return }
                        onHide(Array(selection))
                        endSelecting()
                    }
                    spacerCharacter()
                }
                button(isSelecting ? "albums.select.done" : "albums.select", shortcut: "⌘B", color: .blue) {
                    toggleSelecting()
                }
                spacerCharacter()
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

    /// 「屏蔽的专辑」：有被屏蔽的专辑时带上数量，一眼知道里面有没有东西
    private var hiddenEntryTitle: String {
        guard !hiddenIDs.isEmpty else {
            return Bundle.main.localizedString(forKey: "albums.hidden", value: nil, table: nil)
        }
        return String(format: countFormat("albums.hiddenCount"), hiddenIDs.count)
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
        .modifier(OptionalShortcut(shortcut: shortcut))
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
        if listedAlbums.isEmpty {
            emptyState
        } else if isSelecting {
            List {
                ForEach(listedAlbums) { album in
                    AlbumPickRow(
                        album: album,
                        isSelected: selection.contains(album.id),
                        onToggle: { toggle(album.id) }
                    )
                }
            }
            .listStyle(.plain)
        } else {
            List(selection: $highlighted) {
                ForEach(listedAlbums) { album in
                    AlbumRow(
                        album: album,
                        onOpen: {
                            highlighted = album.id
                            if showingHidden {
                                Diagnostics.log("恢复专辑《\(album.title)》")
                                onRestore([album.id])
                            } else {
                                Diagnostics.log("进入专辑《\(album.title)》\(album.artist)，\(album.songs.count) 首")
                                onOpen(album)
                            }
                        },
                        onSelect: { highlighted = album.id }
                    )
                    .tag(album.id)
                    .contextMenu {
                        if showingHidden {
                            Button("albums.restore") {
                                Diagnostics.log("恢复专辑《\(album.title)》")
                                onRestore([album.id])
                            }
                        } else {
                            Button("albums.rename") { renaming = [album] }
                            Divider()
                            Button("albums.hide", role: .destructive) {
                                Diagnostics.log("屏蔽专辑《\(album.title)》")
                                onHide([album.id])
                            }
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

    private var emptyIcon: String {
        if isSearching { return "magnifyingglass" }
        if allHidden { return "eye.slash" }
        return showingHidden ? "eye.slash" : "square.stack"
    }

    /// 可见的专辑全被屏蔽了：空状态要说清楚去哪里找回来，而不是「还没有专辑」
    private var allHidden: Bool {
        !showingHidden && !isSearching && visibleAlbums.isEmpty && !hiddenIDs.isEmpty
    }

    private var emptyTitle: LocalizedStringKey {
        if isSearching { return "albums.noMatch.title" }
        if allHidden { return "albums.allHidden.title" }
        return showingHidden ? "albums.hidden.empty.title" : "albums.empty.title"
    }

    private var emptyHint: LocalizedStringKey {
        if isSearching { return "albums.noMatch.hint" }
        if allHidden { return "albums.allHidden.hint" }
        return showingHidden ? "albums.hidden.empty.hint" : "albums.empty.hint"
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func countFormat(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// 快捷键可有可无：没有时用空键位，等于不占用任何按键
///
/// `keyboardShortcut` 不接受 nil，所以只能整个修饰符按需挂上；用空键位会与 Escape
/// 冲突，宁可什么都不挂。
private struct OptionalShortcut: ViewModifier {
    let shortcut: String?

    func body(content: Content) -> some View {
        switch shortcut {
        case "⌘R":
            content.keyboardShortcut("r", modifiers: .command)
        case "⌘B":
            content.keyboardShortcut("b", modifiers: .command)
        case "⌘⌫":
            content.keyboardShortcut(.delete, modifiers: .command)
        default:
            content
        }
    }
}

// MARK: - 专辑行
//
// 与歌单行同一套样式（封面 + 名称 + 副标题），两个页面看起来是一家人。
// 封面只取屏幕上看得见的那些：一次取一张要走一趟 AppleScript，一次取一百多张会很慢。
private struct AlbumRow: View {
    let album: Album
    let onOpen: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtwork(album: album)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                AlbumSubtitle(album: album)
            }

            Spacer(minLength: 0)

            // 与歌单行一致：点箭头进入，双击整行也能进入
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("albums.open")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // List 自己的选中判定会和双击手势抢同一次单击，用同时手势自己处理单击，
        // 选中才稳定——这与歌单行踩过的坑是同一个。
        .onTapGesture(count: 2) { onOpen() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
    }
}

/// 选择模式下的专辑行：同一份内容 + 行尾的选中标记
private struct AlbumPickRow: View {
    let album: Album
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtwork(album: album)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                AlbumSubtitle(album: album)
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
}

/// 专辑封面：取第一首的封面，没有时显示灰底
struct AlbumArtwork: View {
    let album: Album

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
        .task(id: album.songs.first?.id) {
            guard let first = album.songs.first else {
                artworkImage = nil
                return
            }
            artworkImage = await MusicData.fetchArtwork(persistentID: first.id)
        }
    }
}

private struct AlbumSubtitle: View {
    let album: Album

    var body: some View {
        HStack(spacing: 4) {
            Text(album.artist)
                .lineLimit(1)
                .truncationMode(.tail)
            if !album.artist.isEmpty {
                Text("·")
            }
            Text(songCountText(album.songs.count))
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

/// 「N 首」的本地化文案
private func songCountText(_ count: Int) -> String {
    let format = Bundle.main.localizedString(forKey: "albums.songCount", value: nil, table: nil)
    return String(format: format, count)
}
