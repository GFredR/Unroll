// AI-Generated | 可修改
// RecentDocumentsTests —— 最近打开(M3,§5.7)
// ----------------------------------------------------------------------------
// 全部走注入的 UserDefaults(suiteName:),不碰生产配置;
// 不造真实 security-scoped bookmark(测试宿主无用户授权),只测:
// 顺序/去重/上限/清空/失效书签剔除 —— 即 UI 菜单背后的全部纯逻辑。
import XCTest
@testable import Unroll

final class RecentDocumentsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var recents: RecentDocuments!

    override func setUp() {
        super.setUp()
        suiteName = "RecentDocumentsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        recents = RecentDocuments(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func url(_ name: String) -> URL {
        // 书签数据造不出来(Data() 占位),重开链路由 resolve 的失效分支覆盖
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    // MARK: - 基本行为

    func testAddPutsNewestFirst() {
        recents.add(url: url("a.cbz"))
        recents.add(url: url("b.cbz"))
        recents.add(url: url("c.cbz"))

        XCTAssertEqual(recents.entries().map(\.name), ["c.cbz", "b.cbz", "a.cbz"])
    }

    func testDisplayNameIsFileNameOnly() {
        recents.add(url: url("a.cbz"))
        // 隐私红线:列表里只有文件名,绝不出现完整路径
        XCTAssertEqual(recents.entries().first?.displayName, "a.cbz")
        XCTAssertFalse(recents.entries().first!.name.contains("/"))
    }

    func testSameNameDedupesAndBumpsToTop() {
        recents.add(url: url("a.cbz"))
        recents.add(url: url("b.cbz"))
        recents.add(url: url("a.cbz"))

        XCTAssertEqual(recents.entries().map(\.name), ["a.cbz", "b.cbz"])
        XCTAssertEqual(recents.entries().count, 2)
    }

    /// LRU 上限:超过 10 条挤掉最旧的
    func testCapAtTenEntries() {
        for i in 0..<12 {
            recents.add(url: url("page-\(i).cbz"))
        }
        let list = recents.entries()
        XCTAssertEqual(list.count, RecentDocuments.maxEntries)
        XCTAssertEqual(list.first?.name, "page-11.cbz")
        XCTAssertEqual(list.last?.name, "page-2.cbz")   // page-0/1 已被挤出
    }

    func testClear() {
        recents.add(url: url("a.cbz"))
        recents.clear()
        XCTAssertTrue(recents.entries().isEmpty)
    }

    // MARK: - 失效书签(坏条目不致命,§5.9.4 同款原则)

    /// 书签数据为空(造不出书签时的落盘形态)→ resolve 返回 nil,可被调用方剔除
    func testResolveInvalidBookmarkReturnsNil() {
        recents.add(url: url("a.cbz"))
        let entry = recents.entries().first!
        XCTAssertNil(recents.resolve(entry))
    }

    func testRemoveSingleEntry() {
        recents.add(url: url("a.cbz"))
        recents.add(url: url("b.cbz"))
        let entry = recents.entries().first { $0.name == "a.cbz" }!
        recents.remove(entry)

        XCTAssertEqual(recents.entries().map(\.name), ["b.cbz"])
    }
}
