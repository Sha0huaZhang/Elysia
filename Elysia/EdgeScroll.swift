import CoreGraphics

// MARK: - 拖动到边缘时自动滚动
//
// 歌曲列表比窗口高得多，一次拖动很难从头拉到尾：鼠标一离开可见区域就没法继续，
// 只能松手、滚一段、再拖一次。这里判断指针是否停在上下边缘带里，由调用方据此滚动。
//
// 纯函数，便于单独验证方向与目标行的选择。
enum EdgeScroll {
    /// 触发滚动的边缘带高度（点）。
    static let band: CGFloat = 60

    /// 指针在边缘带里时应滚动的方向：-1 向上，+1 向下，0 不滚动。
    ///
    /// 指针越过边界也算——拖到列表外面时用户显然还想继续往下拉。
    static func direction(pointerY: CGFloat, container: CGRect) -> Int {
        if pointerY < container.minY + band { return -1 }
        if pointerY > container.maxY - band { return 1 }
        return 0
    }

    /// 下一步应滚到哪一行，返回该行在 `frames` 中的下标；nil 表示已到头，无需再滚。
    ///
    /// - frames: 各行按列表顺序排列的全局坐标（读不到的行传 nil）
    /// - direction: -1 向上滚（把上一行带到顶部），+1 向下滚（把下一行带到底部）
    ///
    /// 向上滚时取「第一行仍可见的行」的前一行，向下滚时取「最后一行仍可见的行」的
    /// 后一行，因此每步只前进一行，滚动手感是连续的，不会一下跳很远。
    static func targetRow(frames: [CGRect?], container: CGRect, direction: Int) -> Int? {
        guard direction != 0, !frames.isEmpty else { return nil }

        if direction < 0 {
            guard let firstVisible = frames.firstIndex(where: { frame in
                guard let frame else { return false }
                return frame.midY > container.minY
            }) else { return nil }
            return firstVisible - 1 >= 0 ? firstVisible - 1 : nil
        }

        guard let lastVisible = frames.lastIndex(where: { frame in
            guard let frame else { return false }
            return frame.midY < container.maxY
        }) else { return nil }
        return lastVisible + 1 < frames.count ? lastVisible + 1 : nil
    }
}
