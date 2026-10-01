import Foundation

// MARK: - 诊断日志
//
// 写到 ~/Library/Logs/Elysia.log。
//
// 用途：像「下一首跳错」这类只在真实运行中出现、且看不出规律的问题，靠推理定位会反复
// 猜错。日志把 Elysia 的每一步决定（锚点是谁、算出哪一首）与它随后观察到的实际播放
// 曲目并排记下来，分歧点一眼可见。
//
// 开销很小（后台串行写文件），保留在发布版里也能用于用户报障。
enum Diagnostics {
    private static let queue = DispatchQueue(label: "org.macwave.elysia.diagnostics")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 日志文件位置；同时供「显示日志」功能使用
    static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Elysia.log")
    }

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let url = fileURL
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 起一个新会话，用横线隔开，便于定位本次复现
    static func markSession() {
        log("")
        log("===== 启动 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") =====")
    }
}
