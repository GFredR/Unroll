// AI-Generated | 可修改
// NaturalSortTests —— 自然排序单测(设计文档 §2.1 P0-8 / §6.2)
// ----------------------------------------------------------------------------
// 四组用例(M0 头注释预告的组):数字段 / 前导零破平局 / 混合大小写 / 空串。
// 铁律:page2 < page10 是 P0 验收项,字典序行为(page10 < page2)是翻页事故。
import XCTest
@testable import ArchiveKit

final class NaturalSortTests: XCTestCase {

    // MARK: - 组 1:数字段按数值(核心验收项)

    func testPage2SortsBeforePage10() {
        XCTAssertTrue(NaturalSort.less("page2", "page10"))
        XCTAssertFalse(NaturalSort.less("page10", "page2"), "字典序事故必须被纠正")
    }

    func testMultiDigitNumericOrder() {
        // 数值链:1 < 2 < 9 < 10 < 11 < 100(字典序会得到 1,10,100,11,2,9)
        let shuffled = ["p11", "p100", "p2", "p9", "p1", "p10"]
        let sorted = shuffled.sorted { NaturalSort.less($0, $1) }
        XCTAssertEqual(sorted, ["p1", "p2", "p9", "p10", "p11", "p100"])
    }

    func testNumericSegmentsInsidePaths() {
        // 目录名里的数字同样按数值:vol2 < vol10
        XCTAssertTrue(NaturalSort.less("vol2/ch001.jpg", "vol10/ch001.jpg"))
        // 目录相同才轮到文件名比较
        XCTAssertTrue(NaturalSort.less("vol1/p2.jpg", "vol1/p10.jpg"))
        // 数值大的目录即使文件名小,也整体在后
        XCTAssertFalse(NaturalSort.less("vol10/p1.jpg", "vol2/p99.jpg"))
    }

    func testPureNumbers() {
        XCTAssertTrue(NaturalSort.less("2", "10"))
        XCTAssertTrue(NaturalSort.less("007", "08"), "数值比较:7 < 8")
    }

    // MARK: - 组 2:前导零破平局

    func testLeadingZeroTieBreak() {
        // 数值全等的 1,按原始数字段字典序:p001 < p01 < p1
        XCTAssertTrue(NaturalSort.less("p001", "p01"))
        XCTAssertTrue(NaturalSort.less("p01", "p1"))
        // 反向必然为假(严格全序)
        XCTAssertFalse(NaturalSort.less("p1", "p01"))
    }

    func testAllZeroPaddingStillTotallyOrdered() {
        // "000" 与 "0" 数值相等(都是 0),仍由原始段字典序破平局:
        // "0" 是 "000" 的前缀 → "0" < "000"(与含非零数字的 "001" < "01" < "1"
        // 方向不同,但都是确定性的全序 —— 全零填充是病态文件名,方向无所谓)
        XCTAssertTrue(NaturalSort.less("p0", "p000"))
        XCTAssertTrue(NaturalSort.less("p0", "p1"))
    }

    // MARK: - 组 3:混合大小写

    func testCaseInsensitivePrimary() {
        // 大小写不敏感优先:Page2 仍按数值排在 page10 前
        XCTAssertTrue(NaturalSort.less("Page2", "page10"))
        XCTAssertFalse(NaturalSort.less("page10", "Page2"))
        // 数值相同时大小写破平局,保证确定性(ASCII 大写在前)
        XCTAssertTrue(NaturalSort.less("PAGE2", "page2"))
    }

    // MARK: - 组 4:空串与边界

    func testEmptyStringSortsFirstAndNeverLessThanItself() {
        XCTAssertTrue(NaturalSort.less("", "page1"), "空串在最前")
        XCTAssertFalse(NaturalSort.less("page1", ""))
        XCTAssertFalse(NaturalSort.less("", ""), "等序时 less 必须为 false")
    }

    func testPrefixSortsBeforeLonger() {
        // "page" 是 "page2" 的前缀:段少者在前
        XCTAssertTrue(NaturalSort.less("page", "page2"))
        XCTAssertFalse(NaturalSort.less("page2", "page"))
    }

    /// 全序一致性:任意 a,b,less(a,b) 与 less(b,a) 恰多一个为真
    func testTotalOrderConsistency() {
        let names = ["", "p", "p1", "p01", "p001", "p2", "p10", "P2", "vol1/p2.jpg",
                     "vol10/p1.jpg", "p1a", "p1b", "007", "08", "__MACOSX/p1"]
        for a in names {
            for b in names {
                let ab = NaturalSort.less(a, b)
                let ba = NaturalSort.less(b, a)
                XCTAssertTrue(ab != ba || !ab,
                              "「\(a)」与「\(b)」违反全序:less(a,b)=\(ab), less(b,a)=\(ba)")
            }
        }
    }
}
