import SwiftUI

// MARK: - 歌单
//
// 歌单只存在于 Elysia 内部，不写入 Apple Music。这里先做「新建 / 删除」与列表；
// 播放歌单（按歌单顺序逐个申请播放）留待后续。
struct PlaylistsView: View {
    /// 资料库全部曲目，供新建歌单时挑选
    let songs: [Song]
    /// 双击某个歌单：进入它（由上层切换到歌单详情页）
    let onOpen: (Playlist) -> Void

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
                    PlaylistRow(
                        playlist: playlist,
                        songs: resolvedSongs(playlist),
                        onOpen: {
                            selection = playlist.id
                            Diagnostics.log("进入歌单《\(playlist.name)》")
                            onOpen(playlist)
                        }
                    )
                    .tag(playlist.id)
                }
            }
            .listStyle(.plain)
        }
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

    private var deleteMessage: String {
        let format = Bundle.main.localizedString(
            forKey: "playlists.delete.confirm.message", value: nil, table: nil
        )
        return String(format: format, selectedPlaylist?.name ?? "")
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

// MARK: - 歌单行
//
// 与歌曲行同一套样式：左侧封面取歌单第一首的封面，右边第一行歌单名、第二行歌曲数
// （对应歌曲行里歌名与艺人的位置）。双击进入歌单，进入后与「歌曲」页完全一致。
private struct PlaylistRow: View {
    let playlist: Playlist
    /// 已与资料库对上的曲目（对不上的已丢掉），封面与数量都按这个算
    let songs: [Song]
    let onOpen: () -> Void

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

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .task(id: songs.first?.id) { await loadArtwork() }
        .onTapGesture(count: 2) { onOpen() }
    }

    private func songCountText(_ count: Int) -> String {
        let format = Bundle.main.localizedString(
            forKey: "playlists.songCount", value: nil, table: nil
        )
        return String(format: format, count)
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
