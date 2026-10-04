import SwiftUI

@main
struct ElysiaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Elysia 是单窗口工具，去掉「新建窗口」菜单项，把 ⌘N 空出来给「新建歌单」
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        // 紧凑标题栏：缩小「Elysia」这行标题的上下边距
        .windowToolbarStyle(.unifiedCompact)
    }
}
