// AI-Generated | 可修改
// SpreadPagingTests —— 双页配对口径(2026-09-16 真缺陷修复)
// ----------------------------------------------------------------------------
// 这组用例是缺陷的**回归锁**:旧实现写死「次页 = 主页 + 1 / 步长 ×2」,
// 数学上无法表达「封面单独一页」,于是日式单行本从第二摊起每一摊错位一面。
// 纯函数无依赖,故直接穷举两种口径 × 各种页数,不依赖任何 fixture。
import XCTest
@testable import Unroll

final class SpreadPagingTests: XCTestCase {

    // MARK: - 归一(任意页 → 所属摊的首面)

    /// 不单独封面:偶数页就是摊首面,奇数页归到前一个偶数
    func testSpreadStartWithoutCoverAlone() {
        XCTAssertEqual(SpreadPaging.spreadStart(for: 0, coverAlone: false), 0)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 1, coverAlone: false), 0)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 2, coverAlone: false), 2)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 3, coverAlone: false), 2)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 7, coverAlone: false), 6)
    }

    /// 封面单独:封面自己一摊,第 1 页起每两页一摊(1-2 / 3-4 / 5-6)
    func testSpreadStartWithCoverAlone() {
        XCTAssertEqual(SpreadPaging.spreadStart(for: 0, coverAlone: true), 0, "封面单独一摊")
        XCTAssertEqual(SpreadPaging.spreadStart(for: 1, coverAlone: true), 1)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 2, coverAlone: true), 1, "第 2 面与第 1 面同摊")
        XCTAssertEqual(SpreadPaging.spreadStart(for: 3, coverAlone: true), 3)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 4, coverAlone: true), 3)
        XCTAssertEqual(SpreadPaging.spreadStart(for: 7, coverAlone: true), 7)
    }

    /// 负数按 0 处理(调用方另有夹紧,这里只保证不产出非法值)
    func testSpreadStartNeverNegative() {
        XCTAssertEqual(SpreadPaging.spreadStart(for: -5, coverAlone: false), 0)
        XCTAssertEqual(SpreadPaging.spreadStart(for: -5, coverAlone: true), 0)
    }

    // MARK: - 次页下标

    /// 单页模式恒无次页(与双页开关无关)
    func testSecondaryNilInSingleMode() {
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 10, dual: false, coverAlone: false))
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 10, dual: false, coverAlone: true))
    }

    /// 空文档不产出次页(避免 pageCount=0 时算出下标 0)
    func testSecondaryNilForEmptyDocument() {
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 0, dual: true, coverAlone: false))
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 0, dual: true, coverAlone: true))
    }

    /// 不单独封面:0-1 / 2-3 / 4-5(**旧行为,必须逐位保持**)
    func testSecondaryPairsWithoutCoverAlone() {
        let expected = [1, 1, 3, 3, 5, 5]
        for (index, pair) in expected.enumerated() {
            XCTAssertEqual(SpreadPaging.secondaryIndex(for: index, pageCount: 6,
                                                       dual: true, coverAlone: false), pair,
                           "第 \(index) 页的配对错误")
        }
        // 奇数尾页:最后一页没有次页
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 5, pageCount: 5, dual: true, coverAlone: false))
    }

    /// 封面单独:封面无次页,之后 1-2 / 3-4(这是修复的核心断言)
    func testSecondaryPairsWithCoverAlone() {
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 6, dual: true, coverAlone: true),
                     "封面必须单独上屏 —— 不能和下一页并排")
        XCTAssertEqual(SpreadPaging.secondaryIndex(for: 1, pageCount: 6, dual: true, coverAlone: true), 2)
        XCTAssertEqual(SpreadPaging.secondaryIndex(for: 2, pageCount: 6, dual: true, coverAlone: true), 2)
        XCTAssertEqual(SpreadPaging.secondaryIndex(for: 3, pageCount: 6, dual: true, coverAlone: true), 4)
        // 奇数尾页:末面单独
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 5, pageCount: 6, dual: true, coverAlone: true))
    }

    /// 只有 1 页:无论哪种口径都只有一面
    func testSinglePageDocumentHasNoSecondary() {
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 1, dual: true, coverAlone: false))
        XCTAssertNil(SpreadPaging.secondaryIndex(for: 0, pageCount: 1, dual: true, coverAlone: true))
    }

    // MARK: - 翻页推进(这是缺陷的第二个面:步长写死 ×2)

    /// 封面单独时第 0 摊 → 第 1 摊的步长必须是 1(旧实现会跳到第 2 页,直接漏看第 1 页)
    func testNextFromCoverStepsToPageOneWhenCoverAlone() {
        XCTAssertEqual(SpreadPaging.next(from: 0, pageCount: 6, dual: true, coverAlone: true), 1,
                       "封面的下一页是第 1 页(不是第 2 页)")
        XCTAssertEqual(SpreadPaging.next(from: 1, pageCount: 6, dual: true, coverAlone: true), 3)
        XCTAssertEqual(SpreadPaging.next(from: 3, pageCount: 6, dual: true, coverAlone: true), 5)
    }

    /// 不单独封面:步长恒 2,与旧行为一致
    func testNextStepsByTwoWithoutCoverAlone() {
        XCTAssertEqual(SpreadPaging.next(from: 0, pageCount: 6, dual: true, coverAlone: false), 2)
        XCTAssertEqual(SpreadPaging.next(from: 2, pageCount: 6, dual: true, coverAlone: false), 4)
    }

    /// 已到最后一摊:next 不动(不得把末页单拎出来,也不得 +=2 越过尾页)
    func testNextStopsAtLastSpread() {
        // 6 页 + 封面单独:最后一摊是 (5)
        XCTAssertEqual(SpreadPaging.next(from: 5, pageCount: 6, dual: true, coverAlone: true), 5)
        // 6 页 + 不单独:最后一摊是 (4,5),摊首面是 4
        XCTAssertEqual(SpreadPaging.next(from: 4, pageCount: 6, dual: true, coverAlone: false), 4)
        // 3 页 + 不单独:最后一摊是 (2)
        XCTAssertEqual(SpreadPaging.next(from: 2, pageCount: 3, dual: true, coverAlone: false), 2)
        // 1 页:唯一那一摊
        XCTAssertEqual(SpreadPaging.next(from: 0, pageCount: 1, dual: true, coverAlone: false), 0)
    }

    /// 单页模式步长恒 1
    func testNextAndPreviousStepByOneInSingleMode() {
        XCTAssertEqual(SpreadPaging.next(from: 0, pageCount: 5, dual: false, coverAlone: false), 1)
        XCTAssertEqual(SpreadPaging.next(from: 4, pageCount: 5, dual: false, coverAlone: false), 4)
        XCTAssertEqual(SpreadPaging.previous(from: 4, pageCount: 5, dual: false, coverAlone: false), 3)
        XCTAssertEqual(SpreadPaging.previous(from: 0, pageCount: 5, dual: false, coverAlone: false), 0)
    }

    /// previous 与 next 互为逆(往返回到原摊)
    func testPreviousIsInverseOfNext() {
        for coverAlone in [false, true] {
            for pageCount in 1...9 {
                var index = 0
                var forward: [Int] = [0]
                // 一路前进,记录每个停留点
                var guardCount = 0
                while guardCount < 20 {
                    let advanced = SpreadPaging.next(from: index, pageCount: pageCount,
                                                     dual: true, coverAlone: coverAlone)
                    if advanced == index { break }
                    index = advanced
                    forward.append(index)
                    guardCount += 1
                }
                // 再一路后退,应逐点回到起点
                var back: [Int] = [index]
                while index > 0 {
                    index = SpreadPaging.previous(from: index, pageCount: pageCount,
                                                  dual: true, coverAlone: coverAlone)
                    back.append(index)
                }
                XCTAssertEqual(Array(back.reversed()), forward,
                               "页数 \(pageCount) / coverAlone=\(coverAlone) 的前进后退路径不对称")
            }
        }
    }

    /// 前进路径必须覆盖每一个摊首面,且严格递增(不得跳摊、不得漏摊)
    func testForwardWalkVisitsEverySpreadStart() {
        for coverAlone in [false, true] {
            for pageCount in 1...9 {
                var starts: [Int] = []
                var index = 0
                for _ in 0..<20 {
                    starts.append(index)
                    let advanced = SpreadPaging.next(from: index, pageCount: pageCount,
                                                     dual: true, coverAlone: coverAlone)
                    if advanced == index { break }
                    index = advanced
                }
                let expected = (0..<pageCount)
                    .map { SpreadPaging.spreadStart(for: $0, coverAlone: coverAlone) }
                let unique = Array(Set(expected)).sorted()
                XCTAssertEqual(starts, unique,
                               "页数 \(pageCount) / coverAlone=\(coverAlone) 的前进路径应为全部摊首面")
            }
        }
    }

    /// 边界:0 页时一切调用都返回 0 / nil,不崩不产非法值
    func testEmptyDocumentEdges() {
        XCTAssertEqual(SpreadPaging.next(from: 3, pageCount: 0, dual: true, coverAlone: false), 0)
        XCTAssertEqual(SpreadPaging.previous(from: 3, pageCount: 0, dual: true, coverAlone: true), 0)
    }
}
