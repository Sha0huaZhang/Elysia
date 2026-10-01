import Foundation

// MARK: - 上一首 / 下一首的落点
//
// 纯函数，便于在没有 Apple Music 的情况下验证连按、末尾环绕等边界。
//
// 顺序以 Elysia 自己的列表为准（含用户拖拽后的自定义顺序），不使用 Apple Music
// 的播放队列；Elysia 未运行时才由 Apple Music 自己决定顺序。
enum SongAdvance {
    /// 算出「上一首 / 下一首」应落到的下标；返回 nil 表示不移动。
    ///
    /// - Parameters:
    ///   - anchorIndex: 当前歌曲在列表中的下标。nil 表示还不知道播到哪首。
    ///   - count: 列表长度。
    ///   - offset: +1 下一首，-1 上一首。
    ///   - repeatAll: 是否处于「全部循环」。
    ///   - stopAtEnd: 歌播完自动跳转时为 true。此时即使开着全部循环，走到列表末尾也
    ///                要停下，而不是绕回开头——那正是「全部循环」与「放完为止」的分界。
    static func targetIndex(
        anchorIndex: Int?,
        count: Int,
        offset: Int,
        repeatAll: Bool,
        stopAtEnd: Bool = false
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
            return repeatAll && !stopAtEnd ? 0 : nil
        }
        return candidate
    }
}
