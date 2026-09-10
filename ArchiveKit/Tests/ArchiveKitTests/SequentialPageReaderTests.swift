// AI-Generated | 可修改
// SequentialPageReaderTests —— 单实例顺序扫描器单测(设计文档 §5.1 硬约束)
// ----------------------------------------------------------------------------
// 断言策略(对齐 §6.2「断言落在语义上」):
//   · 正确性:任意访问顺序的结果 == ArchiveDocument.data(at:)(同一真源的两种
//     实现必须逐字节一致)——这是「顺序扫描器只是换了访问模式,没换语义」的锁;
//   · 字节级 ground truth:与 src/ 源图对拍(Fixtures 同款模式);
//   · 加密页:抛对错误 case,且**扫描器没坏** —— 后续明文页照常可读
//     (§5.9.4 约束 4「单页失败 ≠ 整档失败」在顺序扫描器上的直接推论);
//   · 越界:抛错不崩。
// 注意:struct archive 非线程安全 → 并发共享场景归 PageStore actor 的职责
// (单测在单一 Task 内串行调用,与真实用法一致)。
import XCTest
@testable import ArchiveKit

final class SequentialPageReaderTests: XCTestCase {

    /// fixture 目录:…/ArchiveKit/Tests/Fixtures(与 ArchiveDocumentTests 同款定位)
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

    // MARK: - 前向顺序访问(连续翻页的主路径)

    /// 全前向 0→1→2 与 data(at:) 及源图逐字节一致 —— 顺序扫描的语义等价性
    func testForwardSequentialReadsMatchDataAtAndSource() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let reader = SequentialPageReader(document: doc)

        for index in doc.entries.indices {
            let scanned = try reader.data(at: index)
            XCTAssertEqual(scanned, try doc.data(at: index),
                           "第 \(index) 页:顺序扫描与 data(at:) 结果必须一致")
            XCTAssertEqual(scanned, try Fixtures.srcData(doc.entries[index].path),
                           "第 \(index) 页:与源图 ground truth 一致")
        }
        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
    }

    /// 明文 cbt(tar)全前向往返 —— 扫描器对非 zip 格式同样成立
    func testForwardSequentialReadsTarFixture() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbt"))
        let reader = SequentialPageReader(document: doc)

        for index in doc.entries.indices {
            XCTAssertEqual(try reader.data(at: index),
                           try Fixtures.srcData(doc.entries[index].path))
        }
    }

    // MARK: - 后向 / 乱序访问(重开重建分支)

    /// 读尾页再回头:流不能回头 → 内部重开重建,结果仍必须正确。
    /// 2 → 0 → 1 → 2 覆盖「后向、后向、原地重读」三种重建触发
    func testBackwardAndRepeatedReadsStayCorrect() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let reader = SequentialPageReader(document: doc)

        let last = doc.entries.count - 1
        XCTAssertEqual(try reader.data(at: last), try Fixtures.srcData("page10.png"))
        XCTAssertEqual(try reader.data(at: 0), try Fixtures.srcData("page1.png"))
        XCTAssertEqual(try reader.data(at: 1), try Fixtures.srcData("page2.png"))
        XCTAssertEqual(try reader.data(at: last), try Fixtures.srcData("page10.png"),
                       "原地重读走重建分支,结果不许漂移")
    }

    /// 乱序访问矩阵(模拟用户跳页):与 data(at:) 全对拍
    func testRandomAccessOrderMatchesDataAt() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let reader = SequentialPageReader(document: doc)
        let order = [2, 0, 2, 1, 0]

        for index in order {
            XCTAssertEqual(try reader.data(at: index), try doc.data(at: index),
                           "乱序读第 \(index) 页:与 data(at:) 必须一致")
        }
    }

    // MARK: - 加密页(前置拦截不破坏扫描器)

    /// partial.cbz:page1/2 明文 + page3/4 ZipCrypto。
    /// 加密页抛 .encrypted(v1 无密码框);随后明文页(含后向重建)照常可读 ——
    /// 证明加密失败没有把扫描器/流位置弄坏
    func testEncryptedPageThrowsAndReaderSurvives() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"))
        XCTAssertEqual(doc.protection, .partial(encryptedCount: 2))
        let reader = SequentialPageReader(document: doc)

        // 明文页正常
        XCTAssertEqual(try reader.data(at: 0), try Fixtures.srcData("page1.png"))

        // 加密页(page3/page4)→ .encrypted,不崩
        XCTAssertThrowsError(try reader.data(at: 2)) { error in
            XCTAssertEqual(error as? ArchiveError, .encrypted)
        }

        // 扫描器幸存:前向到 page2、后向重建回 page1 都正常
        XCTAssertEqual(try reader.data(at: 1), try Fixtures.srcData("page2.png"))
        XCTAssertEqual(try reader.data(at: 0), try Fixtures.srcData("page1.png"))

        // page4 同样是加密 → 同一错误分流
        XCTAssertThrowsError(try reader.data(at: 3)) { error in
            XCTAssertEqual(error as? ArchiveError, .encrypted)
        }
    }

    // 注:7z 加密页在扫描器层不可达 —— 现有 7z fixture(encrypted-content.cb7)
    // 是**全部加密**,open 阶段即抛终局态 .encryptedUnsupportedFormat,
    // 轮不到 SequentialPageReader 读页(该行为已由 ArchiveDocumentTests 覆盖)。
    // 扫描器层的加密页分流由 partial.cbz(zip)用例验证:同一 encryptionError
    // 分流函数,zip 分支对了,.sevenZip/.rar 分支是同一个函数的不同输入。

    // MARK: - 越界与生命周期

    /// 越界抛错不 trap(§5.9.4「绝不闪退」);close 后再用自动重开不崩
    func testOutOfRangeThrowsAndReaderReusableAfterClose() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let reader = SequentialPageReader(document: doc)

        XCTAssertThrowsError(try reader.data(at: -1))
        XCTAssertThrowsError(try reader.data(at: doc.entries.count))

        // close → 复用:重开重建,结果正确(行为兜底,虽然调用方应直接丢弃)
        reader.close()
        XCTAssertEqual(try reader.data(at: 0), try Fixtures.srcData("page1.png"))
    }
}
