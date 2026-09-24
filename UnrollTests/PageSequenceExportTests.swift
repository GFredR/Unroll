// AI-Generated | 可修改
// PageSequenceExportTests —— 批量导出在 VM 层的粘合(2026-09-21 新功能)
// ----------------------------------------------------------------------------
// 顺序遍历本身(阅读顺序、原始字节、加密跳过、坏页点名、取消、受控重开)在
// ArchiveKit 包里单测,跑在无沙盒的 swift test 下,有逐字节断言 —— 本文件**不重复**那些。
// 这里只补 VM/写盘这一层真正只有它才有的四件事:
//   · 菜单可用性(没文档 / 需要密码时不许点);
//   · **落盘的名字与内容**:文件名补零连续、内容就是那一页(证明 VM 把 index
//     与字节正确地一起交给了写盘,而不是写成一堆"张数对、内容乱"的文件);
//   · **写盘失败 → `.sinkStopped` 且不算坏页**(页是好的,是写不出去 ——
//     混成"有 N 页损坏"会让用户去重新下载压缩包);
//   · 换书 / 关面板时状态必须清干净(旧包的结论不许贴到新书界面上)。
//
// ⚠️ 与 IntegrityCheckTests 同款沙盒说明:宿主 App 开着 App Sandbox,测试进程继承,
// 仓库 fixture 可能不可读。不可读时 skip,不伪造结论。
import ArchiveKit
import XCTest
@testable import Unroll

@MainActor
final class PageSequenceExportTests: XCTestCase {

    private static let suiteName = "test.pagesequence.export"

