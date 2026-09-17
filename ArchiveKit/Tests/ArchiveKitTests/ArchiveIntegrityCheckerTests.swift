// AI-Generated | 可修改
// ArchiveIntegrityCheckerTests —— 完整性检查单测(2026-09-17 新增功能)
// ----------------------------------------------------------------------------
// fixture 定位方式与 ArchiveDocumentTests 相同(#filePath 回溯源码树)。
//
// 这组用例守的核心是**结论的诚实性**:「没查到损坏」和「查到没有损坏」是两件事。
// 相应的三种结论各有专属用例(干净 / 有坏页 / 没跑完),外加一条容易写错的:
// **加密页不算损坏** —— 把它算进去,每个部分加密包一检查就报红,
// 而用户其实只需要输个密码。
import XCTest
@testable import ArchiveKit

final class ArchiveIntegrityCheckerTests: XCTestCase {

    private enum Fixtures {
        static let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")

        static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    }

    /// 可变计数盒子。检查器的回调是 `@Sendable`,而 Swift 6 不允许闭包捕获
    /// 可变的局部变量 —— 于是「计数」这件事只能自己带一把锁
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        var all: [Int] {
            lock.lock(); defer { lock.unlock() }
            return values
        }

        var last: Int? { all.last }

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
    }

    // MARK: - 干净

    /// 明文包:3 页全通 —— 只有这时才允许说「没有发现损坏」
    func testIntactArchiveReportsNoDamage() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let report = ArchiveIntegrityChecker.check(document: doc)

        XCTAssertEqual(report.pages, 3)
        XCTAssertEqual(report.checked, 3)
        XCTAssertEqual(report.damagedCount, 0)
        XCTAssertTrue(report.damagedPages.isEmpty)
        XCTAssertEqual(report.skippedEncrypted, 0)
        XCTAssertFalse(report.stoppedEarly)
        XCTAssertTrue(report.isIntact, "完整检查 + 零坏页 才算 intact")
    }

    // MARK: - 有坏页

    /// 单页数据损坏(damaged-page.cbz:目录完好,page2 负载被翻一字节)。
    /// 三条一起断言,缺一条这个功能就不可信:
    ///   ① 目录照常列出 3 页(损坏只在数据段,别把整包判死);
    ///   ② 坏页被**精确定位**到索引 1;
    ///   ③ 坏页**之后**的页仍读通 —— 这是「坏页必须重开扫描器」的直接证据
    ///      (不重开的话流位置已坏,page10 会跟着报错,报告就成了假结论)
    func testSingleDamagedPageIsLocatedAndFollowingPageStillReads() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("damaged-page.cbz"))
        XCTAssertEqual(doc.entries.count, 3, "目录本身完好")

        let report = ArchiveIntegrityChecker.check(document: doc)

        XCTAssertEqual(report.damagedPages, [1], "坏页应精确定位到第 2 页(索引 1)")
        XCTAssertEqual(report.damagedCount, 1)
        XCTAssertEqual(report.checked, 2, "page1 与 page10 应读通")
        XCTAssertFalse(report.stoppedEarly)
        XCTAssertFalse(report.isIntact)
    }

    /// 坏页清单有条数上限,但**真实总数**必须如实报 ——
    /// 悄悄截断会让人以为「就坏了这几个」
    func testDamagedListIsCappedButCountIsHonest() throws {
        // 单页损坏的样本只有 1 个坏页,证不了截断;这里锁的是「上限存在且
        // 与计数分离」这条结构:上限值必须为正,否则清单永远是空的
        XCTAssertGreaterThan(ArchiveIntegrityReport.damagedPageLimit, 0)
        let doc = try ArchiveDocument.open(url: Fixtures.url("damaged-page.cbz"))
        let report = ArchiveIntegrityChecker.check(document: doc)
        XCTAssertLessThanOrEqual(report.damagedPages.count, report.damagedCount,
                                 "清单永远不会比真实总数长")
    }

    // MARK: - 加密页 ≠ 损坏

    /// 部分加密包未给密码:2 页明文读通、2 页加密**跳过**。
    /// 这条是「别让加密包一检查就报红」的守门用例
    func testEncryptedPagesAreSkippedNotCountedAsDamage() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"))
        let report = ArchiveIntegrityChecker.check(document: doc)

        XCTAssertEqual(report.pages, 4)
        XCTAssertEqual(report.skippedEncrypted, 2)
        XCTAssertEqual(report.checked, 2)
        XCTAssertEqual(report.damagedCount, 0)
        XCTAssertTrue(report.isIntact, "加密页不是坏页 —— 报告应保持干净")
    }

    /// 带上正确密码 → 加密页也算进来,不再有跳过项
    func testWithPassphraseEncryptedPagesAreCheckedAsWell() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"), passphrase: "secret")
        let report = ArchiveIntegrityChecker.check(document: doc)

        XCTAssertEqual(report.skippedEncrypted, 0)
        XCTAssertEqual(report.checked, 4)
        XCTAssertTrue(report.isIntact)
    }

    // MARK: - 没跑完

    /// 取消:必须报 `stoppedEarly`,而且**不能**报 intact ——
    /// 把「没查到」当成「查到没有」是这类功能最容易犯的错
    func testCancellationReportsStoppedEarlyRatherThanIntact() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let seen = Box()

        let report = ArchiveIntegrityChecker.check(
            document: doc,
            isCancelled: { (seen.last ?? 0) >= 1 },
            onProgress: { seen.append($0) })

        XCTAssertTrue(report.stoppedEarly)
        XCTAssertFalse(report.isIntact, "没跑完绝不能报「没有损坏」")
        XCTAssertEqual(report.lastCheckedPage, 0, "第一页查完就被叫停")
        XCTAssertLessThan(report.lastCheckedPage + 1, report.pages)
    }

    // MARK: - 进度

    /// 每检查完一页回调一次,值从 1 递增到总页数
    func testProgressIsReportedOncePerPage() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let samples = Box()

        _ = ArchiveIntegrityChecker.check(document: doc,
                                         onProgress: { samples.append($0) })

        XCTAssertEqual(samples.all, [1, 2, 3])
    }
}
