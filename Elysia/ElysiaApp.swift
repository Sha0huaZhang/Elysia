import SwiftUI

@main
struct ElysiaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // 紧凑标题栏：缩小「Elysia」这行标题的上下边距
        .windowToolbarStyle(.unifiedCompact)
    }
}
