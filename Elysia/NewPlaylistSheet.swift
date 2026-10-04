import SwiftUI
import AppKit

// MARK: - 新建歌单
//
// 挑歌 + 起名。歌单只存进 Elysia 内部，这里不会写入 Apple Music。
struct NewPlaylistSheet: View {
    let songs: [Song]
    /// 该名字是否已被占用（同名歌单不允许再建）
    let nameExists: (String) -> Bool
    /// 确认：带回名字与选中的曲目（按它们在歌曲列表里的先后）
    let onConfirm: (String, [String]) -> Void
    let onCancel: () -> Void

    /// 默认名字，直接可改
    @State private var name = "UTF-8"
    @State private var query = ""
    @State private var selected: Set<String> = []

    private var visibleSongs: [Song] { SongSearch.filter(songs, query: query) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { !trimmedName.isEmpty && nameExists(trimmedName) }
    private var canConfirm: Bool { !trimmedName.isEmpty && !isDuplicate }

    /// 选中曲目的顺序一律按它们在歌曲列表里的先后，与点击次序无关，
    /// 这样同一个歌单每次建出来顺序都一样，可预期。
    private var orderedSelection: [String] {
        songs.filter { selected.contains($0.id) }.map(\.id)
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
            Text("playlists.new.title")
                .font(.headline)

            HStack(spacing: 8) {
                Text("playlists.name.label")
                    .foregroundColor(.secondary)
                TextField("playlists.name.placeholder", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if isDuplicate {
                Text("playlists.duplicate")
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
                    onToggle: { toggle(song.id) }
                )
            }
            .listStyle(.plain)
        }
    }

    // MARK: 底部：已选数量 + 取消 / 确认
    private var footer: some View {
        HStack(spacing: 12) {
            Text(selectedCountText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onCancel) {
                Text("common.cancel")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: confirm) {
                HStack(spacing: 4) {
                    Text("playlists.confirm")
                    Text("⌘Enter").foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
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

    private func confirm() {
        guard canConfirm else { return }
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

            Image(systemName: isSelected ? "circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .red : .secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private func loadArtwork() async {
        guard artworkImage == nil else { return }
        let image = await MusicData.fetchArtwork(persistentID: song.id)
        await MainActor.run { self.artworkImage = image }
    }
}
