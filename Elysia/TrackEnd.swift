import Foundation

// MARK: - 曲目结束时接管
//
// 循环模式（单曲 / 列表）由 Elysia 自己实现：它保存着自己的歌单顺序，曲目快结束时
// 主动申请下一首，不使用 Apple Music 的 `song repeat`，这样播放顺序始终与 Elysia 的
// 列表（含用户拖拽后的顺序）一致。
//
// 关键设计：**不在轮询里解读「剩余时间」**，而是在曲目开始时就算出一个截止时刻，到点
// 触发一次。
//
// 为什么必须这样。Apple Music 会在曲末自己顺着列表往下走，而轮询是滞后的：
//   * 按下「下一首」后 Music 尚未切过去，这一轮读到的还是旧歌的曲末进度；
//   * 拖动进度条后 Music 的跳转脚本可能还没执行，读到的也是旧进度。
// 两种情况都会让「剩余时间≈0」被误判成曲终，于是以旧歌为锚点再算一次下一首，与刚才
// 申请的目标互相打架——谁后执行就播谁，现象就是「跳错歌且找不出规律」。
// 改用截止时刻后，这些滞后数据完全不参与判断，那一类问题在结构上不再可能发生。
//
// 纯函数部分，便于在没有 Apple Music 的情况下验证。
enum TrackEnd {
    /// 提前多久接管。留出余量覆盖 AppleScript 往返延迟。
    static let lead: TimeInterval = 0.15

    /// 距截止时刻还超过这个值时，就按常规间隔轮询。
    static let calmWindow: TimeInterval = 3.0

    /// 常规轮询间隔，同时决定进度条刷新频率。
    static let base: TimeInterval = 0.5

    /// 临近截止时刻的最小睡眠，避免空转。
    static let minimum: TimeInterval = 0.05

    /// 曲目开始（或跳转）后，算出应当接管下一首的时刻。
    ///
    /// - Parameters:
    ///   - duration: 曲目总长；未知或非正数时返回 nil（不排定，避免误触发）。
    ///   - position: 当前进度。
    /// - Returns: 截止时刻；剩余时间已不足 lead 时返回 nil，交给下一轮重新排定。
    static func deadline(
        duration: Double,
        position: Double,
        now: Date = Date()
    ) -> Date? {
        guard duration > 0 else { return nil }
        let remaining = duration - position
        guard remaining > lead else { return nil }
        return now.addingTimeInterval(remaining - lead)
    }

    /// 下一次轮询该等多久：临近截止时刻就贴着它醒，避免 0.5 秒的间隔错过只有零点几秒的窗口。
    ///
    /// - Parameter fetchSeconds: 上次读取状态花掉的往返时间，从睡眠里扣掉。
    static func sleepInterval(
        until deadline: Date?,
        now: Date = Date(),
        fetchSeconds: TimeInterval = 0
    ) -> TimeInterval {
        guard let deadline else { return base }
        let delta = deadline.timeIntervalSince(now)
        guard delta <= calmWindow else { return base }
        return min(base, max(minimum, delta - fetchSeconds))
    }

    /// 是否已到接管时刻。
    static func isDue(deadline: Date?, now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }
}
