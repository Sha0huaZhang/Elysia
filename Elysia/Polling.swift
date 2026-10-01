import Foundation

// MARK: - 轮询节奏
//
// 循环模式（单曲 / 列表）已交给 Apple Music 原生执行，Elysia 不再于曲末接管，因此这里
// 只需要决定轮询间隔。进度条刷新与状态跟随都靠它。
//
// 之所以不再接管：接管必须盯住曲末并在 Music 自己走歌之前抢先下手，而 Music 的曲末行为
// 会让每次读到的「当前曲目」在几首之间抖动，抢时间必然产生竞态。交给 Music 后，Elysia
// 只在用户切换模式时下发一次，全程没有与 Music 争抢的动作。
enum Polling {
    /// 常规轮询间隔，同时决定进度条刷新频率。
    static let interval: TimeInterval = 0.5

    /// 把秒数换成纳秒，供 Task.sleep 使用（并防止出现非正值）。
    static func sleepNanoseconds(_ seconds: TimeInterval = interval) -> UInt64 {
        UInt64(max(0.05, seconds) * 1_000_000_000)
    }
}
