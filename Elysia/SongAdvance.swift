import Foundation

// MARK: - 上一首 / 下一首的落点
//
// 纯函数，便于在没有 Apple Music 的情况下验证连按、末尾环绕等边界。
//
// 顺序以 Elysia 自己的列表为准（含用户拖拽后的自定义顺序），不使用 Apple Music
// 的播放队列；Elysia 未运行时才由 Apple Music 自己决定顺序。
enum SongAdvance {
    /// 选锚点：**现场值优先**，取不到时才用轮询确认过的稳定值。
    ///
    /// 早先写反过：当时认为「两者不一致说明现场值可能是切歌过渡态，应信稳定值」。但稳定值
    /// 是**最后一次确认**的曲目，天然比实际播放慢一首；不一致恰恰说明曲目刚换过，此时信稳定值
    /// 会以旧曲为锚点，算出的目标正是「上一首的下一首」——也就是正在播的那首，按下去像没反应。
    /// 实测记录：现场=《友情岁月 (Live)》(#5)、稳定=《在银河中孤独摇摆》(#4)，
    /// 结果算出目标 #5（正在播）。
    static func fallbackAnchor(live: String?, polled: String?) -> String? {
        live ?? polled
    }

    /// 算出「上一首 / 下一首」应落到的下标；返回 nil 表示不移动。
    ///
    /// - Parameters:
    ///   - anchorIndex: 当前歌曲在列表中的下标。nil 表示还不知道播到哪首——此时**不动作**。
    ///     早先会「从头开始」兜底，那等于在不确定时擅自替用户选一首，可能跳到毫不相干的歌。
    ///   - count: 列表长度。
    ///   - offset: +1 下一首，-1 上一首。
    ///   - repeatAll: 是否处于「列表循环」。
    static func targetIndex(
        anchorIndex: Int?,
        count: Int,
        offset: Int,
        repeatAll: Bool
    ) -> Int? {
        guard count > 0, let anchor = anchorIndex else { return nil }

        let candidate = anchor + offset

        if candidate < 0 {
            return repeatAll ? count - 1 : nil
        }
        if candidate >= count {
            return repeatAll ? 0 : nil
        }
        return candidate
    }
}
