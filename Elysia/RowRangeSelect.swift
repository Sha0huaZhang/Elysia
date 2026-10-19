import CoreGraphics

// MARK: - 拖动划过一片行来多选
//
// 在选歌窗口里按住一首歌往下拖，途经的行应成片选中。这里只负责「指针此时落在第几行」，
// 选中范围的合并由调用方处理。
//
// 纯函数，便于单独验证：指针落在行与行的间隙、拖出列表两端、部分行位置读不到时都要有
// 确定的结果。
enum RowRangeSelect {
    /// 指针所指的行下标。
    ///
    /// 先找真正包含该点的行；落在间隙里就取最近的一行，拖出列表两端时就取首/末行——
    /// 这样一路拖到列表外面仍能继续扩大选区，与直觉一致。
    /// 全部行都读不到位置时返回 nil（无从判断，不擅自选择）。
    static func index(atY y: CGFloat, frames: [CGRect?]) -> Int? {
        let known = frames.indices.filter { frames[$0] != nil }
        guard !known.isEmpty else { return nil }

        if let hit = known.first(where: { frames[$0]!.contains(CGPoint(x: frames[$0]!.midX, y: y)) }) {
            return hit
        }
        // 不在任何行内：取中心线最近的一行
        return known.min { a, b in
            abs(frames[a]!.midY - y) < abs(frames[b]!.midY - y)
        }
    }

    /// 两个下标之间的全部下标，顺序无关（向上拖、向下拖结果一样）。
    static func span(_ first: Int, _ second: Int) -> ClosedRange<Int> {
        first <= second ? first...second : second...first
    }
}
