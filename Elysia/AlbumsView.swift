import SwiftUI
import AppKit

// MARK: - 专辑
//
// 专辑来自 Apple Music 的资料库：Elysia 只读取，不写入，也不改动资料库里的任何内容。
// 这里只负责把专辑列出来，点进去后用与「歌曲」「歌单」相同的控制条与歌曲列表播放。
struct AlbumsView: View {
    /// 资料库全部曲目，专辑由它归并出来
    let songs: [Song]
    /// 侧边栏搜索框的文字
    let searchText: String
    /// 双击专辑：进入它
    let onOpen: (Album) -> Void

    @State private var selection: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .onAppear { keepSelectionValid() }
        .onChange(of: songs.count) { _ in keepSelectionValid() }
    }

    private var albums: [Album] { AlbumLibrary.albums(from: songs) }
    private var visibleAlbums: [Album] { AlbumLibrary.filter(albums, query: searchText) }
    private var isSearching: Bool { SongSearch.isActive(searchText) }

    @ViewBuilder
    private var content: some View {
        if visibleAlbums.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: isSearching ? "magnifyingglass" : "square.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(isSearching ? "albums.noMatch.title" : "albums.empty.title")
                    .foregroundColor(.secondary)
                Text(isSearching ? "albums.noMatch.hint" : "albums.empty.hint")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(visibleAlbums) { album in
                    AlbumRow(
                        album: album,
                        onOpen: {
                            selection = album.id
                            Diagnostics.log("进入专辑《\(album.title)》\(album.artist)，\(album.songs.count) 首")
                            onOpen(album)
                        },
                        onSelect: { selection = album.id }
                    )
                    .tag(album.id)
                }
            }
            .listStyle(.plain)
        }
    }

    /// 资料库刷新后，原来选中的专辑可能已经不在了
    private func keepSelectionValid() {
        guard let selection else { return }
        if !albums.contains(where: { $0.id == selection }) {
            self.selection = nil
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
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .task(id: album.songs.first?.id) {
            guard let first = album.songs.first else {
                artworkImage = nil
                return
            }
            artworkImage = await MusicData.fetchArtwork(persistentID: first.id)
        }
    }
}

/// 「N 首」的本地化文案
private func songCountText(_ count: Int) -> String {
    let format = Bundle.main.localizedString(forKey: "albums.songCount", value: nil, table: nil)
    return String(format: format, count)
}
