// AI-Generated | 可修改
// RecentDocumentsTests —— 最近打开(M3,§5.7)
// ----------------------------------------------------------------------------
// 全部走注入的 UserDefaults(suiteName:),不碰生产配置。
// 两条线:
//   ① 占位书签(Data())—— 覆盖顺序/去重/上限/清空/失效剔除等纯逻辑,不依赖任何授权;
//   ② 真实书签(容器内临时目录的真文件)—— 覆盖 2026-09-15 新增的失效探测
//      「能解析 → 不误标 / 文件被删 → 标失效」;宿主造不出 security-scoped 书签时
//      自动 XCTSkip,不伪装通过。
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

    // MARK: - 失效探测:标记与清理分离(2026-09-15)

    /// 造一个真实文件(容器内临时目录),用于验「能解析 / 不能解析」两种走向
    private func makeRealFile(_ name: String = "real.cbz") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try Data("PK\u{03}\u{04}".utf8).write(to: file)
        return file
    }

    /// 造不出书签的条目一律算失效;探测**只读**,不动已存列表
    func testProbeMarksUnusableBookmarksWithoutRemoving() {
        recents.add(url: url("a.cbz"))
        recents.add(url: url("b.cbz"))

        XCTAssertEqual(recents.unresolvableIDs(), Set(recents.entries().map(\.id)))
        XCTAssertEqual(recents.entries().count, 2, "探测只读:删除动作留给调用方")
    }

    /// 文件被删 → 探测出该条失效(菜单「找不到文件」后缀的数据来源)
    func testProbeFindsDeletedFile() throws {
        let file = try makeRealFile()
        recents.add(url: file)
        let entry = recents.entries().first!
        guard let probe = recents.resolve(entry) else {
            throw XCTSkip("测试宿主造不出 security-scoped 书签,跳过正向链路")
        }
        recents.stopAccess(probe)

        try FileManager.default.removeItem(at: file)

        XCTAssertEqual(recents.unresolvableIDs(), [entry.id])
        XCTAssertEqual(recents.entries().count, 1, "探测不删除")
    }

    /// 文件还在 → 不得误标(反例断言,防「一律标失效」的假实现蒙混过关)
    func testProbeLeavesResolvableEntryAlone() throws {
        let file = try makeRealFile()
        recents.add(url: file)
        let entry = recents.entries().first!
        guard let probe = recents.resolve(entry) else {
            throw XCTSkip("测试宿主造不出 security-scoped 书签,跳过正向链路")
        }
        recents.stopAccess(probe)

        XCTAssertTrue(recents.unresolvableIDs().isEmpty, "可解析条目不得被判失效")
    }
}
