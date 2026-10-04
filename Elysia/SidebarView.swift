import SwiftUI

// MARK: - 侧边栏栏目
//
// 用稳定的枚举值作为选中标识，显示文字单独本地化，
// 这样切换语言不会影响选中状态与分支逻辑。
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case settings
    case songs
    case playlists
    case albums
    case start

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .settings:  return "sidebar.settings"
        case .songs:     return "sidebar.songs"
        case .playlists: return "sidebar.playlists"
        case .albums:    return "sidebar.albums"
        case .start:     return "sidebar.start"
        }
    }

    var systemImage: String {
        switch self {
        case .settings:  return "gearshape"
        case .songs:     return "music.note"
        case .playlists: return "music.note.list"
        case .albums:    return "square.stack"
        case .start:     return "play.circle"
        }
    }
}

// MARK: - 侧边栏
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
    }

    /// 列表上方的搜索框
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("search.placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { searchText = "" }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
