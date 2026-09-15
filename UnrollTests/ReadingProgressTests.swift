// AI-Generated | 可修改
// ReadingProgressTests —— 续读记忆存储(2026-09-15,v2「进度记忆」)
// ----------------------------------------------------------------------------
// 存储层单测:隔离 UserDefaults suite,不碰宿主 App 的真实进度。
import XCTest
@testable import Unroll

final class ReadingProgressTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.progress.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 保存 → 读取往返一致
    func testSaveLoadRoundtrip() {
        let progress = ReadingProgress(defaults: defaults)
        let key = ReadingProgress.key(name: "a.cbz", size: 123)

        progress.save(key: key, page: 7, layout: "dual",
                      direction: "rightToLeft", fitMode: "fitWidth")

        let entry = progress.entry(forKey: key)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.page, 7)
        XCTAssertEqual(entry?.layout, "dual")
        XCTAssertEqual(entry?.direction, "rightToLeft")
        XCTAssertEqual(entry?.fitMode, "fitWidth")
    }

    /// 同名不同大小 = 不同文档(身份键含大小)
    func testKeyDistinguishesFilesBySize() {
        let progress = ReadingProgress(defaults: defaults)
        progress.save(key: ReadingProgress.key(name: "a.cbz", size: 1),
                      page: 1, layout: "single", direction: "leftToRight", fitMode: "fit")
        progress.save(key: ReadingProgress.key(name: "a.cbz", size: 2),
                      page: 2, layout: "single", direction: "leftToRight", fitMode: "fit")

        XCTAssertEqual(progress.entry(forKey: ReadingProgress.key(name: "a.cbz", size: 1))?.page, 1)
        XCTAssertEqual(progress.entry(forKey: ReadingProgress.key(name: "a.cbz", size: 2))?.page, 2)
    }

    /// 覆盖写:同一文档再保存取最新
    func testOverwriteKeepsLatest() {
        let progress = ReadingProgress(defaults: defaults)
        let key = ReadingProgress.key(name: "a.cbz", size: 1)

        progress.save(key: key, page: 3, layout: "single", direction: "leftToRight", fitMode: "fit")
        progress.save(key: key, page: 9, layout: "dual", direction: "leftToRight", fitMode: "fit")

        XCTAssertEqual(progress.entry(forKey: key)?.page, 9)
        XCTAssertEqual(progress.entry(forKey: key)?.layout, "dual")
    }

    /// LRU 上限:超出上限剔除最旧条目
    func testLRUCapEvictsOldest() {
        let progress = ReadingProgress(defaults: defaults)
        let count = ReadingProgress.maxEntries

        for i in 0..<count {
            progress.save(key: "k\(i)", page: i, layout: "single",
                          direction: "leftToRight", fitMode: "fit")
        }
        // 触碰第 0 条(变新),再塞入一条新的 → 被挤掉的应是第 1 条而非第 0 条
        progress.save(key: "k0", page: 0, layout: "single", direction: "leftToRight", fitMode: "fit")
        progress.save(key: "new", page: 99, layout: "single", direction: "leftToRight", fitMode: "fit")

        XCTAssertNotNil(progress.entry(forKey: "k0"))
        XCTAssertNotNil(progress.entry(forKey: "new"))
        XCTAssertNil(progress.entry(forKey: "k1"), "最旧未被触碰的 k1 应被剔除")
    }

    /// 清空后读不到
    func testClearRemovesEverything() {
        let progress = ReadingProgress(defaults: defaults)
        progress.save(key: "k", page: 1, layout: "single", direction: "leftToRight", fitMode: "fit")
        progress.clear()
        XCTAssertNil(progress.entry(forKey: "k"))
    }

    /// 坏数据容错:瞎写的字节不解出崩溃,当空处理
    func testCorruptedDataTreatedAsEmpty() {
        defaults.set(Data("garbage".utf8), forKey: "reading.progress.v1")
        let progress = ReadingProgress(defaults: defaults)
        XCTAssertNil(progress.entry(forKey: "k"))
    }
}
