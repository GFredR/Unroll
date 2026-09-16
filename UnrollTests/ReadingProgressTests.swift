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

    // MARK: - 总页数 / 键名还原(2026-09-15:最近打开菜单标注进度)

    /// total 往返一致(菜单要显示 P.当前/总数)
    func testTotalRoundtrip() {
        let progress = ReadingProgress(defaults: defaults)
        progress.save(key: "k", page: 4, total: 200,
                      layout: "single", direction: "leftToRight", fitMode: "fit")

        XCTAssertEqual(progress.entry(forKey: "k")?.total, 200)
    }

    /// 老记录(无 total 字段)仍能解出,缺省 nil —— 升级不丢已有进度
    func testLegacyRecordWithoutTotalDecodesAsNil() {
        let json = """
        {"k":{"page":3,"layout":"dual","direction":"leftToRight",\
        "fitMode":"fit","updatedAt":0}}
        """
        defaults.set(Data(json.utf8), forKey: "reading.progress.v1")
        let progress = ReadingProgress(defaults: defaults)

        let entry = progress.entry(forKey: "k")
        XCTAssertEqual(entry?.page, 3)
        XCTAssertNil(entry?.total)
    }

    // MARK: - 封面单独一页(双页配对口径,2026-09-16)

    /// coverAlone 往返一致(重开同一本要恢复上次的配对口径)
    func testCoverAloneRoundtrip() {
        let progress = ReadingProgress(defaults: defaults)
        progress.save(key: "k", page: 1, layout: "dual",
                      direction: "rightToLeft", fitMode: "fit", coverAlone: true)

        XCTAssertEqual(progress.entry(forKey: "k")?.coverAlone, true)
    }

    /// coverAlone 缺省写入 = false(老调用方不传参时行为不变)
    func testCoverAloneDefaultsToFalseWhenOmitted() {
        let progress = ReadingProgress(defaults: defaults)
        progress.save(key: "k", page: 1, layout: "dual",
                      direction: "leftToRight", fitMode: "fit")

        XCTAssertEqual(progress.entry(forKey: "k")?.coverAlone, false)
    }

    /// **升级不丢数据**:老记录里没有 coverAlone 字段。
    /// 该字段若写成非可选,解码会抛 keyNotFound,而解码是 `try?` ——
    /// 整份字典会被当成空,用户的全部进度一次性消失。这条用例锁死这个坑
    func testLegacyRecordWithoutCoverAloneKeepsProgress() {
        let json = """
        {"k":{"page":3,"layout":"dual","direction":"leftToRight",\
        "fitMode":"fit","updatedAt":0}}
        """
        defaults.set(Data(json.utf8), forKey: "reading.progress.v1")
        let progress = ReadingProgress(defaults: defaults)

        let entry = progress.entry(forKey: "k")
        XCTAssertEqual(entry?.page, 3, "老记录必须仍能读出页码")
        XCTAssertEqual(progress.allEntries().count, 1, "整份字典不得因新字段被丢弃")
        XCTAssertNil(entry?.coverAlone, "缺省解成 nil,调用方按 false 处理")
    }

    /// 键 → 文件名还原(菜单按文件名匹配进度)
    func testDocumentNameParsedFromKey() {
        XCTAssertEqual(ReadingProgress.documentName(fromKey: ReadingProgress.key(name: "a.cbz", size: 12)),
                       "a.cbz")
        // 文件名本身含分隔符:按最后一个切,名字不被截断
        XCTAssertEqual(ReadingProgress.documentName(fromKey: "we|ird|1.cbz|99"), "we|ird|1.cbz")
        // 非法键(无分隔符)= 原样返回,不崩
        XCTAssertEqual(ReadingProgress.documentName(fromKey: "no-separator"), "no-separator")
    }

    /// allEntries 暴露全量(菜单据此建索引)
    func testAllEntriesReturnsEverything() {
        let progress = ReadingProgress(defaults: defaults)
        progress.save(key: "a|1", page: 1, layout: "single", direction: "leftToRight", fitMode: "fit")
        progress.save(key: "b|2", page: 2, layout: "single", direction: "leftToRight", fitMode: "fit")

        XCTAssertEqual(progress.allEntries().count, 2)
        XCTAssertEqual(progress.allEntries()["b|2"]?.page, 2)
    }
}
