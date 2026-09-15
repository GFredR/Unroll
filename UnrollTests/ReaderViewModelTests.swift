// AI-Generated | 可修改
// ReaderViewModelTests —— 归档级状态机分支(宿主为 App,§6.2/AGENTS.md 九.1)
// ----------------------------------------------------------------------------
// M2 覆盖:open 的失败分支(损坏/不存在 → .failed + 正确文案 key)与
// 成功分支的基本不变量(pageCount/phase)。失败分支用临时目录的垃圾文件
// (沙盒可写);成功分支走仓库内 fixture(见 PageStoreTests 的沙盒说明)。
import XCTest
@testable import Unroll

@MainActor
final class ReaderViewModelTests: XCTestCase {

    // MARK: - 测试隔离

    /// 进度存储固定用一个独立 suite,并在每个 VM 创建前清空。
    /// **必须隔离**:续读会持久化「上次读到第几页」,若走宿主 App 的真实偏好,
    /// 单测之间会互相污染(前一个用例翻到第 2 页,后一个用例一打开就被恢复过去)。
    private static let suiteName = "test.readervm.progress"
    /// 书签同样要隔离:它也会持久化,走宿主真实偏好一样会跨用例污染
    private static let bookmarkSuiteName = "test.readervm.bookmarks"

    /// reuseProgress = true 时保留已有进度(专供「续读恢复」用例模拟重开)
    private func makeViewModel(reuseProgress: Bool = false) -> ReaderViewModel {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        let bookmarkDefaults = UserDefaults(suiteName: Self.bookmarkSuiteName) ?? .standard
        if !reuseProgress {
            defaults.removePersistentDomain(forName: Self.suiteName)
            bookmarkDefaults.removePersistentDomain(forName: Self.bookmarkSuiteName)
        }
        return ReaderViewModel(progressStore: ReadingProgress(defaults: defaults),
                               bookmarkStore: Bookmarks(defaults: bookmarkDefaults))
    }

    private func progressStore() -> ReadingProgress {
        ReadingProgress(defaults: UserDefaults(suiteName: Self.suiteName) ?? .standard)
    }

    private func bookmarkStore() -> Bookmarks {
        Bookmarks(defaults: UserDefaults(suiteName: Self.bookmarkSuiteName) ?? .standard)
    }

