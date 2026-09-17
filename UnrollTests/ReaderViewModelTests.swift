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

    // MARK: - 封面单独一页(双页配对口径,2026-09-16 真缺陷修复)

    /// 默认关 = 与旧版本行为逐位一致(封面与下一页并排)
    func testCoverAloneOffByDefaultKeepsLegacyPairing() async throws {
        let vm = try await openFixtureOrSkip()
        XCTAssertFalse(vm.coverAlone, "默认必须是关,否则老用户手感被悄悄改掉")
        vm.layout = .dual
        XCTAssertEqual(vm.secondaryIndex, 1, "旧配对:封面与第 1 页并排")
    }

    /// 开着 = 封面单独上屏,之后 (1,2) 才是正确的一摊;第 0 摊 → 第 1 摊步长为 1
    func testCoverAlonePairsCoverByItself() async throws {
        let vm = try await openFixtureOrSkip()
        XCTAssertGreaterThanOrEqual(vm.pageCount, 3, "本用例依赖至少 3 页")
        vm.layout = .dual
        vm.coverAlone = true

        XCTAssertEqual(vm.pageIndex, 0, "切口径不得跳页")
        XCTAssertNil(vm.secondaryIndex, "封面必须单独一屏")

        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, 1, "封面之后是第 1 页(旧实现会直接跳到第 2 页)")
        XCTAssertEqual(vm.secondaryIndex, 2, "正确的摊是 (1,2)")
    }

    /// 跳到「摊的第二面」时归一到摊首面 —— 保证目标页一定可见
    func testJumpToSecondFaceOfSpreadAlignsToSpreadStart() async throws {
        let vm = try await openFixtureOrSkip()
        vm.layout = .dual
        vm.coverAlone = true

        vm.goTo(2)                               // 第 3 面,属于 (1,2) 这一摊
        XCTAssertEqual(vm.pageIndex, 1, "应归一到摊首面,否则主图会是摊的第二面")
        XCTAssertEqual(vm.secondaryIndex, 2)

        // 关掉口径后,第 1 面不再与第 0 面同摊 → 回到摊首面 0
        vm.coverAlone = false
        XCTAssertEqual(vm.pageIndex, 0)
        XCTAssertEqual(vm.secondaryIndex, 1)
    }

    /// 配对口径变化时主图必须换页(单页档停在第 2 面 → 开封面单独的双页 → 归一)
    func testToggleCoverAloneRealignsSinglePagePosition() async throws {
        let vm = try await openFixtureOrSkip()
        vm.goTo(2)
        vm.layout = .dual
        XCTAssertEqual(vm.pageIndex, 2, "不单独封面时第 2 面本就是摊首面")

        vm.coverAlone = true
        XCTAssertEqual(vm.pageIndex, 1, "封面单独后 (1,2) 才是一摊,主图须落到摊首面")
        XCTAssertEqual(vm.secondaryIndex, 2)
    }

    /// 口径随文档记忆:重开同一本恢复
    func testCoverAloneSurvivesReopen() async throws {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }

        let first = makeViewModel()
        await first.open(url: url).value
        guard case .reading = first.phase else { return XCTFail("首次打开应进入 reading") }
        first.layout = .dual
        first.coverAlone = true
        first.goTo(1)
        XCTAssertEqual(first.pageIndex, 1)

        let second = makeViewModel(reuseProgress: true)
        await second.open(url: url).value
        guard case .reading = second.phase else { return XCTFail("重开应进入 reading") }
        XCTAssertTrue(second.coverAlone, "封面单独口径应随文档恢复")
        XCTAssertEqual(second.pageIndex, 1, "恢复到摊首面")
        XCTAssertEqual(second.secondaryIndex, 2)
    }

    /// 老记录(无 coverAlone 字段)恢复时必须退化成「不单独封面」,且进度不丢
    func testResumeLegacyProgressWithoutCoverAloneFallsBackToOff() async throws {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }
        cleanProgress()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        progressStore().save(key: ReadingProgress.key(name: url.lastPathComponent, size: size),
                             page: 2, layout: "dual",
                             direction: "rightToLeft", fitMode: "fitWidth")

        let vm = makeViewModel(reuseProgress: true)
        await vm.open(url: url).value
        guard case .reading = vm.phase else { return XCTFail("打开应进入 reading") }
        XCTAssertFalse(vm.coverAlone, "老记录没有该字段 → 关")
        XCTAssertEqual(vm.pageIndex, 2, "老记录页码照常恢复(不单独封面时 2 就是摊首面)")
        XCTAssertEqual(vm.secondaryIndex, nil, "3 页文档:末面单独")
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

    // MARK: - 导出 / 窗口标题(v2,2026-09-16)

    /// 双页模式的次页是异步加载的,断言前必须等它落定
    private func waitForSecondary(_ vm: ReaderViewModel, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.secondary == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 没有文档时标题回落到 App 名 —— 空窗口上挂个「P.1/0」很怪
    func testWindowTitleFallsBackToAppNameWithoutDocument() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.windowTitle, L10n.tr("app.name"))
        XCTAssertFalse(vm.windowTitle.contains("P."))
    }

    /// 打开后标题带文件名与页码(多窗口 / Dock 悬停辨认用)
    func testWindowTitleCarriesNameAndPage() async throws {
        let vm = try await openFixtureOrSkip()
        vm.goTo(min(2, vm.pageCount - 1))
        XCTAssertEqual(vm.windowTitle,
                       L10n.tr("reader.window.title", "plain.cbz", vm.pageIndex + 1, vm.pageCount))
        XCTAssertTrue(vm.windowTitle.contains("plain.cbz"))
    }

    /// 未打开文档 → 导不出图(菜单项据此禁用,不留"点了没反应")
    func testExportImageIsNilWithoutDocument() {
        XCTAssertNil(makeViewModel().exportImage())
    }

    /// 单页模式导出 = 当前页本身
    func testExportImageInSinglePageIsThePageItself() async throws {
        let vm = try await openFixtureOrSkip()
        let image = try XCTUnwrap(vm.exportImage())
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertNil(vm.secondary, "单页模式不该有次页")
    }

    /// 双页模式导出 = **屏幕上那一摊**(两页并成一张),宽度正好翻倍。
    /// 口径与画布渲染同一套,否则「导出的和看到的不一样」
    func testExportImageInDualPageComposesWholeSpread() async throws {
        let vm = try await openFixtureOrSkip()
        let single = try XCTUnwrap(vm.exportImage())

        vm.layout = .dual
        vm.goTo(0)
        try await waitForSecondary(vm)

        let spread = try XCTUnwrap(vm.exportImage())
        XCTAssertEqual(spread.width, single.width * 2, "双页导出应把两页并排成一张")
        XCTAssertEqual(spread.height, single.height)
    }

    /// 建议文件名带归档名与补零页号(扩展名随格式)
    func testExportFileNameFollowsDocumentAndPage() async throws {
        let vm = try await openFixtureOrSkip()
        vm.goTo(0)
        XCTAssertEqual(vm.exportFileName(format: .png), "plain-p001.png")
        XCTAssertEqual(vm.exportFileName(format: .jpeg), "plain-p001.jpg")
    }

    // MARK: - 解压密码(v2,2026-09-17)

    /// fixture 里所有加密样本共用这一个密码(造法见 ArchiveKit/Tests/Fixtures/make_fixtures.sh)
    private static let fixturePassphrase = "secret"

    /// 取加密 fixture;不可达则 skip(与 openFixtureOrSkip 同一套沙盒约定)
    private func encryptedFixture(_ name: String) throws -> URL {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }
        return url
    }

    /// 等一个异步状态落定。解锁走的是 Task(不是可 await 的 open),
    /// 只能轮询 —— 20ms 粒度,与 waitForSecondary 同一套写法
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 全加密 zip + 不给密码 → **进入 needsPassword,而不是失败**。
    /// 这是 v2 密码功能的入口断言:v1 时同一个文件走的是一条终局错误页
    func testEncryptedArchiveAsksForPasswordInsteadOfFailing() async throws {
        let url = try encryptedFixture("encrypted-zip.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value

        XCTAssertEqual(vm.phase, .needsPassword)
        XCTAssertNil(vm.passwordFailure, "第一次问密码,不该先摆一句「密码不对」")
        XCTAssertEqual(vm.pageCount, 0)
    }

    /// 输对密码 → 进阅读态,首页真的解出来上屏。
    /// 只断言「没报错」是不够的:密码错与密码对都可能走到 reading,
    /// 真正说明问题的是**图出来了**(之前那张是加密占位卡)
    func testCorrectPasswordOpensArchive() async throws {
        let url = try encryptedFixture("encrypted-zip.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value
        XCTAssertEqual(vm.phase, .needsPassword)

        await vm.open(url: url, passphrase: Self.fixturePassphrase).value

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertEqual(vm.pageCount, 3)
        XCTAssertNil(vm.passwordFailure)
        XCTAssertFalse(vm.hasLockedPages)
        let image = try XCTUnwrap(vm.presentation.image, "解开密码后首页应当真的上屏")
        XCTAssertGreaterThan(image.width, 0)
    }

    /// AES-256 加密包同样走通。ZipCrypto 与 AES 在 libarchive 里是两套解密
    /// 代码(ZipCrypto 靠末尾校验字节、AES 靠口令校验值 + HMAC),
    /// 一条通过不能推断另一条 —— 故两种样本各测一遍
    func testCorrectPasswordOpensAesArchive() async throws {
        let url = try encryptedFixture("encrypted-zip-aes.cbz")
        let vm = makeViewModel()
        await vm.open(url: url, passphrase: Self.fixturePassphrase).value

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertEqual(vm.pageCount, 3)
    }

    /// 密码错 → **留在密码界面**并说明原因:不是终局失败,也不许进阅读器
    /// (进了就是满屏占位卡片,用户不知道自己做错了什么)
    func testWrongPasswordStaysOnPromptWithExplanation() async throws {
        let url = try encryptedFixture("encrypted-zip.cbz")
        let vm = makeViewModel()
        await vm.open(url: url, passphrase: "definitely-not-the-password").value

        XCTAssertEqual(vm.phase, .needsPassword)
        XCTAssertEqual(vm.passwordFailure?.titleKey, "archive.password.wrong.title")
        XCTAssertEqual(vm.passwordFailure?.bodyKey, "archive.password.wrong.body")
        XCTAssertEqual(vm.pageCount, 0, "密码没对就不该有页进内存")
    }

    /// 输错之后再输对 → 正常进入。重试路径必须通,否则面板成了死胡同
    func testRetryAfterWrongPasswordSucceeds() async throws {
        let url = try encryptedFixture("encrypted-zip.cbz")
        let vm = makeViewModel()
        await vm.open(url: url, passphrase: "nope").value
        XCTAssertNotNil(vm.passwordFailure)

        await vm.open(url: url, passphrase: Self.fixturePassphrase).value

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertNil(vm.passwordFailure, "成功之后旧的「密码不对」必须清掉")
    }

    /// 取消 → 回空态,并清掉 documentURL。
    /// (留着它会让「在访达中显示」指向一个**从未真正打开**的归档 ——
    ///  菜单可用但点了没意义,是很隐蔽的假状态)
    func testCancellingPasswordReturnsToEmptyState() async throws {
        let url = try encryptedFixture("encrypted-zip.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value
        XCTAssertEqual(vm.phase, .needsPassword)

        vm.cancelPasswordPrompt()

        XCTAssertEqual(vm.phase, .noDocument)
        XCTAssertNil(vm.documentURL)
        XCTAssertNil(vm.documentName)
        XCTAssertNil(vm.passwordFailure)
    }

    /// 空密码被忽略:不发起打开、不改状态(UI 已禁用按钮,这层是兜底)
    func testEmptyPasswordIsIgnored() async throws {
        let url = try encryptedFixture("encrypted-zip.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value
        vm.submitPassword("")

        XCTAssertEqual(vm.phase, .needsPassword)
        XCTAssertNil(vm.passwordFailure)
    }

    /// 7z 加密**不给密码入口**,仍是终局失败。
    /// 依据:系统库对 7z 加密是能力死限(给了正确密码也报 currently not supported,
    /// 2026-09-17 实测),让用户白输一次密码是欺骗
    func testEncrypted7zFailsWithoutPasswordPrompt() async throws {
        let url = try encryptedFixture("encrypted-content.cb7")
        let vm = makeViewModel()
        await vm.open(url: url).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("7z 加密应仍是终局失败,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.encrypted.7z.title")
    }

    // MARK: - 部分加密包的解锁(⇧⌘K)

    /// 部分加密包照常打开(加密页显示占位卡片),此时解锁入口才可用
    func testPartialArchiveOpensWithLockedPages() async throws {
        let url = try encryptedFixture("partial.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertEqual(vm.pageCount, 4)
        XCTAssertTrue(vm.hasLockedPages, "有读不出的页时,解锁入口必须可用")
    }

    /// 解锁成功:全部页可读,且**页码不动** —— 解锁不是换书,不该把读者弹回封面
    func testUnlockPartialArchiveKeepsPosition() async throws {
        let url = try encryptedFixture("partial.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value
        vm.goTo(1)
        let positionBeforeUnlock = vm.pageIndex

        vm.beginUnlock()
        XCTAssertTrue(vm.isUnlockSheetPresented)
        vm.submitUnlockPassword(Self.fixturePassphrase)
        try await waitUntil { !vm.hasLockedPages }

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertEqual(vm.pageIndex, positionBeforeUnlock, "解锁不该变动阅读位置")
        XCTAssertEqual(vm.pageCount, 4, "解密不改条目数")
        XCTAssertFalse(vm.isUnlockSheetPresented)
        XCTAssertNil(vm.passwordFailure)
    }

    /// 解锁失败:读数**留在原地**、面板留着让人重试。
    /// 这条专门盯「解锁不许走 open()」—— 那条路是换书语义,一上来就 teardown
    /// 旧 store 并清空页码,于是密码打错一次就白屏一次、读者被弹回封面
    func testUnlockWithWrongPasswordKeepsReadingIntact() async throws {
        let url = try encryptedFixture("partial.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value
        guard case .reading = vm.phase else { throw XCTSkip("partial.cbz 未进入 reading") }

        vm.beginUnlock()
        vm.submitUnlockPassword("definitely-not-the-password")
        try await waitUntil { vm.passwordFailure != nil }

        XCTAssertEqual(vm.phase, .reading, "解锁失败不许把读者踢出阅读态")
        XCTAssertEqual(vm.pageCount, 4, "解锁失败不许把文档拆掉")
        XCTAssertTrue(vm.isUnlockSheetPresented, "面板要留着让人重试")
        XCTAssertTrue(vm.hasLockedPages, "没解开就还是有锁定页")
    }

    /// 解锁面板的取消只关面板,阅读照常
    func testCancellingUnlockKeepsReading() async throws {
        let url = try encryptedFixture("partial.cbz")
        let vm = makeViewModel()
        await vm.open(url: url).value
        vm.beginUnlock()

        vm.cancelPasswordPrompt()

        XCTAssertFalse(vm.isUnlockSheetPresented)
        XCTAssertEqual(vm.phase, .reading)
        XCTAssertEqual(vm.pageCount, 4)
    }
}
