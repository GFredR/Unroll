// AI-Generated | 可修改
// BookmarksTests —— 书签存储(v2「书签」,2026-09-15)
// ----------------------------------------------------------------------------
// 隔离 UserDefaults suite,不碰宿主 App 的真实书签。
// 只测纯存储逻辑:切换/升序/按文档隔离/两级上限/清空/坏数据容错 ——
// 即「书签菜单」背后的全部数据行为(菜单本身走 ReaderViewModelTests)。
import XCTest
@testable import Unroll

final class BookmarksTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var bookmarks: Bookmarks!

    override func setUp() {
        super.setUp()
        suiteName = "test.bookmarks.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        bookmarks = Bookmarks(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 落盘字典(校验上限类断言用;避免为测试单开只读 API)
    private func stored() -> [String: Bookmarks.Entry] {
        guard let data = defaults.data(forKey: "bookmarks.v1") else { return [:] }
        return (try? JSONDecoder().decode([String: Bookmarks.Entry].self, from: data)) ?? [:]
    }

    // MARK: - 切换

    /// toggle 是切换语义:返回值即切换后的状态
    func testToggleAddsThenRemoves() {
        XCTAssertTrue(bookmarks.toggle(page: 3, key: "a.cbz|1"))
        XCTAssertEqual(bookmarks.pages(forKey: "a.cbz|1"), [3])

        XCTAssertFalse(bookmarks.toggle(page: 3, key: "a.cbz|1"))
        XCTAssertTrue(bookmarks.pages(forKey: "a.cbz|1").isEmpty)
    }

    /// 页码恒升序 —— 「下一个/上一个书签」的顺序查找依赖这个不变量
    func testPagesStaySorted() {
        for page in [9, 2, 40, 7] {
            bookmarks.toggle(page: page, key: "k")
        }
        XCTAssertEqual(bookmarks.pages(forKey: "k"), [2, 7, 9, 40])
    }

    func testUnknownDocumentReturnsEmpty() {
        XCTAssertTrue(bookmarks.pages(forKey: "never-seen").isEmpty)
    }

    // MARK: - 按文档隔离

    func testDocumentsAreIsolated() {
        bookmarks.toggle(page: 1, key: "a.cbz|1")
        XCTAssertTrue(bookmarks.pages(forKey: "b.cbz|2").isEmpty)

        bookmarks.toggle(page: 5, key: "b.cbz|2")
        XCTAssertEqual(bookmarks.pages(forKey: "a.cbz|1"), [1])
        XCTAssertEqual(bookmarks.pages(forKey: "b.cbz|2"), [5])
    }

    /// 清空单本:不影响其他文档
    func testClearDocumentKeepsOthers() {
        bookmarks.toggle(page: 1, key: "a")
        bookmarks.toggle(page: 2, key: "b")

        bookmarks.clearDocument(key: "a")
        XCTAssertTrue(bookmarks.pages(forKey: "a").isEmpty)
        XCTAssertEqual(bookmarks.pages(forKey: "b"), [2])
    }

    // MARK: - 上限

    /// 每本上限:超限丢**最早**的页码(保留最新标记的一批)
    func testPerDocumentCapDropsEarliestPages() {
        let cap = Bookmarks.maxPagesPerDocument
        for page in 0..<(cap + 5) {
            bookmarks.toggle(page: page, key: "k")
        }
        let pages = stored()["k"]?.pages ?? []
        XCTAssertEqual(pages.count, cap)
        XCTAssertEqual(pages.first, 5, "最早的 5 个页码应被丢弃")
        XCTAssertEqual(pages.last, cap + 4)
    }

    /// 文档数上限:超限剔除最久未更新的文档(整体条目数收敛在上限内)
    func testDocumentCapEvictsOldest() {
        for i in 0..<(Bookmarks.maxDocuments + 2) {
            bookmarks.toggle(page: i, key: "doc-\(i)")
        }
        XCTAssertEqual(stored().count, Bookmarks.maxDocuments)
    }

    // MARK: - 清空与容错

    func testClearRemovesEverything() {
        bookmarks.toggle(page: 1, key: "a")
        bookmarks.toggle(page: 2, key: "b")

        bookmarks.clear()
        XCTAssertTrue(bookmarks.pages(forKey: "a").isEmpty)
        XCTAssertTrue(bookmarks.pages(forKey: "b").isEmpty)
        XCTAssertTrue(stored().isEmpty)
    }

    /// 坏数据当空处理:绝不影响阅读主流程(§5.9.4 同款原则)
    func testCorruptedDataTreatedAsEmpty() {
        defaults.set(Data("garbage".utf8), forKey: "bookmarks.v1")
        XCTAssertTrue(bookmarks.pages(forKey: "k").isEmpty)

        // 坏数据之上仍可正常写入(自愈,不永久卡死)
        XCTAssertTrue(bookmarks.toggle(page: 1, key: "k"))
        XCTAssertEqual(bookmarks.pages(forKey: "k"), [1])
    }
}
