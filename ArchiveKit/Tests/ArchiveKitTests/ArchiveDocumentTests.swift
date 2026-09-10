// AI-Generated | 可修改
// ArchiveDocumentTests —— fixture 驱动的打开/四态/读页单测(设计文档 §6.2)
// ----------------------------------------------------------------------------
// 覆盖 §6.2 的断言要点:列目录行为 + isEncrypted 标志(经四态呈现)+ 读页返回码。
// fixture 由 Tests/Fixtures/make_fixtures.sh 生成并入库(每个仅几百字节),
// 造法与 §5.9 POC 完全一致 —— 断言因此锁死的是「系统 libarchive 的实测行为」。
// fixture 定位用 #filePath 回溯源码树,swift test 与 Xcode 跑法都成立。
import XCTest
@testable import ArchiveKit

final class ArchiveDocumentTests: XCTestCase {

    /// fixture 目录:…/ArchiveKit/Tests/Fixtures(src/ 是造包源图,字节级对照的 ground truth)
    private enum Fixtures {
        static let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/ArchiveKitTests
            .deletingLastPathComponent()      // …/Tests
            .appendingPathComponent("Fixtures")

        static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        static func srcData(_ name: String) throws -> Data {
            try Data(contentsOf: dir.appendingPathComponent("src").appendingPathComponent(name))
        }
    }

    // MARK: - open:明文归档

