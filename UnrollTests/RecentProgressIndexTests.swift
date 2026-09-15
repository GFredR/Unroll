// AI-Generated | 可修改
// RecentProgressIndexTests —— 续读记录按文件名建索引(2026-09-15)
// ----------------------------------------------------------------------------
// 「打开最近」菜单的进度标注靠它:键是「文件名|大小」而条目只有文件名,
// 故按名匹配;同名多份取最新。纯逻辑,不碰任何存储。
import XCTest
@testable import Unroll

final class RecentProgressIndexTests: XCTestCase {

    private func entry(page: Int, total: Int? = nil, updatedAt: Date = Date()) -> ReadingProgress.Entry {
        ReadingProgress.Entry(page: page, layout: "single", direction: "leftToRight",
                              fitMode: "fit", updatedAt: updatedAt, total: total)
    }

    /// 键含大小,但匹配只看文件名
    func testMatchesByDocumentName() {
        let index = RecentProgressIndex(entries: [ReadingProgress.key(name: "a.cbz", size: 100):
                                                   entry(page: 4, total: 200)])
        XCTAssertEqual(index.entry(forDocument: "a.cbz")?.page, 4)
        XCTAssertEqual(index.entry(forDocument: "a.cbz")?.total, 200)
    }

    func testUnknownDocumentReturnsNil() {
        let index = RecentProgressIndex(entries: [:])
        XCTAssertNil(index.entry(forDocument: "a.cbz"))
    }

    /// 同名多份(大小不同)→ 取 updatedAt 最新的一条,且与字典顺序无关
    func testSameNamePicksMostRecentlyUpdated() {
        let old = entry(page: 1, total: 10, updatedAt: Date(timeIntervalSince1970: 1_000))
        let new = entry(page: 7, total: 10, updatedAt: Date(timeIntervalSince1970: 2_000))

        let forward = RecentProgressIndex(entries: ["a.cbz|1": old, "a.cbz|2": new])
        let reversed = RecentProgressIndex(entries: ["a.cbz|2": new, "a.cbz|1": old])

        XCTAssertEqual(forward.entry(forDocument: "a.cbz")?.page, 7)
        XCTAssertEqual(reversed.entry(forDocument: "a.cbz")?.page, 7)
    }

    /// 文件名本身含分隔符:「按最后一个 | 切」才不会截断名字
    func testNameContainingSeparatorMatches() {
        let index = RecentProgressIndex(entries: ["vol|01.cbz|4096": entry(page: 2)])
        XCTAssertEqual(index.entry(forDocument: "vol|01.cbz")?.page, 2)
    }

    /// 多个不同文档各自独立
    func testMultipleDocumentsCoexist() {
        let index = RecentProgressIndex(entries: [
            "a.cbz|1": entry(page: 1, total: 10),
            "b.cbz|2": entry(page: 5, total: 20),
        ])
        XCTAssertEqual(index.entry(forDocument: "a.cbz")?.page, 1)
        XCTAssertEqual(index.entry(forDocument: "b.cbz")?.page, 5)
        XCTAssertNil(index.entry(forDocument: "c.cbz"))
    }
}
