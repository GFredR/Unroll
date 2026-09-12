// AI-Generated | 可修改
// CrashReporterTests —— L0 崩溃采集与自愿上报(M4 §5.10.3-②③ / §5.10.4)
// ----------------------------------------------------------------------------
// 每个用例都在临时目录里模拟「两次进程」:上一次会话写标记 → 不正常退出(或不退出)
// → 下一次会话 beginSession 自检。**不碰真实 App Support**。
import XCTest
@testable import Unroll

final class CrashReporterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeReporter(version: String = "1.0.0") -> CrashReporter {
        CrashReporter(directory: directory,
                      breadcrumbs: Breadcrumbs(directory: directory),
                      version: version,
                      build: "1")
    }

    /// 模拟「上一次会话」:本次用独立的 Breadcrumbs 实例,好让调用方能自己写轨迹
    private func makeSession(version: String = "1.0.0") -> (CrashReporter, Breadcrumbs) {
        let crumbs = Breadcrumbs(directory: directory)
        let reporter = CrashReporter(directory: directory,
                                     breadcrumbs: crumbs,
                                     version: version,
                                     build: "1")
        return (reporter, crumbs)
    }

    // MARK: - 正常退出 → 不误报

    func testCleanExitLeavesNoReport() {
        let (first, _) = makeSession()
        XCTAssertFalse(first.beginSession())
        first.endSession()

        let second = makeReporter()
        XCTAssertFalse(second.beginSession(), "⌘Q 正常退出后不该判定异常退出")
        XCTAssertNil(second.pendingReport())
    }

    // MARK: - 异常退出 → 检出 + 有报告

    func testUncleanExitIsDetectedWithReport() throws {
        // 上次会话:开始 → 记轨迹 → 崩溃(故意不调用 endSession)
        let (crashed, crumbs) = makeSession()
        crashed.beginSession()
        crumbs.record(.openArchive(format: "zip", sizeBucket: "sz_50_200MB"))
        crumbs.record(.indexBuilt(pages: 128))
        crumbs.record(.pageDecode(index: 97))

        let next = makeReporter()
        XCTAssertTrue(next.beginSession(), "残留 alive = true 应判定为上次异常退出")

        let report = try XCTUnwrap(next.pendingReport())
        XCTAssertEqual(report.appVersion, "1.0.0")
        XCTAssertEqual(report.summary.format, "zip")
        XCTAssertEqual(report.summary.sizeBucket, "sz_50_200MB")
        XCTAssertEqual(report.summary.pages, 128)
        XCTAssertEqual(report.summary.lastPage, 97)
        // beginSession 自己会记一条 appLaunched,所以是 1 + 调用方写的 3 条
        XCTAssertEqual(report.breadcrumbs.map(\.e),
                       ["appLaunched", "openArchive", "indexBuilt", "pageDecode"])
        XCTAssertTrue(report.body.contains("pageDecode"))
        XCTAssertFalse(report.osVersion.isEmpty)
        XCTAssertFalse(report.arch.isEmpty)
    }

    /// 刚启动就崩溃:没有任何会话事实,也要能产出报告(不能因为摘要为空就崩)
    func testCrashRightAfterLaunchStillReports() throws {
        let (crashed, _) = makeSession()
        crashed.beginSession()

        let next = makeReporter()
        XCTAssertTrue(next.beginSession())

        let report = try XCTUnwrap(next.pendingReport())
        XCTAssertEqual(report.summary, CrashReporter.Summary())
        XCTAssertNotNil(report.issueURL)
    }

    /// 误报兜底:`kern.boottime` 对不上 = 系统重启过,不算崩溃(§5.10.3-②)
    func testSystemRebootSuppressesReport() throws {
        let stale = CrashReporter.SessionRecord(alive: true,
                                                version: "1.0.0",
                                                build: "1",
                                                bootTime: CrashReporter.bootTime() - 10_000,
                                                suppressedVersion: nil)
        try JSONEncoder().encode(stale).write(to: directory.appendingPathComponent("session.json"))

        let reporter = makeReporter()
        XCTAssertFalse(reporter.beginSession(), "系统重启过就不该判定异常退出")
        XCTAssertNil(reporter.pendingReport())
    }

    func testBootTimeIsPlausible() {
        let boot = CrashReporter.bootTime()
        XCTAssertGreaterThan(boot, 1_500_000_000)                     // 晚于 2017-07
        XCTAssertLessThan(boot, Date().timeIntervalSince1970)
    }

    // MARK: - 免打扰(拒绝后同版本不再询问)

    func testDecliningStopsAskingForSameVersion() {
        let (crashed, _) = makeSession()
        crashed.beginSession()
        // 崩溃

        let second = makeReporter()
        XCTAssertTrue(second.beginSession())
        second.clearPending(suppress: true)      // 用户点「不再询问」

        let third = makeReporter()
        XCTAssertFalse(third.beginSession(), "同版本已拒绝过,不再询问")
        XCTAssertNil(third.pendingReport())
    }

    func testNewVersionAsksAgain() {
        let (crashed, _) = makeSession()
        crashed.beginSession()

        let second = makeReporter()
        XCTAssertTrue(second.beginSession())
        second.clearPending(suppress: true)

        let third = makeReporter(version: "1.0.1")
        XCTAssertTrue(third.beginSession(), "换版本了,应重新询问一次")
    }

    /// 用户点了「查看报告」:清标记但不记免打扰,下次仍会问
    func testSubmittingClearsPendingWithoutSuppressing() {
        let (crashed, _) = makeSession()
        crashed.beginSession()

        let second = makeReporter()
        XCTAssertTrue(second.beginSession())
        second.clearPending(suppress: false)
        XCTAssertNil(second.pendingReport())

        let third = makeReporter()
        XCTAssertTrue(third.beginSession())
    }

    // MARK: - 隐私红线(§5.10.4):草稿里不得有文件名 / 路径

    func testIssueDraftContainsNoFileNameOrPath() throws {
        let (crashed, crumbs) = makeSession()
        crashed.beginSession()
        crumbs.record(.openArchive(format: "cbz", sizeBucket: "sz_50_200MB"))
        crumbs.record(.indexBuilt(pages: 128))
        crumbs.record(.pageDecode(index: 12))

        let next = makeReporter()
        XCTAssertTrue(next.beginSession())
        let report = try XCTUnwrap(next.pendingReport())
        let url = try XCTUnwrap(report.issueURL)
        let encoded = url.absoluteString

        // 只允许出现「公开仓库 + 允许字段」,不得出现任何用户文件信息
        XCTAssertTrue(encoded.hasPrefix("https://github.com/GFredR/Unroll/issues/new"))
        XCTAssertTrue(encoded.contains("labels=crash"))
        XCTAssertTrue(encoded.contains("1.0.0"))
        XCTAssertFalse(encoded.contains("Users"))
        XCTAssertFalse(report.body.contains("/Users/"))
        XCTAssertFalse(report.body.contains(".cbz"))
        // 面包屑轨迹会原样进正文(那正是报告的主体)。桶标记出现在轨迹里是预期内的,
        // 关键是它只能是「格式:桶」这种短标签,永远夹带不了路径 / 文件名
        XCTAssertTrue(report.body.contains("cbz:sz_50_200MB"))
        XCTAssertTrue(report.body.contains("50–200 MB"))
        XCTAssertTrue(report.body.contains("openArchive"))
    }
}
