import SwiftUI

// MARK: - 歌单
//
// 歌单只存在于 Elysia 内部，不写入 Apple Music。这里先做「新建 / 删除」与列表；
// 播放歌单（按歌单顺序逐个申请播放）留待后续。
struct PlaylistsView: View {
    /// 资料库全部曲目，供新建歌单时挑选
    let songs: [Song]

    private let store = PlaylistStore()

    @State private var playlists: [Playlist] = []
    @State private var selection: UUID? = nil
    @State private var isCreating = false
    @State private var isConfirmingDelete = false

    private var selectedPlaylist: Playlist? {
        guard let selection else { return nil }
        return playlists.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear { reload() }
        .sheet(isPresented: $isCreating) {
            NewPlaylistSheet(
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
        .confirmationDialog(
            "playlists.delete.confirm.title",
            isPresented: $isConfirmingDelete
        ) {
            Button("playlists.delete", role: .destructive) { deleteSelected() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
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
                    Text("playlists.new")
                    Text("⌘N").foregroundColor(.secondary)
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
    }

    private func requestDelete() {
        guard selectedPlaylist != nil else {
            Diagnostics.log("未选中歌单，删除已忽略")
            return
        }
        isConfirmingDelete = true
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
                    HStack(spacing: 8) {
                        Text(playlist.name)
                        Spacer()
                        Text(songCountText(playlist.songIDs.count))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .tag(playlist.id)
                }
            }
            .listStyle(.plain)
        }
    }

    private var deleteMessage: String {
        let format = Bundle.main.localizedString(
            forKey: "playlists.delete.confirm.message", value: nil, table: nil
        )
        return String(format: format, selectedPlaylist?.name ?? "")
    }

    private func songCountText(_ count: Int) -> String {
        let format = Bundle.main.localizedString(
            forKey: "playlists.songCount", value: nil, table: nil
        )
        return String(format: format, count)
    }

    private func reload() {
        playlists = store.all
    }

    private func deleteSelected() {
        guard let target = selectedPlaylist else { return }
        store.delete(id: target.id)
        Diagnostics.log("删除歌单《\(target.name)》")
        reload()
        selection = nil
    }
}
