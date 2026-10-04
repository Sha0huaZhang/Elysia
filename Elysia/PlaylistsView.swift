import SwiftUI

// MARK: - 歌单
//
// 歌单只存在于 Elysia 内部，不写入 Apple Music。
struct PlaylistsView: View {
    /// 资料库全部曲目，供新建/编辑歌单时挑选
    let songs: [Song]
    /// 双击某个歌单：进入它（由上层切换到歌单详情页）
    let onOpen: (Playlist) -> Void

    private let store = PlaylistStore()

    @State private var playlists: [Playlist] = []
    @State private var selection: UUID? = nil
    @State private var isCreating = false
    /// 正在编辑曲目的歌单
    @State private var editing: Playlist? = nil
    /// 正在重命名的歌单，以及输入框里的文字
    @State private var renaming: Playlist? = nil
    @State private var renameText = ""
    /// 待确认删除的歌单。删除一律先经这一步，不直接删。
    @State private var pendingDelete: Playlist? = nil
    /// 没有选中项时，改为从列表里挑一个要删的歌单
    @State private var isChoosingDelete = false
    /// 挑选窗口里选中的歌单；确认后交给 pendingDelete，走同一个二次确认
    @State private var pickerSelection: UUID? = nil
    @State private var chosenForDelete: Playlist? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear { reload() }
        .sheet(isPresented: $isCreating) { createSheet }
        .sheet(item: $editing) { playlist in editSheet(playlist) }
        .alert(renameTitle, isPresented: isRenaming) {
            TextField("playlists.name.placeholder", text: $renameText)
            Button("common.cancel", role: .cancel) { renaming = nil }
            Button("playlists.confirm") { commitRename() }
        } message: {
            renameMessage
        }
        // 挑选窗口关闭后再交给二次确认：同一个循环里接连弹出两层弹窗，SwiftUI 会漏掉一层
        .sheet(isPresented: $isChoosingDelete, onDismiss: {
            if let chosen = chosenForDelete {
                chosenForDelete = nil
                pendingDelete = chosen
            }
        }) {
            deletePickerSheet
        }
        .confirmationDialog(
            "playlists.delete.confirm.title",
            isPresented: isConfirmingDelete,
            presenting: pendingDelete
        ) { playlist in
            Button("playlists.delete", role: .destructive) { delete(playlist) }
            Button("common.cancel", role: .cancel) { pendingDelete = nil }
        } message: { playlist in
            Text(deleteMessage(for: playlist))
        }
    }

    /// 选中歌单后可用的快捷键。
    ///
    /// 与 ⌘D 一致：没有选中时什么都不做。这些操作都要有明确的目标，不能替用户猜是哪一个。
    ///
    /// 两个必须注意的地方：
    /// 1. `allowsHitTesting(false)`——`.opacity(0)` 只是看不见，并不影响命中测试，
    ///    而 `.frame(width: 0, height: 0)` 也不会裁剪，按钮仍会以自身尺寸叠在内容上，
    ///    把底下的单击吃掉（曾经因此让歌单列表整片点不动）。加了这个才真的不挡点击。
    /// 2. 挂在工具栏这条窄带上，而不是整个页面：即使哪里没挡住，也只覆盖这条空白区域。
    private var selectionShortcuts: some View {
        Group {
            Button { runOnSelection(action: "编辑", startEditing) } label: { EmptyView() }
                .keyboardShortcut("e", modifiers: .command)
            Button { runOnSelection(action: "重命名", startRenaming) } label: { EmptyView() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func runOnSelection(action: String, _ perform: (Playlist) -> Void) {
        guard let target = selectedPlaylist else {
            Diagnostics.log("未选中歌单，\(action)已忽略")
            return
        }
        perform(target)
    }

    // MARK: 顶部右上角：新建（靠前） / 删除（靠后），两者相隔一个文字
    //
    // 不用 .disabled：禁用态会把红色一起调暗，看起来是灰的。删除按钮始终是正常的红色，
    // 没选中歌单时点按只是什么都不做（并记一条日志）。
    private var toolbar: some View {
        HStack(spacing: 0) {
            Spacer()

            Button(action: { isCreating = true }) {
                HStack(spacing: 4) {
                    Text("playlists.new").foregroundColor(.blue)
                    // 快捷键用更柔和的蓝，不与歌单名抢眼
                    Text("⌘N").foregroundColor(Color.blue.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)

            // 一个文字的宽度
            Text("字").font(.body).hidden()

            Button(action: requestDelete) {
                HStack(spacing: 4) {
                    Text("playlists.delete")
                    Text("⌘D")
                }
                .foregroundColor(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(selectionShortcuts)
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func requestDelete() {
        if let target = selectedPlaylist {
            Diagnostics.log("请求删除歌单《\(target.name)》")
            pendingDelete = target
            return
        }
        // 没有选中项时不能替用户挑一个（删除是危险操作），也不能按了没反应。
        // 改成弹出列表让他自己明确选一个，再走同一个二次确认。
        pickerSelection = nil
        Diagnostics.log("未选中歌单，改为从列表中选择要删除的")
        isChoosingDelete = true
    }

    /// 没有选中项时用来挑选要删除的歌单。
    ///
    /// 这里的行没有单击/双击手势，因此 List 的原生选中是可靠的：单击即可选中。
    private var deletePickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("playlists.delete.pick")
                    .font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            if playlists.isEmpty {
                Text("playlists.empty.title")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(playlists, selection: $pickerSelection) { playlist in
                    PlaylistPickRow(
                        playlist: playlist,
                        songs: resolvedSongs(playlist),
                        isSelected: pickerSelection == playlist.id
                    )
                    .tag(playlist.id)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 12) {
                if pickerSelection == nil {
                    Text("playlists.delete.pickHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isChoosingDelete = false
                } label: {
                    HStack(spacing: 4) {
                        Text("common.cancel").foregroundColor(.red)
                        Text("Esc").foregroundColor(Color.red.opacity(0.55))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(Color.red, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: chooseForDelete) {
                    HStack(spacing: 4) {
                        Text("playlists.delete").foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(pickerSelection == nil ? Color.red.opacity(0.35) : Color.red)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .frame(width: 420, height: 420)
    }

    private func chooseForDelete() {
        guard let id = pickerSelection, let target = playlists.first(where: { $0.id == id }) else { return }
        Diagnostics.log("从列表中选择删除《\(target.name)》")
        chosenForDelete = target
        isChoosingDelete = false
    }

    @ViewBuilder
    private var content: some View {
        if playlists.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("playlists.empty.title").foregroundColor(.secondary)
                Text("playlists.empty.hint")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(playlists) { playlist in
                    PlaylistRow(
                        playlist: playlist,
                        songs: resolvedSongs(playlist),
                        onOpen: {
                            selection = playlist.id
                            Diagnostics.log("进入歌单《\(playlist.name)》")
                            onOpen(playlist)
                        },
                        onSelect: {
                            selection = playlist.id
                        }
                    )
                    .tag(playlist.id)
                    .contextMenu {
                        Button("playlists.editMenu") { startEditing(playlist) }
                            .keyboardShortcut("e", modifiers: .command)
                        Button("playlists.rename") { startRenaming(playlist) }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                        Divider()
                        // role: .destructive 让菜单项显示为红色
                        Button("playlists.delete", role: .destructive) {
                            // 先选中这一行，再进入确认；这样即便快捷键在菜单外被触发，
                            // 删除目标也与界面上被选中的那个一致，不会指向别处
                            selection = playlist.id
                            requestDelete()
                        }
                        .keyboardShortcut("d", modifiers: .command)
                    }
                }
                // 拖动调整歌单之间的先后。列表顺序就是存储顺序，拖完立即落盘。
                .onMove { offsets, destination in
                    let reordered = Playlist.moved(
                        playlists.map(\.id), fromOffsets: offsets, toOffset: destination
                    )
                    store.reorder(ids: reordered)
                    reload()
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: 弹窗

    private var createSheet: some View {
        PlaylistSheet(
            titleKey: "playlists.new.title",
            songs: songs,
            nameExists: { store.contains(name: $0) },
            onConfirm: { name, songIDs in
                if let created = store.create(name: name, songIDs: songIDs) {
                    Diagnostics.log("新建歌单《\(created.name)》，\(songIDs.count) 首")
                    reload()
                    selection = created.id
                }
                isCreating = false
            },
            onCancel: { isCreating = false }
        )
    }

    private func editSheet(_ playlist: Playlist) -> some View {
        PlaylistSheet(
            titleKey: "playlists.edit.title",
            songs: songs,
            initialName: playlist.name,
            initialOrder: playlist.songIDs,
            nameExists: { store.contains(name: $0, excluding: playlist.id) },
            onConfirm: { name, songIDs in
                editing = nil
                if let updated = store.update(id: playlist.id, name: name, songIDs: songIDs) {
                    Diagnostics.log("编辑歌单《\(updated.name)》，共 \(songIDs.count) 首")
                    reload()
                }
            },
            onCancel: { editing = nil }
        )
    }

    // MARK: 重命名

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private var renameTitle: LocalizedStringKey { "playlists.rename" }

    /// 在提示里说明为什么不能确认，而不是让「确认」按钮变灰——变灰会把颜色一起调暗。
    private var renameMessage: Text {
        if renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Text("playlists.name.required")
        }
        if let playlist = renaming, store.contains(name: renameText, excluding: playlist.id) {
            return Text("playlists.duplicate")
        }
        return Text("playlists.name.placeholder")
    }

    // MARK: 操作

    private func startEditing(_ playlist: Playlist) {
        selection = playlist.id
        editing = playlist
    }

    private func startRenaming(_ playlist: Playlist) {
        selection = playlist.id
        renameText = playlist.name
        renaming = playlist
    }

    private func commitRename() {
        guard let playlist = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !store.contains(name: name, excluding: playlist.id) else { return }
        if let updated = store.update(id: playlist.id, name: name, songIDs: playlist.songIDs) {
            Diagnostics.log("重命名歌单《\(playlist.name)》→《\(updated.name)》")
            reload()
        }
        renaming = nil
    }

    private var selectedPlaylist: Playlist? {
        guard let selection else { return nil }
        return playlists.first { $0.id == selection }
    }

    /// 歌单里能真正对上的曲目。
    ///
    /// 资料库里已经删掉的曲目、以及那个读不出属性的坏条目，在这里都会被丢掉：歌单只存
    /// ID，对不上就不显示。封面取第一首能对上的，歌曲数也按能对上的算。丢掉了几首会记进
    /// 日志，界面上不打扰。
    private func resolvedSongs(_ playlist: Playlist) -> [Song] {
        let resolved = playlist.resolvedSongs(in: Song.index(songs))
        if resolved.count != playlist.songIDs.count {
            Diagnostics.log("歌单《\(playlist.name)》有 \(playlist.songIDs.count - resolved.count) 首对不上资料库，已略过")
        }
        return resolved
    }

    private func deleteMessage(for playlist: Playlist) -> String {
        let format = Bundle.main.localizedString(
            forKey: "playlists.delete.confirm.message", value: nil, table: nil
        )
        return String(format: format, playlist.name)
    }

    private func reload() {
        playlists = store.all
        // 选中的歌单可能已经被删掉
        if let id = selection, !playlists.contains(where: { $0.id == id }) {
            selection = nil
        }
        // 刻意不默认选中第一行：删除是危险操作，必须先由用户明确选中要删的那个。
        // 替用户预选，等于让 ⌘D 在一个用户没指定过的目标上生效。
    }

    private func delete(_ playlist: Playlist) {
        store.delete(id: playlist.id)
        Diagnostics.log("删除歌单《\(playlist.name)》")
        pendingDelete = nil
        reload()
    }
}

// MARK: - 歌单行
//
// 主列表与挑选窗口共用同一份行内容（封面 + 名称 + 歌曲数），两处样式不会分叉；
// 区别只在行尾的标记，以及主列表需要单击/双击手势。
private struct PlaylistRowContent: View {
    let playlist: Playlist
    /// 已与资料库对上的曲目（对不上的已丢掉），封面与数量都按这个算
    let songs: [Song]

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

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                Text(songCountText(songs.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        // 封面跟着歌单第一首走：拖动排序或编辑曲目后第一首变了，这里会重新取封面
        .task(id: songs.first?.id) { await loadArtwork() }
    }

    private func loadArtwork() async {
        guard let first = songs.first else {
            await MainActor.run { artworkImage = nil }
            return
        }
        let image = await MusicData.fetchArtwork(persistentID: first.id)
        await MainActor.run { self.artworkImage = image }
    }
}

/// 主列表的歌单行：行内容 + 可点击的箭头，单击选中、双击进入。
private struct PlaylistRow: View {
    let playlist: Playlist
    let songs: [Song]
    let onOpen: () -> Void
    /// 单击：选中这一行
    let onSelect: () -> Void

    var body: some View {
        PlaylistRowContent(playlist: playlist, songs: songs)
            .overlay(alignment: .trailing) {
                // 也可以点箭头进入：不必只靠双击，双击的判定本来就有先后关系
                Button(action: onOpen) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("playlists.open")
            }
            .contentShape(Rectangle())
            // 单击与双击：List 自己的选中判定要和双击手势抢同一次单击，谁赢取决于时序，
            // 于是「有时能选中有时候选不中」。这里用同时手势自己处理单击，选中不再依赖
            // List 的内部判定；双击因此仍然可用。
            .onTapGesture(count: 2) { onOpen() }
            .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
    }
}

/// 挑选窗口的歌单行：同一份行内容 + 行尾圆点。
///
/// 这里刻意不挂任何手势：没有手势竞争，List 的原生选中就是可靠的，单击必中；
/// 主列表那个「时好时坏」的问题正是手势抢同一次单击造成的。
private struct PlaylistPickRow: View {
    let playlist: Playlist
    let songs: [Song]
    let isSelected: Bool

    var body: some View {
        PlaylistRowContent(playlist: playlist, songs: songs)
            .overlay(alignment: .trailing) {
                Image(systemName: isSelected ? "circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .red : .secondary)
            }
    }
}

/// 「N 首」的本地化文案。
///
/// 歌单行、挑选窗口都用这一份：措辞只在一处定义，两个地方不会各说各话。
private func songCountText(_ count: Int) -> String {
    let format = Bundle.main.localizedString(
        forKey: "playlists.songCount", value: nil, table: nil
    )
    return String(format: format, count)
}