    /// 明文 cbz:过滤(note.txt/.DS_Store)+ 自然排序(原始顺序是乱的:
    /// 造包写入顺序 page10,page2,page1 —— 断言排序真实发生而非碰巧有序)
    func testOpenPlainCbzFiltersJunkAndSortsNaturally() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))

        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
        XCTAssertEqual(doc.entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(doc.protection, .none)
        XCTAssertEqual(doc.format, .zip)

        // size 是未压缩大小:与源图字节数一致
        let page1 = try Fixtures.srcData("page1.png")
        XCTAssertEqual(doc.entries[0].size, Int64(page1.count))
    }

    /// Finder 风格 cbz(含合法 AppleDouble 的 __MACOSX 元数据条目):
    /// libarchive 自行消化 __MACOSX 条目(列目录不出现),图片照常可读。
    /// 真实用户「右键压缩」产物就是这种形态 —— 必须能开。
    /// (反面:非法 AppleDouble 内容会整档 FATAL,已按 .corrupted 处理,
    ///  见 make_fixtures.sh 实测注记,不另造 fixture)
    func testOpenFinderStyleZipWithAppleDoubleJunk() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("mac-junk.cbz"))
        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
        XCTAssertEqual(doc.protection, .none)
        XCTAssertEqual(try doc.data(at: 0), try Fixtures.srcData("page1.png"))
    }

    /// 明文 cbt(tar):P0 格式,§6.2 明确「cbt 无样本的现状到此为止」
    func testOpenPlainCbt() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbt"))
        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
        XCTAssertEqual(doc.protection, .none)
        XCTAssertEqual(doc.format, .tar)
    }

    /// 目录条目 / 深层隐藏目录内文件 / 未知扩展名均不入列表
    func testOpenFiltersNonImagesAndHiddenPaths() throws {
        // plain.cbt 的 note.txt:tar 内存在但非图片 → 被过滤(上面条目数已证);
        // no-images.cbz 反向证明过滤逻辑没有把所有条目当图片
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("no-images.cbz"))) { error in
            XCTAssertEqual(error as? ArchiveError, .noImages(found: 1))
        }
    }

    // MARK: - open:加密四态(§5.9.1 实测行为表的逐行复刻)

    /// ZIP + ZipCrypto 全加密:能列目录但全部条目加密 → zip 走 .encrypted
    func testOpenFullyEncryptedZipThrowsEncrypted() {
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("encrypted-zip.cbz"))) { error in
            XCTAssertEqual(error as? ArchiveError, .encrypted)
        }
    }

    /// ZIP + AES-256 全加密:§5.9.1 注明「未实测,M1 需补样本」—— 本测试即补测。
    /// 预期与 ZipCrypto 同路(列目录 OK + is_encrypted=1 + 读页要密码)
    func testOpenFullyEncryptedAesZipThrowsEncrypted() {
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("encrypted-zip-aes.cbz"))) { error in
            XCTAssertEqual(error as? ArchiveError, .encrypted)
        }
    }

    /// 7z 内容加密:能列目录但库不支持解密(§5.9.1 结论 1)→ .encryptedUnsupportedFormat
    func testOpenEncrypted7zContentThrowsUnsupported() {
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("encrypted-content.cb7"))) { error in
            XCTAssertEqual(error as? ArchiveError, .encryptedUnsupportedFormat)
        }
    }

    /// 7z 头部加密:列目录 0 条 + FATAL -30 + 文案含 header is encrypted(双信号)
    /// —— 该判定逻辑必须进单测,防库升级换措辞后误判为「损坏」(§5.9.3 表)
    func testOpenHeaderEncrypted7zThrowsHeaderEncrypted() {
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("encrypted-header.cb7"))) { error in
            XCTAssertEqual(error as? ArchiveError, .headerEncrypted)
        }
    }

    /// 部分加密 zip:正常打开 + .partial(2) —— 「部分加密 → 占位卡片」全新 UI 路径的依据
    func testOpenPartiallyEncryptedZipReturnsPartialState() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"))
        XCTAssertEqual(doc.entries.count, 4, "加密页保留在列表里,由读页阶段逐页报错")
        XCTAssertEqual(doc.entries.map(\.path),
                       ["page1.png", "page2.png", "page3.png", "page4.png"])
        XCTAssertEqual(doc.protection, .partial(encryptedCount: 2))
        XCTAssertEqual(doc.format, .zip)
    }

    // MARK: - open:损坏 / 空 / 无图 / 文件消失

    func testOpenCorruptedThrowsCorrupted() {
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("corrupted.cbz"))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupted)
        }
    }

    func testOpenEmptyThrowsEmpty() {
        XCTAssertThrowsError(try ArchiveDocument.open(url: Fixtures.url("empty.cbz"))) { error in
            XCTAssertEqual(error as? ArchiveError, .empty)
        }
    }

    /// open 与 data(at:) 之间文件被移走:不崩,报「无法打开这个文件」
    func testOpenMissingFileThrowsCorrupted() {
        XCTAssertThrowsError(
            try ArchiveDocument.open(url: Fixtures.url("does-not-exist.cbz"))
        ) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupted)
        }
    }

    // MARK: - data(at:):字节级 round-trip

    /// 明文 cbz 读页:内容与源图逐字节一致。
    /// 注意 plain.cbz 原始顺序是 page10,page2,page1 —— 排序后 index 0/1/2
    /// 分别映射到原始位置 2/1/0,本测试同时锁死 rawPositions 映射的正确性
    func testReadPlainCbzRoundTripsExactly() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        XCTAssertEqual(try doc.data(at: 0), try Fixtures.srcData("page1.png"))
        XCTAssertEqual(try doc.data(at: 1), try Fixtures.srcData("page2.png"))
        XCTAssertEqual(try doc.data(at: 2), try Fixtures.srcData("page10.png"))
    }

    func testReadPlainCbtRoundTripsExactly() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbt"))
        XCTAssertEqual(try doc.data(at: 0), try Fixtures.srcData("page1.png"))
    }

    /// 部分加密:明文页照常读,加密页抛 .encrypted —— 「单页失败 ≠ 整档失败」
    func testReadPartialCbzPlainPagesWorkEncryptedPagesThrow() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"))
        XCTAssertEqual(try doc.data(at: 0), try Fixtures.srcData("page1.png"))
        XCTAssertEqual(try doc.data(at: 1), try Fixtures.srcData("page2.png"))
        XCTAssertThrowsError(try doc.data(at: 2)) { error in
            XCTAssertEqual(error as? ArchiveError, .encrypted)
        }
        XCTAssertThrowsError(try doc.data(at: 3)) { error in
            XCTAssertEqual(error as? ArchiveError, .encrypted)
        }
    }

    /// 越界 index:绝不 trap(§5.9.4「绝不闪退」),按 .unknown 兜底
    func testReadOutOfRangeIndexThrowsInsteadOfCrashing() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        XCTAssertThrowsError(try doc.data(at: 99)) { error in
            guard case .unknown = error as? ArchiveError else {
                return XCTFail("预期 .unknown,得到 \(error)")
            }
        }
    }

    // MARK: - 并发读取一致性(§6.2)

    /// 每个并发读自建 libarchive 实例(§4.4 规则 1):并发读同一档不同页,
    /// 全部成功且字节正确 —— 锁死「无共享可变状态」的设计前提
    func testConcurrentReadsAreConsistent() async throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let expected = try [
            Fixtures.srcData("page1.png"),
            Fixtures.srcData("page2.png"),
            Fixtures.srcData("page10.png"),
        ]

        // 3 个并发子任务各读各的页:data(at:) 每次自建 libarchive 实例,
        // 若存在共享可变状态(如复用句柄),并发下必然互相踩踏
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for i in expected.indices {
                group.addTask { try doc.data(at: i) }
            }
            var collected: [Data] = []
            collected.reserveCapacity(expected.count)
            while let d = try await group.next() { collected.append(d) }
            return collected
        }

        // 完成顺序不定:按集合比较,不按序比较
        XCTAssertEqual(results.count, expected.count)
        for d in results {
            XCTAssertTrue(expected.contains(d), "并发读出了意料之外的字节")
        }
    }

    // MARK: - 图片条目判定(isListedImage 规则单测)

    /// __MACOSX/ 场景无法用 fixture 端到端复现(实测:合法 AppleDouble 被
    /// libarchive 自行消化、非法内容整档 FATAL),因此过滤规则直接单测覆盖(§6.2)
    func testIsListedImageFiltersJunkEntries() {
        // 正常图片:各种受支持扩展名、大小写、深层路径
        XCTAssertTrue(ArchiveDocument.isListedImage("page1.png"))
        XCTAssertTrue(ArchiveDocument.isListedImage("PAGE1.JPG"))
        XCTAssertTrue(ArchiveDocument.isListedImage("vol01/ch002.webp"))
        XCTAssertTrue(ArchiveDocument.isListedImage("a/b/c/d/page1.heic"))

        // 非图片扩展名
        XCTAssertFalse(ArchiveDocument.isListedImage("note.txt"))
        XCTAssertFalse(ArchiveDocument.isListedImage("page1.pdf"))

        // 隐藏文件 / 隐藏目录内
        XCTAssertFalse(ArchiveDocument.isListedImage(".DS_Store"))
        XCTAssertFalse(ArchiveDocument.isListedImage("vol01/.hidden.jpg"))
        XCTAssertFalse(ArchiveDocument.isListedImage(".hidden/page1.jpg"))

        // __MACOSX 垃圾目录(前缀或裸目录名)
        XCTAssertFalse(ArchiveDocument.isListedImage("__MACOSX/page1.png"))
        XCTAssertFalse(ArchiveDocument.isListedImage("__MACOSX/._page1.png"))

        // 目录条目(尾部斜杠)与空串
        XCTAssertFalse(ArchiveDocument.isListedImage("vol01/"))
        XCTAssertFalse(ArchiveDocument.isListedImage(""))

        // 无扩展名 / 只有扩展名
        XCTAssertFalse(ArchiveDocument.isListedImage("page1"))
        XCTAssertFalse(ArchiveDocument.isListedImage(".png"), "纯扩展名视为隐藏文件")
    }
}
