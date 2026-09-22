// AI-Generated | 可修改
// PageGridViewModelTests —— 缩略图网格与跳页预览在 VM 层的粘合(2026-09-18,v1.1)
// ----------------------------------------------------------------------------
// 生成算法本身(顺序性 / 双预算 / 异常分流)在 `PageGridTests` 里测。
// 本文件只补**状态机与所有权**三件事 —— 这三件事的共同点是「出了错界面照样能跑」:
//   · 菜单可用性随阶段变化(没打开文档时不许点);
//   · 结果确实落到 `grid` 上,且**池子真的被填满**(不是"进度条到头了图还没到");
//   · **换书必须丢掉旧池子** —— 旧包的缩略图显示在新书上是纯粹的"张冠李戴",
//     而且它长得完全正常,没有任何报错会提示你出错。
//
// ⚠️ 与 PageStoreTests / IntegrityCheckTests 同款沙盒说明。
import ArchiveKit
import XCTest
@testable import Unroll

@MainActor
final class PageGridViewModelTests: XCTestCase {

    private static let suiteName = "test.pagegrid.progress"

    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    private func fixture(_ name: String) throws -> URL {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)—— 算法层由 PageGridTests 覆盖")
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

    // MARK: - 可用性

    /// 没打开文档时不许生成 —— 没有文档就没有可生成的对象。
    /// 返回 nil 而不是「建个空任务」,是为了不留半启动状态
    func testGridIsUnavailableBeforeOpening() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .noDocument)
        XCTAssertFalse(vm.canShowGrid)
        XCTAssertNil(vm.showGrid())
        XCTAssertNil(vm.buildGrid())
        XCTAssertFalse(vm.isGridSheetPresented, "不可用时连面板都不该开")
    }

    // MARK: - 生成落地

    /// 生成完必须是 `.ready` + 报告,而且**池子真的填满了**。
    ///
    /// 后半句是这条用例的重点:第一版实现里缩略图是「每张回跳一次主线程」写入的,
    /// 于是 `await task.value` 返回时池子**可能还是空的** —— 界面表现就是
    /// "进度条到头了、图还没出全",而任何只看 `grid` 状态的断言都发现不了
    func testShowGridFillsPoolAndFinishesWithReport() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value

        let task = vm.showGrid()
        XCTAssertTrue(vm.isGridSheetPresented, "开始生成要顺带把面板打开")
        XCTAssertEqual(vm.grid, .building(done: 0, total: 3))
        XCTAssertTrue(vm.isGridBuilding)
        try XCTSkipIf(task == nil, "fixture 不可读时 showGrid 不会建任务")

        await task?.value

        guard case .ready(let report) = vm.grid else {
            return XCTFail("生成结束后必须是 .ready,实际:\(String(describing: vm.grid))")
        }
        XCTAssertEqual(report.generated, 3)
        XCTAssertEqual(report.stop, .finished)
        XCTAssertFalse(vm.isGridBuilding)
        // 池子必须已经填满,不用等任何东西
        for page in 0..<3 {
            XCTAssertNotNil(vm.gridThumbnail(at: page), "第 \(page + 1) 页的缩略图没有落到池子里")
        }
        XCTAssertNil(vm.gridThumbnail(at: 99), "越界查询必须是 nil,不能崩")
    }

    /// 重开面板**不重扫**:有现成结果就直接显示。
    /// 这条的收益是实打实的 —— solid 7z 上重扫一次是秒级,
    /// 而「看一眼就关、再打开」正是这个功能的典型用法
    func testReopeningGridReusesResultWithoutRescanning() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.showGrid()?.value

        vm.dismissGrid()
        XCTAssertFalse(vm.isGridSheetPresented)
        XCTAssertNil(vm.grid, "关面板要清掉视图状态")
        XCTAssertNotNil(vm.gridThumbnail(at: 0), "但池子要留着 —— 否则重开又得全扫一遍")

        let second = vm.showGrid()
        XCTAssertNil(second, "已有结果时不该再起任务(返回 nil = 没做任何异步工作)")
        XCTAssertTrue(vm.isGridSheetPresented)
        guard case .ready(let report) = vm.grid else {
            return XCTFail("重开面板应当直接拿到上次的报告")
        }
        XCTAssertEqual(report.generated, 3)
    }

    /// 「重新生成」是**另一个语义**:丢现有的重做。与「打开面板」分开,
    /// 是为了让「打开很快」这件事可预期
    func testRebuildDiscardsExistingPoolAndRescans() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.showGrid()?.value

        let task = vm.rebuildGrid()
        XCTAssertNotNil(task, "重新生成必须真的再跑一遍,而不是复用结果")
        await task?.value

        guard case .ready(let report) = vm.grid else {
            return XCTFail("重新生成后必须回到 .ready")
        }
        XCTAssertEqual(report.generated, 3)
        XCTAssertNotNil(vm.gridThumbnail(at: 2))
    }

    // MARK: - 所有权:换书必须丢池子

    /// 旧包的缩略图**绝不能**落到新书上。这类错误的特征是没有报错:
    /// 格子里的图看着都正常,只是画的是另一本书
    func testOpeningAnotherArchiveDropsPreviousGrid() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.showGrid()?.value
        XCTAssertNotNil(vm.gridThumbnail(at: 0))

        await vm.open(url: try fixture("damaged-page.cbz")).value

        XCTAssertNil(vm.grid, "换书后旧网格状态必须立即清掉")
        XCTAssertFalse(vm.isGridSheetPresented, "面板也要一起关掉")
        XCTAssertNil(vm.gridThumbnail(at: 0), "旧包的缩略图不许留在池子里")
        // 新书写 `showGrid` 必须真的重扫 —— 否则会直接显示旧包的报告
        let task = vm.showGrid()
        XCTAssertNotNil(task, "换书后必须重新生成(旧报告已作废)")
        await task?.value
        guard case .ready(let report) = vm.grid else {
            return XCTFail("新书的生成必须跑出结果")
        }
        XCTAssertEqual(report.pages, 3)
    }

    // MARK: - 跳页预览

    /// 真去取一页 → 图和页码都要对上,加载标志要落回 false
    func testPreviewLoadsRequestedPage() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value

        let task = vm.previewJumpTarget(1)
        XCTAssertNotNil(task)
        XCTAssertTrue(vm.isJumpPreviewLoading)
        await task?.value

        XCTAssertNotNil(vm.jumpPreview)
        XCTAssertEqual(vm.jumpPreviewPage, 1, "预览必须记住自己是哪一页的 —— UI 靠它防串页")
        XCTAssertNil(vm.jumpPreviewFailure)
        XCTAssertFalse(vm.isJumpPreviewLoading)
    }

    /// 越界输入要**夹紧**而不是报错:面板里的输入框自己会先做合法性检查,
    /// 走到这里的一定是"接近边界"的值(比如翻页后页码变小了)
    func testPreviewClampsOutOfRangeIndex() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value

        await vm.previewJumpTarget(99)?.value
        XCTAssertEqual(vm.jumpPreviewPage, 2, "越界应当夹到最后一页")
        XCTAssertNotNil(vm.jumpPreview)
    }

    /// 池子命中时**同步返回、零异步工作** —— 这是「先开网格再跳页」这条路径的
    /// 全部收益所在。返回 nil 就说明没有起任务,也就没有新的 I/O
    func testPreviewUsesGridPoolWithoutSpawningWork() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.showGrid()?.value          // 池子已经被填满

        let task = vm.previewJumpTarget(2)
        XCTAssertNil(task, "池子命中时不该起任务")
        XCTAssertNotNil(vm.jumpPreview, "而且必须同步就有图,不能先闪一下转圈")
        XCTAssertEqual(vm.jumpPreviewPage, 2)
        XCTAssertFalse(vm.isJumpPreviewLoading)
    }

    /// 加密页:如实报失败,**不崩、不假装在加载**。
    /// 面板上那格必须显示「此页已加密」这类明确说明 —— 一直转圈会被当成卡住了
    func testPreviewOnEncryptedPageReportsFailure() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("partial.cbz")).value

        await vm.previewJumpTarget(3)?.value     // partial.cbz 的 page4 是加密页

        XCTAssertNil(vm.jumpPreview)
        let failure = try XCTUnwrap(vm.jumpPreviewFailure, "加密页必须给出可显示的原因")
        XCTAssertEqual(failure.titleKey, "archive.page.encrypted.title")
        XCTAssertFalse(vm.isJumpPreviewLoading, "失败也必须把加载态收掉")
    }

    /// 清预览:面板关闭时调用。**不清池子** —— 池子归网格管,寿命不同
    func testClearPreviewKeepsGridPool() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.showGrid()?.value
        await vm.previewJumpTarget(1)?.value
        XCTAssertNotNil(vm.jumpPreview)

        vm.clearJumpPreview()

        XCTAssertNil(vm.jumpPreview)
        XCTAssertNil(vm.jumpPreviewPage)
        XCTAssertNil(vm.jumpPreviewFailure)
        XCTAssertFalse(vm.isJumpPreviewLoading)
        XCTAssertNotNil(vm.gridThumbnail(at: 1), "清预览顺手把网格池也清了,会让重开面板变成全量重扫")
    }

    /// 同一页重复请求被吃掉:防抖之后仍可能连点,而每次请求都是一次真实读取
    func testRepeatedPreviewRequestForSamePageIsDeduped() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.previewJumpTarget(1)?.value

        XCTAssertNil(vm.previewJumpTarget(1), "同一页已有结果,不该再起任务")
    }
}
