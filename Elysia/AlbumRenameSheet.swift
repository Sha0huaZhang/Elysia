import SwiftUI

// MARK: - 专辑改名窗口
//
// 单张与批量共用这一个窗口：选中几张就列几行，每行一张专辑的封面与名字输入框，
// 输入框里先填好当前的名字，改哪张就改哪张，留空或保持原名都不会写入覆盖。
// 风格与「新建歌单」的选歌窗口一致：红字取消、蓝字确认，快捷键相同。
struct AlbumRenameSheet: View {
    let albums: [Album]
    let onConfirm: ([(id: String, original: String, name: String)]) -> Void
    let onCancel: () -> Void

    @State private var names: [String: String]

    init(
        albums: [Album],
        onConfirm: @escaping ([(id: String, original: String, name: String)]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.albums = albums
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _names = State(initialValue: Dictionary(albums.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
    }

    private var hasEmptyName: Bool {
        albums.contains { name(for: $0).isEmpty }
    }

    private var changedCount: Int {
        albums.filter { name(for: $0) != $0.title }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("albums.rename.title")
                .font(.headline)
            Text("albums.rename.hint")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var list: some View {
        List(albums) { album in
            HStack(spacing: 12) {
                AlbumArtwork(album: album)

                VStack(alignment: .leading, spacing: 2) {
                    TextField("albums.rename.placeholder", text: binding(for: album))
                        .textFieldStyle(.roundedBorder)
                        // 与歌单名同一条上限：粘贴超长文本只保留上限内的内容，
                        // 否则主线程要先排一次几万字符的文字
                        .onChange(of: names[album.id] ?? "") { newValue in
                            if newValue.count > LibraryLimits.albumName {
                                names[album.id] = String(newValue.prefix(LibraryLimits.albumName))
                            }
                        }
                    // 已经改过名的专辑：把 Apple Music 里的原名也列出来，方便对照
                    if album.title != album.originalTitle {
                        Text(album.originalTitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(format: countFormat("albums.rename.changed"), changedCount))
                .font(.callout)
                .foregroundColor(.secondary)

            if hasEmptyName {
                Text("albums.rename.required")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Text("common.cancel").foregroundColor(.red)
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
    }

    private func binding(for album: Album) -> Binding<String> {
        Binding(
            get: { names[album.id] ?? album.title },
            set: { names[album.id] = $0 }
        )
    }

    private func name(for album: Album) -> String {
        LibraryLimits.normalized(names[album.id] ?? album.title, limit: LibraryLimits.albumName)
    }

    private func confirm() {
        guard !hasEmptyName else { return }
        let changes = albums.map { album in
            (id: album.id, original: album.originalTitle, name: name(for: album))
        }
        Diagnostics.log("重命名专辑 \(changes.map { "《\($0.name)》" }.joined(separator: "、"))")
        onConfirm(changes)
    }

    private func countFormat(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}