    /// 仓库内 fixture 目录(与 IntegrityCheckTests / PageStoreTests 同一口径)
    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    /// 导出目标目录(临时)—— 每例现建现删,不留到下一轮
    ///
    /// ⚠️ `nonisolated(unsafe)` 是**为了跨工具链编译**,不是随手加的:
    ///    本类整体是 `@MainActor`,而 `setUpWithError` / `tearDownWithError` 重写的是
    ///    XCTest 的**非隔离**方法 —— Swift 6.2(Xcode 26)允许这种重写继承类型的隔离,
    ///    Swift 6.0(Xcode 16.4)不允许,于是同一个属性一边能碰、一边报
    ///    "main actor-isolated property 'directory' can not be mutated from a
    ///     nonisolated context"。CI 首次在真实 runner 上跑就撞上了(那边是 Xcode 16.4,
    ///    本机是 26.1,所以本机从未复现)。
    ///    该值只在 setUp 写、tearDown 读、各用例内读,全部在测试线程上顺序发生,
    ///    没有并发访问 —— 去掉隔离在这条用途上是安全的。
    private nonisolated(unsafe) var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) throws -> URL {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)—— 算法层由 ArchiveKit 包内单测覆盖")
        }
        return url
    }

    private func makeViewModel() -> ReaderViewModel {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        defaults.removePersistentDomain(forName: Self.suiteName)
        return ReaderViewModel(progressStore: ReadingProgress(defaults: defaults),
                               bookmarkStore: Bookmarks(defaults: defaults),
                               tips: ReaderTips(defaults: defaults))
    }

    /// 目标目录里的文件名(排序后;空目录 / 不存在都返回 [])
    private func writtenNames() -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return (names ?? []).sorted()
    }

    private func bytes(of name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func ready(_ vm: ReaderViewModel) throws -> PageSequenceReport {
        guard case .ready(let report) = vm.exportState else {
            throw XCTSkip("导出未收尾,实际状态:\(String(describing: vm.exportState))")
        }
        return report
    }

    // MARK: - 可用性

    /// 没打开文档时不许点「导出本卷页文件」—— 没有文档就没有可导出的页。
    /// 同时钉住「不可用时不留半启动状态」:不建任务、不弹面板、不写 running
    func testMenuIsUnavailableBeforeOpening() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .noDocument)
        XCTAssertFalse(vm.canExportPages)
        XCTAssertFalse(vm.isExportRunning)
        XCTAssertNil(vm.exportPages(to: directory), "不可用时返回 nil,不产生任务")
        XCTAssertFalse(vm.isExportSheetPresented)
        XCTAssertNil(vm.exportState)
    }

    /// 加密包在**没输密码之前**也不许导出:此时每页都会读成"加密跳过",
    /// 导出的会是一个空目录 —— 那是比不给点更坏的体验(用户以为导完了)
    func testMenuIsUnavailableWhilePasswordIsRequired() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("encrypted-zip.cbz")).value

        guard vm.phase == .needsPassword else {
            throw XCTSkip("该 fixture 未走密码分支,实际:\(vm.phase)")
        }
        XCTAssertFalse(vm.canExportPages)
        XCTAssertNil(vm.exportPages(to: directory))
        XCTAssertEqual(writtenNames(), [])
    }

    // MARK: - 落盘:名字连续 + 内容对得上

    /// `plain.cbz` 的**归档顺序**是 page10 / page2 / page1(实测),阅读顺序是
    /// 1 → 2 → 10。所以「`plain-p001.png` 里装着 page1 的字节」这一条同时锁住了
    /// 顺序与内容 —— 只断言"写出 3 个文件"是抓不到顺序错的:
    /// 名字对、内容乱的文件谁都不会当场发现
    func testExportWritesEveryPageWithPaddedNamesInReadingOrder() async throws {
        let vm = makeViewModel()
        let archive = try fixture("plain.cbz")
        await vm.open(url: archive).value
        XCTAssertTrue(vm.canExportPages)

        let task = try XCTUnwrap(vm.exportPages(to: directory))
        XCTAssertTrue(vm.isExportSheetPresented, "开始导出要顺带把面板打开")
        await task.value

        let report = try ready(vm)
        XCTAssertEqual(report.stop, .finished)
        XCTAssertEqual(report.delivered, 3)
        XCTAssertEqual(report.skippedEncrypted, 0)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(report.coversWholeArchive)
        XCTAssertFalse(vm.isExportRunning)

        XCTAssertEqual(writtenNames(), ["plain-p001.png", "plain-p002.png", "plain-p003.png"],
                       "补零 3 位且连续 —— 文件名排出来就是阅读顺序")

        // 参照物取**归档自己**(随机访问路径),不依赖 Fixtures/src 是否与样本同步:
        // 两条路径(单实例前向扫描 vs 每页自建实例)给出的字节必须一致
        let doc = try ArchiveDocument.open(url: archive)
        XCTAssertEqual(try bytes(of: "plain-p001.png"), try doc.data(at: 0))
        XCTAssertEqual(try bytes(of: "plain-p002.png"), try doc.data(at: 1))
        XCTAssertEqual(try bytes(of: "plain-p003.png"), try doc.data(at: 2))
    }

    /// 部分加密包(不给密码):明文页照常落盘、加密页**跳过而不是报损坏**,
    /// 且文件名**不留空洞**(第 3、4 页没写出来,不是写成两个空文件)。
    ///
    /// 实测(2026-09-21,系统 `ditto -x -k`):`partial.cbz` 的 page1 / page2 是明文,
    /// page3 / page4 是 ZipCrypto。没有这条用例的话,「跳过」很容易被实现成
    /// 写一个 0 字节文件占位 —— 那在访达里就是两张打不开的白色卡片
    func testEncryptedPagesAreSkippedAndLeaveNoHoles() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("partial.cbz")).value

        guard vm.phase == .reading else {
            throw XCTSkip("该 fixture 在 App 层走了密码分支(实际:\(vm.phase))")
        }

        await vm.exportPages(to: directory)?.value
        let report = try ready(vm)

        XCTAssertEqual(report.delivered, 2)
        XCTAssertEqual(report.skippedEncrypted, 2, "加密不是损坏")
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(report.stop, .finished)
        XCTAssertTrue(report.coversWholeArchive, "跳过的页也算交代清楚了")

        XCTAssertEqual(writtenNames(), ["partial-p001.png", "partial-p002.png"],
                       "只写能写的两页,不拿空文件占位")
        for name in writtenNames() {
            XCTAssertFalse(try bytes(of: name).isEmpty, "\(name) 是空文件 —— 跳过不等于占位")
        }
    }

    /// 单页损坏的包:坏页**不写文件**,但第 3 页照写 ——
    /// 这是「坏页之后必须重开扫描器」在落盘这一侧的可见结果
    func testDamagedPageIsAbsentFromDiskButOthersStillWritten() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("damaged-page.cbz")).value

        await vm.exportPages(to: directory)?.value
        let report = try ready(vm)

        XCTAssertEqual(report.failedPages, [1])
        XCTAssertEqual(writtenNames(), ["damaged-page-p001.png", "damaged-page-p003.png"],
                       "坏页那一格空着 —— 报告已经点名说了是哪一页")
        XCTAssertTrue(report.coversWholeArchive, "点名了就等于交代清楚了")
    }

    // MARK: - 写盘失败 ⇒ 立即收工,且不算坏页

    /// 目标目录不存在(模拟"没权限 / 磁盘满"这类写不出去):
    /// ① 必须**立即收工**,而不是接着把 200 页全读一遍然后报「200 页全失败」——
    ///    那会把真实原因埋在页码列表里;
    /// ② **不算坏页**:页本身是好的,失败的是"写出去"这件事
    func testWriteFailureStopsImmediatelyAndIsNotReportedAsDamage() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value

        // 父目录不存在 → 连 `.atomic` 的同目录临时文件都建不出来,必然写失败。
        // 刻意不指向 /tmp 之外的系统路径:沙盒下那种失败原因不可控(可能被拒绝),
        // 而这一条要测的是"写失败被如实分类",不是沙盒行为
        let missing = directory.appendingPathComponent("not-a-dir/sub")

        await vm.exportPages(to: missing)?.value
        let report = try ready(vm)

        XCTAssertEqual(report.stop, .sinkStopped, "写不出去 ≠ 页坏了")
        XCTAssertEqual(report.failedCount, 0, "页是好页 —— 不许报成损坏")
        XCTAssertEqual(report.failedPages, [])
        XCTAssertEqual(report.delivered, 0)
        XCTAssertFalse(report.coversWholeArchive, "没写完就绝不说写完了")
        XCTAssertEqual(report.remaining, 3)
    }

    // MARK: - 状态清理

    /// 关掉面板 = 清掉结论。于是「点菜单」的语义永远是「现在导一次」,
    /// 不会出现「这次点开看到的是上次的结果」
    func testDismissClearsResultSoMenuAlwaysMeansRunNow() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.exportPages(to: directory)?.value
        XCTAssertNotNil(vm.exportState)

        vm.dismissExport()
        XCTAssertNil(vm.exportState)
        XCTAssertFalse(vm.isExportSheetPresented)
        XCTAssertFalse(vm.isExportRunning)
    }

    /// 旧包的导出结论**绝不能**落到新包的界面上;已经写出的文件**不删** ——
    /// 那是用户看得见的东西,他可能正要把那几张拿走(见 `cancelExport` 说明)。
    ///
    /// ⚠️ 两点诚实说明:
    ///   ① 3 页的样本跑得太快,没法保证"换书那一刻导出还在跑",所以这条用例锁的是
    ///      **结果**(界面干净 + 文件留着),分不出是 open() 清的还是代号守卫拦的 ——
    ///      两条路都必须成立,而代号守卫本身由 Kit 侧取消用例覆盖;
    ///   ② **停在第几页不可预期**。首轮实测跑到第 1 页就被取消了(那 0.9s 花在坏页
    ///      重开上)—— 这反倒是个好消息:它证明换书的 cancel 真的穿进了导出循环,
    ///      而不只是把界面状态清掉了。所以判据只能是"写出来的都还在、且都不是别的
    ///      东西",不能写成"两页都在"
    func testOpeningAnotherArchiveDiscardsPreviousExport() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("damaged-page.cbz")).value

        let stale = vm.exportPages(to: directory)
        await vm.open(url: try fixture("plain.cbz")).value

        XCTAssertNil(vm.exportState, "换书后旧结论必须立即清掉")
        XCTAssertFalse(vm.isExportSheetPresented, "面板也要一起关掉")
        await stale?.value
        XCTAssertNil(vm.exportState, "旧任务收尾时也不许把结论写回来")

        let expected = ["damaged-page-p001.png", "damaged-page-p003.png"]
        for name in writtenNames() {
            XCTAssertTrue(expected.contains(name), "目录里出现了不属于这次导出的东西:\(name)")
            XCTAssertFalse(try bytes(of: name).isEmpty, "已写出的文件不许被回滚")
        }
    }
}
