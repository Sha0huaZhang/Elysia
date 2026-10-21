import Foundation

// MARK: - 输入长度上限
//
// 上限是为了稳住界面，不是为了整齐。SwiftUI 在主线程排版文字，成本比字符串长度涨得
// 还快：往歌单名里粘贴约 4 万个字符，主线程就被排版占满，内存一路涨到几个 GB，窗口
// 直接「未响应」。同一个名字还会同时出现在歌单行、歌单详情标题和日志里，每处重绘都要
// 把它重新排一遍。
//
// 上限远高于真实名字需要的长度，并且按 Unicode 字素簇（Character）截断，
// emoji 与中文不会被切成半个。
enum LibraryLimits {
    static let playlistName = 100

    /// 去掉首尾空白，并截到最多 `limit` 个字符。
    static func normalized(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}
