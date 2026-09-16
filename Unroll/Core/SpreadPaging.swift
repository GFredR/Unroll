// AI-Generated | 可修改
// SpreadPaging —— 双页「摊」配对口径(纯函数,零依赖,可穷举单测)
// ----------------------------------------------------------------------------
// 背景(2026-09-16 修复的真缺陷):配对原先写死在 ReaderViewModel 里 ——
// `secondaryIndex = pageIndex + 1` 且 `pageStep = 2`,于是**永远是** (0,1)(2,3)(4,5)。
// 但日式单行本(以及绝大多数漫画单册)的**封面是独立一页**,出版意义上的摊是
//   0 | (1,2) | (3,4) | (5,6) …
// 按 (0,1) 配,从第二摊起每一摊都错位一面:该合在一起看的跨页被拆到两摊,
// 不该相邻的两页被并排 —— 是肉眼可见的内容错乱,不是审美问题。
// 旧模型还有个副作用:跳到奇数页时主图就从奇数页开始配对,配对随「怎么到达」漂移。
//
// 本文件把口径抽成纯函数,并做两件事:
//   1. 用 `coverAlone` 一个布尔表达两种出版约定;
//   2. 提供 `spreadStart(for:)` 归一 —— 任意页索引 → 它所在那一摊的首面。
//      归一保证「跳到第 N 页 → 一定看得到第 N 页」,且配对与到达方式无关。
//
// 口径:
//   · coverAlone = false(默认,与旧版本行为逐位一致):(0,1)(2,3)(4,5)…
//   · coverAlone = true:(0) 单独一摊,之后 (1,2)(3,4)(5,6)…
// 尾页为奇数时最后一摊自然退化为单页(次页 nil,View 已支持)。
//
// 纯函数、不引用 ViewModel / 枚举(口径用 Bool 传入)。理由同 RecentProgressIndex:
// 配对是最容易写错又最难肉眼发现的一段逻辑,必须能脱离 App 宿主穷举验证。
import Foundation

/// 双页配对(摊)计算
enum SpreadPaging {

    /// 一摊的首面:把任意页索引归一到「所在那一摊的第一页」。
    /// 越界/负数按 0 处理(调用方另有夹紧,这里只保证不产出非法值)
    static func spreadStart(for index: Int, coverAlone: Bool) -> Int {
        guard index > 0 else { return 0 }
        // 封面单独时,从第 1 页起每两页一摊;否则从第 0 页起每两页一摊
        return coverAlone ? 1 + ((index - 1) / 2) * 2 : (index / 2) * 2
    }

    /// 次页下标(nil = 本摊只有一面:单页模式 / 封面单独那一摊 / 奇数尾页)
    static func secondaryIndex(for index: Int, pageCount: Int,
                               dual: Bool, coverAlone: Bool) -> Int? {
        guard dual, pageCount > 0 else { return nil }
        let start = spreadStart(for: index, coverAlone: coverAlone)
        if coverAlone, start == 0 { return nil }   // 封面自己一摊
        let next = start + 1
        return next < pageCount ? next : nil
    }

    /// 下一页 / 下一摊的首面。已在最后一摊 → 返回当前位置(不动)
    static func next(from index: Int, pageCount: Int, dual: Bool, coverAlone: Bool) -> Int {
        guard pageCount > 0 else { return 0 }
        let current = clamp(index, pageCount: pageCount)
        guard dual else { return min(current + 1, pageCount - 1) }
        let start = spreadStart(for: current, coverAlone: coverAlone)
        // 封面单独时,封面(0)的下一摊是 1;其余摊 +2
        let candidate = (coverAlone && start == 0) ? 1 : start + 2
        // 夹到最后一摊的首面:避免「跨过尾页」导致末页被单拎出来
        return min(candidate, spreadStart(for: pageCount - 1, coverAlone: coverAlone))
    }

    /// 上一页 / 上一摊的首面。已在首页/第一摊 → 返回 0(不动)
    static func previous(from index: Int, pageCount: Int, dual: Bool, coverAlone: Bool) -> Int {
        guard pageCount > 0 else { return 0 }
        let current = clamp(index, pageCount: pageCount)
        guard dual else { return max(current - 1, 0) }
        let start = spreadStart(for: current, coverAlone: coverAlone)
        if start == 0 { return 0 }
        if coverAlone, start == 1 { return 0 }     // 第 1 摊的上一摊是封面
        return start - 2
    }

    private static func clamp(_ index: Int, pageCount: Int) -> Int {
        min(max(index, 0), pageCount - 1)
    }
}
