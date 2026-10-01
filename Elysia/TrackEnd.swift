import Foundation

// MARK: - 曲目结束时接管
//
// 循环模式（单曲 / 列表）由 Elysia 自己实现：它保存着自己的歌单顺序，曲目一结束
// 就按这个顺序再申请播放下一首，不使用 Apple Music 的 `song repeat`，这样播放顺序
// 始终与 Elysia 的列表（含用户拖拽后的顺序）一致。
//
// 麻烦在于「曲目结束」怎么判断。不能用 `player state` 变成 stopped 来判断：从资料库
// 直接播放一首歌之后，Music 会自己顺着资料库继续往下播，状态一直是 playing，直到
// 整个资料库播完才会 stopped。所以这里改成盯住播放进度，在曲目结束前主动接管。
//
// 纯函数，便于在没有 Apple Music 的情况下验证。
enum TrackEnd {
    /// 提前多久接管。留出余量覆盖 AppleScript 往返延迟，取小了会来不及（Music 已经
    /// 自己播到下一首，才被我们纠正回来，会听到一小段错歌）。
    static let lead: TimeInterval = 0.12

    /// 同一首的两次接管之间至少间隔这么久，兼作申请失败后的重试间隔。
    static let retryCooldown: TimeInterval = 2.0

    /// 剩余时间大于此值就按常规间隔轮询，进入这个范围才开始加密。
    static let calmWindow: TimeInterval = 3.0

    /// 常规轮询间隔，同时决定进度条刷新的频率。
    static let base: TimeInterval = 0.5

    /// 加密后的最小间隔，避免空转。
    static let minimum: TimeInterval = 0.05

    /// 是否应当立刻接管、申请下一首。
    ///
    /// - Parameters:
    ///   - remaining: 当前曲目剩余秒数；时长未知时为 nil。
    ///   - isPlaying: 是否正在播放。暂停时不能接管，否则会把暂停当成播完。
    ///   - secondsSinceTakeover: 距上次接管过了多久；从未接管过则为 nil。
    ///
    /// 用「距上次接管的秒数」而不是歌曲 ID 来防重复：单曲循环时曲目 ID 始终不变，
    /// 按 ID 记录会让循环只生效一次。冷却时间同时也是一道保险——万一某次申请没送到，
    /// 两秒后还会再试一次，不会就此卡在曲末不动。
    static func shouldTakeOver(
        remaining: TimeInterval?,
        isPlaying: Bool,
        secondsSinceTakeover: TimeInterval?
    ) -> Bool {
        guard isPlaying, let remaining else { return false }
        // 剩余时间为负说明已经播完（进度偶尔会略微超过时长），也应接管
        guard remaining <= lead else { return false }
        guard let since = secondsSinceTakeover else { return true }
        return since > retryCooldown
    }

    /// 下一次轮询该等多久。
    ///
    /// 接近曲末时按「剩余时间减掉 lead」来等，正好赶上接管点，既不会空转太多次，
    /// 也不会因为固定 0.5 秒的间隔而错过只有零点几秒的窗口。
    ///
    /// - Parameter fetchSeconds: 上一次读取状态花掉的往返时间。下一次拿到状态同样要花
    ///   这么久，从睡眠里扣掉，唤醒时刻才会落在接管点上，而不是每晚一个往返。
    static func pollInterval(
        remaining: TimeInterval?,
        isPlaying: Bool,
        fetchSeconds: TimeInterval = 0
    ) -> TimeInterval {
        guard isPlaying, let remaining, remaining <= calmWindow else { return base }
        let next = remaining - lead - fetchSeconds
        return min(base, max(minimum, next))
    }
}
