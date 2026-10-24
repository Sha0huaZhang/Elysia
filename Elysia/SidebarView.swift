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
    case artists
    case start
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .settings:  return "sidebar.settings"
        case .songs:     return "sidebar.songs"
        case .playlists: return "sidebar.playlists"
        case .albums:    return "sidebar.albums"
        case .artists:   return "sidebar.artists"
        case .start:     return "sidebar.start"
        case .about:     return "sidebar.about"
        }
    }

    var systemImage: String {
        switch self {
        case .settings:  return "gearshape"
        case .songs:     return "music.note"
        case .playlists: return "music.note.list"
        case .albums:    return "square.stack"
        case .artists:   return "music.mic"
        case .start:     return "play.circle"
        case .about:     return "info.circle"
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

    private var searchPlaceholder: LocalizedStringKey {
        switch selection {
        case .albums:  return "search.placeholder.albums"
        case .artists: return "search.placeholder.artists"
        default:       return "search.placeholder"
        }
    }

    /// 列表上方的搜索框
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // 提示随栏目变：专辑页搜的是专辑名与歌手，不是歌曲
            TextField(searchPlaceholder, text: $searchText)
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
