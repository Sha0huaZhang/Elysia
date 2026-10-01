import Foundation

// MARK: - 上一首 / 下一首的落点
//
// 纯函数，便于在没有 Apple Music 的情况下验证连按、末尾环绕等边界。
//
// 顺序以 Elysia 自己的列表为准（含用户拖拽后的自定义顺序），不使用 Apple Music
// 的播放队列；Elysia 未运行时才由 Apple Music 自己决定顺序。
enum SongAdvance {
    /// 选锚点：现场值与已确认的稳定值**一致时用现场值**；不一致时信稳定值。
    ///
    /// 现场查询本身也可能读到过渡抖动（切歌时 Music 会在几首之间来回报「当前曲目」，
    /// 界面甚至同时给多首显示正在播放标识）。所以不能无条件让现场值优先，否则抖动照旧
    /// 传进来。两值一致说明确实在播那一首；不一致则说明现场值可能是抖动，此时用连续两轮
    /// 确认过的稳定值更可靠。
    ///
    /// 稳定值还没有时（刚启动）别无选择，只能用现场值。
    static func fallbackAnchor(live: String?, polled: String?) -> String? {
        guard let polled else { return live }
        return live == polled ? live : polled
    }

    /// 算出「上一首 / 下一首」应落到的下标；返回 nil 表示不移动。
    ///
    /// - Parameters:
    ///   - anchorIndex: 当前歌曲在列表中的下标。nil 表示还不知道播到哪首。
    ///   - count: 列表长度。
    ///   - offset: +1 下一首，-1 上一首。
    ///   - repeatAll: 是否处于「列表循环」。
    static func targetIndex(
        anchorIndex: Int?,
        count: Int,
        offset: Int,
        repeatAll: Bool
    ) -> Int? {
        guard count > 0 else { return nil }

        let candidate: Int
        if let anchor = anchorIndex {
            candidate = anchor + offset
        } else {
            // 还不知道播到哪首：向前就从头开始，向后就从末尾开始
            candidate = offset > 0 ? 0 : count - 1
        }

        if candidate < 0 {
            return repeatAll ? count - 1 : nil
        }
        if candidate >= count {
            return repeatAll ? 0 : nil
        }
        return candidate
    }
}
