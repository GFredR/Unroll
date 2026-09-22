// AI-Generated | 可修改
// BreadcrumbsTests —— 崩溃面包屑(M4 §5.10.3-① / §5.10.4)
// ----------------------------------------------------------------------------
// 全部用**临时目录**注入,不碰真实 App Support(测试不留痕);
// 隐私红线的断言是硬性的:落盘内容里不得出现任何路径 / 文件名特征。
import ArchiveKit
import XCTest
@testable import Unroll

final class BreadcrumbsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-crumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBreadcrumbs(limit: Int = 20, maxBytes: Int = 4096) -> Breadcrumbs {
        Breadcrumbs(directory: directory, limit: limit, maxBytes: maxBytes)
    }

    private var logURL: URL { directory.appendingPathComponent("breadcrumbs.log") }

    // MARK: - 记录与顺序

    func testRecordsEventsInOrder() {
        let crumbs = makeBreadcrumbs()
        crumbs.record(.appLaunched)
        crumbs.record(.openArchive(format: "zip", sizeBucket: "sz_50_200MB"))
        crumbs.record(.pageDecode(index: 7))

        let snapshot = crumbs.snapshot()
        XCTAssertEqual(snapshot.map(\.e), ["appLaunched", "openArchive", "pageDecode"])
        XCTAssertNil(snapshot.first?.v)
        XCTAssertEqual(snapshot[1].v, "zip:sz_50_200MB")
        XCTAssertEqual(snapshot.last?.v, "7")
    }

    func testRingBufferKeepsNewestTwenty() {
        let crumbs = makeBreadcrumbs()
        for index in 0..<30 { crumbs.record(.pageDecode(index: index)) }

        let snapshot = crumbs.snapshot()
        XCTAssertEqual(snapshot.count, 20)
        XCTAssertEqual(snapshot.first?.v, "10")   // 最旧的 10 条被挤掉
        XCTAssertEqual(snapshot.last?.v, "29")
    }

    /// 连续重复事件折叠,别把 20 条额度刷光
    func testConsecutiveDuplicatesCollapse() {
        let crumbs = makeBreadcrumbs()
        crumbs.record(.pageDecode(index: 3))
        crumbs.record(.pageDecode(index: 3))
        XCTAssertEqual(crumbs.snapshot().count, 1)
    }

    // MARK: - 落盘(崩溃时内存会丢,必须实时落盘)

    func testPersistsAndReloads() {
        let crumbs = makeBreadcrumbs()
        crumbs.record(.appLaunched)
        crumbs.record(.indexBuilt(pages: 128))

        let reloaded = Breadcrumbs.read(from: directory)
        XCTAssertEqual(reloaded.map(\.e), ["appLaunched", "indexBuilt"])
        XCTAssertEqual(reloaded.last?.v, "128")
    }

    func testClearRemovesBothMemoryAndFile() {
        let crumbs = makeBreadcrumbs()
        crumbs.record(.appLaunched)
        crumbs.clear()

        XCTAssertTrue(crumbs.snapshot().isEmpty)
        XCTAssertTrue(Breadcrumbs.read(from: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testFileStaysUnderByteCap() {
        let crumbs = makeBreadcrumbs(maxBytes: 512)
        for index in 0..<200 { crumbs.record(.pageDecode(index: index)) }

        let size = (try? Data(contentsOf: logURL))?.count ?? 0
        XCTAssertLessThanOrEqual(size, 512)
        XCTAssertFalse(Breadcrumbs.read(from: directory).isEmpty, "截尾后仍应保留最新若干条")
    }

    // MARK: - 隐私红线(§5.10.4)

    func testSanitizeRejectsPathsAndFileNames() {
        XCTAssertNil(Breadcrumbs.sanitize("/Users/someone/secret.cbz"))
        XCTAssertNil(Breadcrumbs.sanitize("secret.cbz"))
        XCTAssertNil(Breadcrumbs.sanitize("My Comic 01.cbz"))
        XCTAssertNil(Breadcrumbs.sanitize("~"))
        XCTAssertNil(Breadcrumbs.sanitize(""))
        XCTAssertNil(Breadcrumbs.sanitize(String(repeating: "a", count: 25)))
        XCTAssertEqual(Breadcrumbs.sanitize("zip:sz_50_200MB"), "zip:sz_50_200MB")
        XCTAssertEqual(Breadcrumbs.sanitize("128"), "128")
    }

    /// 落盘文件里不得出现任何路径 / 文件名特征(防未来重构把值换成自由文本)
    func testPersistedFileNeverContainsPathLikeValue() {
        let crumbs = makeBreadcrumbs()
        crumbs.record(.appLaunched)
        crumbs.record(.pageDecode(index: 3))
        crumbs.record(.openArchive(format: "zip", sizeBucket: "sz_50_200MB"))

        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertFalse(text.contains(".cbz"))
        XCTAssertFalse(text.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    /// 批量导出事件(2026-09-21)的标签必须**真的落得下去**。
    ///
    /// 这一条与上面的隐私断言是**反方向**的:值被 `sanitize` 悄悄丢掉时,隐私守卫
    /// 照样全绿(文件里确实没有路径),但诊断线索也没了 —— 那是「守卫的第二种失效」。
    /// 所以四个停止标签都要逐个验一遍:它们是 `PageSequenceStop.token` 的产物,
    /// 而 `sinkStopped` 这种驼峰长词就在白名单边缘上
    func testExportEventsSurviveThePrivacyGate() {
        let crumbs = makeBreadcrumbs()
        crumbs.record(.pageExportStarted(pages: 421))
        crumbs.record(.pageExportFinished(written: 420,
                                          stop: PageSequenceStop.sinkStopped.token))

        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("\"v\":\"421\""), "开始事件的页数必须落得下去")
        XCTAssertTrue(text.contains("420:sinkStopped"),
                      "结束事件的值必须落得下去 —— 被 sanitize 丢掉的话诊断线索就没了")
        XCTAssertFalse(text.contains("/Users"))

        for stop in [PageSequenceStop.finished, .cancelled, .sinkStopped, .stalled] {
            XCTAssertEqual(Breadcrumbs.sanitize(stop.token), stop.token,
                           "\(stop.token) 过不了隐私闸门,导出事件会静默变成空值")
        }
    }

    func testSizeBucketBoundaries() {
        XCTAssertEqual(Breadcrumbs.sizeBucket(bytes: -1), "sz_unknown")
        XCTAssertEqual(Breadcrumbs.sizeBucket(bytes: 0), "sz_lt50MB")
        XCTAssertEqual(Breadcrumbs.sizeBucket(bytes: 49_999_999), "sz_lt50MB")
        XCTAssertEqual(Breadcrumbs.sizeBucket(bytes: 50_000_000), "sz_50_200MB")
        XCTAssertEqual(Breadcrumbs.sizeBucket(bytes: 199_999_999), "sz_50_200MB")
        XCTAssertEqual(Breadcrumbs.sizeBucket(bytes: 200_000_000), "sz_gt200MB")
    }
}