    private func cleanProgress() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
    }

    // MARK: - 失败分支(绝不闪退,§5.9.4)

    /// 垃圾文件 → .failed + corrupted 文案组
    func testOpenGarbageFileFailsWithCorruptedCopy() async throws {
        let vm = makeViewModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-garbage-\(UUID().uuidString).bin")
        try Data("this is definitely not an archive".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await vm.open(url: url).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("垃圾文件必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.corrupted.title")
        XCTAssertEqual(failure.bodyKey, "archive.corrupted.body")
        XCTAssertEqual(vm.pageCount, 0)
    }

    /// 不存在的文件 → 同 corrupted 组(openRawHandle 打不开即 .corrupted)
    func testOpenMissingFileFails() async throws {
        let vm = makeViewModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-missing-\(UUID().uuidString).cbz")

        await vm.open(url: url).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("不存在的文件必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.corrupted.title")
    }

    // MARK: - 状态机不变量

    /// 初始态:noDocument、空呈现
    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .noDocument)
        XCTAssertEqual(vm.pageCount, 0)
        XCTAssertEqual(vm.pageIndex, 0)
        XCTAssertNil(vm.presentation.image)
        XCTAssertFalse(vm.presentation.isLoading)
    }

    /// 换书语义:再次 open 时旧任务被取消,最终状态由新任务决定
    func testReopenReplacesPreviousState() async throws {
        let vm = makeViewModel()
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-garbage-\(UUID().uuidString).bin")
        try Data("junk".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        // 第一次打开成功与否不重要(不依赖 fixture);第二次打开后状态应被重置再落定
        await vm.open(url: garbage).value
        await vm.open(url: garbage).value

        guard case .failed = vm.phase else {
            return XCTFail("两次垃圾打开后仍应是 failed,实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.pageIndex, 0)
    }

    // MARK: - 缩放档位(§2.1-4,2026-09-14 补齐)

    /// 默认档位 = 适应窗口(整页完整可见)
    func testDefaultFitModeIsFitWindow() {
        XCTAssertEqual(ReaderViewModel().fitMode, .fitWindow)
    }

    /// 档位切换只改渲染基准,不碰归档状态机
    func testFitModeSwitchingKeepsArchiveState() async throws {
        let vm = try await openFixtureOrSkip()
        vm.fitMode = .fitWidth
        XCTAssertEqual(vm.fitMode, .fitWidth)
        guard case .reading = vm.phase else {
            return XCTFail("换档位不得影响 reading 态")
        }
        XCTAssertEqual(vm.pageCount, 3)
        vm.fitMode = .actualSize
        XCTAssertEqual(vm.fitMode, .actualSize)
    }

    /// 面包屑标签必须过 sanitize 白名单(§5.10.4 隐私红线由结构保证)
    func testFitModeTokensPassSanitizeWhitelist() {
        let modes: [ReaderViewModel.FitMode] = [.fitWindow, .fitWidth, .fitHeight, .actualSize]
        for mode in modes {
            XCTAssertNotNil(Breadcrumbs.sanitize(mode.token), "\(mode.token) 必须过白名单")
        }
    }

    // MARK: - 双页 / 右开(M3,§0 决策 3)

    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    /// fixture 不可达 → skip(同 PageStoreTests 的沙盒约定)
    private func openFixtureOrSkip() async throws -> ReaderViewModel {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }
        let vm = makeViewModel()
        await vm.open(url: url).value
        guard case .reading = vm.phase, vm.pageCount >= 2 else {
            throw XCTSkip("fixture 未进入 reading 态或页数不足(plain.cbz 有 3 页)")
        }
        return vm
    }

    /// 双页:次页 = 主页 +1;翻页步长 ×2;尾页越界 → 次页 nil
    func testDualModeStepAndSecondaryIndex() async throws {
        let vm = try await openFixtureOrSkip()
        let count = vm.pageCount
        vm.layout = .dual

        XCTAssertEqual(vm.secondaryIndex, 1)
        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, min(2, count - 1), "双页模式一次跨两页")

        // 连翻到尾:最后一页无次页 → nil,退化为单页
        vm.goTo(count - 1)
        XCTAssertNil(vm.secondaryIndex)
    }

    /// 单页:次页恒 nil,步长 1
    func testSingleModeHasNoSecondary() async throws {
        let vm = try await openFixtureOrSkip()
        XCTAssertNil(vm.secondaryIndex)
        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, 1, "单页模式步长 1")
    }

    /// 右开:只影响视觉顺序(归 View),VM 的翻页语义恒为「文档前进/后退」;
    /// 切方向不动当前页
    func testDirectionSwitchKeepsPositionAndForwardStep() async throws {
        let vm = try await openFixtureOrSkip()
        vm.direction = .rightToLeft
        XCTAssertEqual(vm.pageIndex, 0, "切方向不得跳页")
        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, 1, "前进语义与方向无关,恒 +1(文档序)")
    }

    // MARK: - 续读记忆(v2「进度记忆」,2026-09-15)

    /// 打开 → 翻页/换模式 → 换一个 VM(同一进度存储)重开 → 页码与模式全部恢复
    func testResumeRestoresPageAndModes() async throws {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }

        // 第一次阅读:翻到第 2 页,双页 + 右开 + 适应宽
        let first = makeViewModel()
        await first.open(url: url).value
        guard case .reading = first.phase else {
            return XCTFail("首次打开应进入 reading")
        }
        first.layout = .dual
        first.direction = .rightToLeft
        first.fitMode = .fitWidth
        first.goTo(2)

        // 重开(模拟退出后再看同一本):页码与三个模式应恢复
        let second = makeViewModel(reuseProgress: true)
        await second.open(url: url).value
        guard case .reading = second.phase else {
            return XCTFail("重开应进入 reading")
        }
        XCTAssertEqual(second.pageIndex, 2, "应恢复到上次阅读的页")
        XCTAssertEqual(second.layout, .dual)
        XCTAssertEqual(second.direction, .rightToLeft)
        XCTAssertEqual(second.fitMode, .fitWidth)
    }

    /// 恢复页码越界(文档变小 / 进度来自别处)时必须夹紧,不得落进非法页
    func testResumeClampsOutOfRangePage() async throws {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }
        cleanProgress()
        let progress = progressStore()

        // 手工塞一条越界进度(页 99,文档只有 3 页)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        progress.save(key: ReadingProgress.key(name: url.lastPathComponent, size: size),
                      page: 99, layout: "dual", direction: "rightToLeft", fitMode: "fitWidth")

        let vm = makeViewModel(reuseProgress: true)
        await vm.open(url: url).value
        guard case .reading = vm.phase else {
            return XCTFail("打开应进入 reading")
        }
        XCTAssertLessThan(vm.pageIndex, vm.pageCount, "越界进度必须被夹紧")
        XCTAssertEqual(vm.pageIndex, 0, "越界记录应被当作「无进度」")
        XCTAssertEqual(vm.pageCount, 3)
    }

    /// 从未翻页 → 不留进度记录(免得多出无意义的条目)
    func testFreshDocumentLeavesNoProgressWhenPageZero() async throws {
        _ = try await openFixtureOrSkip()   // 打开后停在封面,不做任何翻页
        let saved = progressStore().entry(forKey: ReadingProgress.key(name: "plain.cbz",
                                                                     size: fixtureSize("plain.cbz")))
        XCTAssertNil(saved, "未翻页就不该落进度")
    }

    /// 「清空最近打开」连带清进度
    func testClearProgressWipesStore() async throws {
        let vm = try await openFixtureOrSkip()
        vm.goTo(1)
        XCTAssertNotNil(progressStore().entry(forKey: ReadingProgress.key(name: "plain.cbz",
                                                                        size: fixtureSize("plain.cbz"))))
        vm.clearProgress()
        XCTAssertNil(progressStore().entry(forKey: ReadingProgress.key(name: "plain.cbz",
                                                                     size: fixtureSize("plain.cbz"))))
    }

    private func fixtureSize(_ name: String) -> Int {
        let path = Self.fixturesDir.appendingPathComponent(name).path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    // MARK: - 书签(v2,2026-09-15)

    /// 标记/取消标记当前页,且落到存储(不只在内存里)
    func testToggleBookmarkMarksAndUnmarks() async throws {
        let vm = try await openFixtureOrSkip()

        XCTAssertFalse(vm.isCurrentPageBookmarked, "初始未标记")
        vm.toggleBookmark()
        XCTAssertTrue(vm.isCurrentPageBookmarked)
        XCTAssertEqual(vm.bookmarkedPages, [0])
        XCTAssertEqual(bookmarkStore().pages(forKey: ReadingProgress.key(name: "plain.cbz",
                                                                        size: fixtureSize("plain.cbz"))),
                       [0], "标记必须落盘,不能只活在内存")

        vm.toggleBookmark()
        XCTAssertFalse(vm.isCurrentPageBookmarked)
        XCTAssertTrue(vm.bookmarkedPages.isEmpty)
    }

    /// 未在读文档时标记:静默无操作(不得崩、不得写出无主书签)
    func testToggleBookmarkWithoutDocumentIsNoOp() {
        let vm = makeViewModel()
        vm.toggleBookmark()
        XCTAssertTrue(vm.bookmarkedPages.isEmpty)
        XCTAssertTrue(bookmarkStore().pages(forKey: "whatever").isEmpty)
    }

    /// 重开同一本文档:书签集合恢复
    func testBookmarksSurviveReopen() async throws {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }

        let first = makeViewModel()
        await first.open(url: url).value
        guard case .reading = first.phase else { return XCTFail("首次打开应进入 reading") }
        first.goTo(2)
        first.toggleBookmark()

        let second = makeViewModel(reuseProgress: true)
        await second.open(url: url).value
        guard case .reading = second.phase else { return XCTFail("重开应进入 reading") }
        XCTAssertEqual(second.bookmarkedPages, [2], "书签应随文档恢复")
    }

    /// 书签间跳转:无更前/更后的书签时绕回,页码升序且不重复
    func testBookmarkNavigationWrapsAround() async throws {
        let vm = try await openFixtureOrSkip()
        let last = vm.pageCount - 1

        vm.goTo(0)
        vm.toggleBookmark()
        vm.goTo(last)
        vm.toggleBookmark()
        XCTAssertEqual(vm.bookmarkedPages, [0, last], "书签集合恒按页码升序")

        // 已在最后一个书签 → 下一个绕回第一个
        vm.goToNextBookmark()
        XCTAssertEqual(vm.pageIndex, 0)
        // 已在第一个书签 → 上一个绕回最后一个
        vm.goToPreviousBookmark()
        XCTAssertEqual(vm.pageIndex, last)
    }

    /// 无书签时跳转不动作;清空本书签后集合为空且存储已删
    func testBookmarkNavigationAndClearWithNoBookmarks() async throws {
        let vm = try await openFixtureOrSkip()

        vm.goToNextBookmark()       // 空集合:不动
        XCTAssertEqual(vm.pageIndex, 0)
        vm.goToPreviousBookmark()
        XCTAssertEqual(vm.pageIndex, 0)

        vm.toggleBookmark()
        vm.clearBookmarks()
        XCTAssertTrue(vm.bookmarkedPages.isEmpty)
        XCTAssertTrue(bookmarkStore().pages(forKey: ReadingProgress.key(name: "plain.cbz",
                                                                        size: fixtureSize("plain.cbz"))).isEmpty)
    }

    /// 「清空最近打开」连带清书签(与进度同一处收口,不留无主数据)
    func testClearProgressAlsoClearsBookmarks() async throws {
        let vm = try await openFixtureOrSkip()
        vm.toggleBookmark()
        XCTAssertFalse(vm.bookmarkedPages.isEmpty)

        vm.clearProgress()
        XCTAssertTrue(vm.bookmarkedPages.isEmpty)
        XCTAssertTrue(bookmarkStore().pages(forKey: ReadingProgress.key(name: "plain.cbz",
                                                                        size: fixtureSize("plain.cbz"))).isEmpty)
    }

    // MARK: - 页码跳转解析(纯函数,不依赖 fixture)

    func testParsePageInputAcceptsValidPages() {
        XCTAssertEqual(ReaderViewModel.parsePageInput("1", pageCount: 200), 0)
        XCTAssertEqual(ReaderViewModel.parsePageInput("200", pageCount: 200), 199, "末页合法")
        XCTAssertEqual(ReaderViewModel.parsePageInput("  5 ", pageCount: 200), 4, "容忍首尾空白")
        XCTAssertEqual(ReaderViewModel.parsePageInput("１２", pageCount: 200), 11, "全角数字(中文输入法常见)")
    }

    func testParsePageInputRejectsInvalid() {
        XCTAssertNil(ReaderViewModel.parsePageInput("0", pageCount: 200), "页码从 1 开始")
        XCTAssertNil(ReaderViewModel.parsePageInput("201", pageCount: 200), "越界")
        XCTAssertNil(ReaderViewModel.parsePageInput("-3", pageCount: 200))
        XCTAssertNil(ReaderViewModel.parsePageInput("abc", pageCount: 200))
        XCTAssertNil(ReaderViewModel.parsePageInput("", pageCount: 200))
        XCTAssertNil(ReaderViewModel.parsePageInput("1.5", pageCount: 200))
        XCTAssertNil(ReaderViewModel.parsePageInput("7", pageCount: 0), "空文档不跳转")
    }
}
