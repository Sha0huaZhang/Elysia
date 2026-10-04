import SwiftUI

// MARK: - 尚未实现的栏目
struct ComingSoonView: View {
    let item: SidebarItem

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.title3)
            Text("comingSoon.message")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
