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
        log("===== 启动 \(AppVersion.display) =====")
    }

    /// 列表清单文件位置
    static var listURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Elysia-list.txt")
    }

    /// 把当前列表按位置写成清单。
    ///
    /// 位置就是 Apple Music 资料库中的位置，界面上显示的编号与日志里的「第 N 位」都用它，
    /// 因此不必再用眼睛数界面上是第几行；也便于事后核对 Elysia 的顺序与 Apple Music 的
    /// 顺序差在哪一首。每次读取资料库（启动、切回应用、手动刷新）都会重写一次。
    static func dumpList(_ songs: [Song]) {
        var text = "# Elysia 列表清单　共 \(songs.count) 首\n"
        text += "# 位置就是 Apple Music 资料库中的位置\n"
        text += "# 位置\t歌名\t歌手\tpersistent ID\n"
        for song in songs {
            let position = song.libraryPosition > 0 ? String(song.libraryPosition) : "未知"
            text += "\(position)\t\(song.title)\t\(song.artist)\t\(song.id)\n"
        }
        queue.async {
            try? text.data(using: .utf8)?.write(to: listURL)
        }
    }
}
