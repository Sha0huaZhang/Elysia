import Foundation

// MARK: - 曲目结束时由 Elysia 接管
//
// 循环（单曲 / 列表）由 Elysia 自己按它的歌单顺序实现，不依赖 Apple Music 的
// `song repeat`。原因是实测出来的：用 `play <track>` 播放指定曲目后，Music 的三种
// 循环模式全部失效——曲末它走的是自己的内部队列，与资料库顺序无关，也与 Elysia 的
// 顺序无关。实测记录（皆为 `play track` 启动后自然播到曲末）：
//
//     repeat=off ：#75《每段路》播完 -> #46《我只在乎你》（不是 #76）
//     repeat=one ：#75《每段路》播完 -> #45《偿还》      （不是重复自己）
//     repeat=all ：#128 播完         -> #46《我和你》    （不是回到 #1）
//
// 因此 Elysia 需要自己处理曲末。做法是在曲目开始时算出截止时刻，比 Music 的队列推进
// 早一点动手（实测：提前申请完全有效，不会被队列抢走）。
//
// 三种模式的处理方式不同：
//   * 单曲循环：把播放头绕回开头。同一首继续播，Music 永远到不了曲末，因此连申请都
//     不需要，**结构性无竞态**（已实测：repeat=off 下绕回后同一首继续）。
//   * 列表循环 / 不循环：提前申请 Elysia 顺序中的下一首（已实测：能稳稳停在目标曲目）。
enum TrackEnd {
    /// 提前多久动手。需要盖过 AppleScript 往返（实测约 115ms）并留有裕量。
    /// 代价是每首会少播最后这么一小段，取小一些更不易察觉。
    static let lead: TimeInterval = 0.3

    /// 距截止时刻还超过这个值时按常规间隔轮询。
    static let calmWindow: TimeInterval = 3.0

    /// 常规轮询间隔，同时决定进度条刷新频率。不用再为进度条设更小的值。
    static let base: TimeInterval = 0.5

    /// 临近截止时刻的最小睡眠，避免空转。
    static let minimum: TimeInterval = 0.05

    /// 是否该动手：剩余时间已不足 lead。
    ///
    /// 这里**不能**写成「算出截止时刻、再判断是否已到」的形式。那样写会在剩余时间不足
    /// lead 时算不出截止时刻（返回 nil），于是判断恒为「未到」，接管永不触发——音乐照旧
    /// 由 Music 的队列接管，表现为「自动播放乱跳」。直接判断剩余时间即可，且每轮都判，
    /// 因此用户拖动进度条后也能立即对准。
    static func shouldTakeOver(remaining: TimeInterval?, isPlaying: Bool) -> Bool {
        guard isPlaying, let remaining else { return false }
        return remaining <= lead
    }

    /// 下一次轮询等多久：临近曲末就贴着动手点醒，避免 0.5 秒间隔错过只有零点几秒的窗口。
    static func sleepInterval(
        remaining: TimeInterval?,
        isPlaying: Bool,
        fetchSeconds: TimeInterval = 0
    ) -> TimeInterval {
        guard isPlaying, let remaining, remaining <= calmWindow else { return base }
        return min(base, max(minimum, remaining - lead - fetchSeconds))
    }

    /// 把秒数换成纳秒，供 Task.sleep 使用。
    static func sleepNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(minimum, seconds) * 1_000_000_000)
    }
}
