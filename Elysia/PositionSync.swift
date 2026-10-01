import Foundation

// MARK: - 播放进度同步
//
// 进度条只由轮询驱动，而轮询有间隔、Apple Music 切歌也要花时间，所以「刚点了
// 另一首歌」到「轮询报出新歌」之间，界面会一直显示上一首的进度。这里把这几种
// 情况分开处理，避免进度条不归零、甚至被旧值顶回去。
//
// 纯函数，便于验证各分支。
enum PositionSync {
    enum Outcome: Equatable {
        /// 正在拖动进度条，界面显示拖动值，轮询不插手
        case dragging
        /// 已请求换曲但 Music 还没跟上，进度先显示 0，不要显示上一首的进度
        case reset
        /// 采用轮询值，并丢弃已无意义的跳转目标
        case useReported(Double)
        /// 跳转目标还没被 Music 采纳，继续按目标值显示
        case keepPending(Double)
    }

    static let tolerance: Double = 1.0

    static func resolve(
        dragging: Bool,
        awaitingSwitch: Bool,
        trackChanged: Bool,
        pendingSeek: Double?,
        reported: Double,
        tolerance: Double = PositionSync.tolerance
    ) -> Outcome {
        if dragging { return .dragging }

        // 用户已点了别的歌，Music 尚未切过去。此刻轮询报的仍是上一首的进度，照用
        // 就会把进度条顶回旧位置，所以先显示 0。
        if awaitingSwitch { return .reset }

        // 曲目已变，上一首的跳转目标不再适用。必须丢弃，否则会一直按旧目标校正，
        // 新歌的进度条会永久停在旧位置——这正是「进度条不归零」的原因之一。
        guard let target = pendingSeek, !trackChanged else { return .useReported(reported) }

        if abs(reported - target) < tolerance { return .useReported(reported) }
        return .keepPending(target)
    }
}
