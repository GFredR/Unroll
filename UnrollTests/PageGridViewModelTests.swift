// AI-Generated | 可修改
// PageGridViewModelTests —— 缩略图网格与跳页预览在 VM 层的粘合(2026-09-18,v1.1)
// ----------------------------------------------------------------------------
// 生成算法本身(顺序性 / 双预算 / 异常分流)在 `PageGridTests` 里测。
// 本文件只补**状态机与所有权**四件事 —— 它们的共同点是「出了错界面照样能跑」:
//   · 可用性随阶段变化(没打开文档时不许点,也不许切层);
//   · 结果确实落到 `grid` 上,且**池子真的被填满**(不是"进度条到头了图还没到");
//   · **层(`layer`)是双向往返的**:打开落网格 → 点格进大图 → 返回落回网格,
//     而**切层不许动扫描**(既不能取消,也不能重开一轮);
//   · **换书必须丢掉旧池子** —— 旧包的缩略图显示在新书上是纯粹的"张冠李戴",
//     而且它长得完全正常,没有任何报错会提示你出错。
//
// ⚠️ 2026-09-23 起网格从「浮层面板」变成**默认层**,于是本文件里那些
// `isGridSheetPresented` / `dismissGrid()` 的断言整体换成了 `layer` 与
// `showReader()`,并且多了一条「打开即开扫」的断言 —— 因为**没有返回值能 await**
// 那一轮自动生成,`gridBuildTask` 才是等它落定的手段(为此从 private 放开到 private(set))
//
// ⚠️ 时序纪律:凡「打开之后状态应该还在 X」这类断言都**不写死**。
// 三个页的小包可能在 `await open(...).value` 期间就扫完了 —— 那时状态是
// `.ready` 而不是 `.building`。要钉的是**终局**(池子填满 / 报告正确),
// 不是中途某一刻。需要"在途窗口"的用例一律用 `rebuildGrid()` 造
// (它同步返回句柄,与紧随的调用之间没有 await ⇒ MainActor 不可重入保证它在途),
// 而不是赌某个包扫得够慢。
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

        // 先把层摆到一个**非默认**的位置,下面那条断言才有判别力 ——
        // `layer` 的默认值本来就是 `.browse`,而 `showGrid()` 第一件事就是
        // 把它写成 `.browse`:不摆的话「层没被切」这句话恒真,什么也没测
        vm.layer = .read

        XCTAssertNil(vm.showGrid())
        XCTAssertNil(vm.buildGrid())
        XCTAssertEqual(vm.layer, .read, "不可用时连层都不该切")
    }

    // MARK: - 打开即网格(2026-09-23)

    /// 「打开即网格」:点开压缩包**先看到全卷缩略图**,而不是先看到第 1 页大图。
    /// 落层与开扫都必须由 VM 保证 —— 交给 View 的 `onAppear` 去触发,
    /// 就会冒出"谁的 onAppear 先到"这种没人说得清的顺序问题
    ///
    /// 反向注入实测(2026-09-23):把 `performOpen` 里那句 `showGrid()` 拿掉
    /// (退回"打开不自动开扫")→ 本用例红在 `case nil: XCTFail("…压根没开始扫")`,
    /// 同时整类 7 红 7 绿(红的全是依赖"打开就有池子"的用例)
    func testOpenLandsOnGridLayerAndStartsGenerating() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")

        XCTAssertEqual(vm.layer, .browse, "打开归档后应落在网格层,而不是直接进大图")

        // ⚠️ **刻意不写** `XCTAssertEqual(vm.grid, .building(done: 0, total: 3))`:
        // 三个页的包可能在上面那个 await 里就扫完了,那一刻是 `.ready` ——
        // 「必须还在 building」会变成一条随机器忙闲漂移的判据。
        // 这一条要钉住的是**打开就开扫了**(没等人按任何键),两条路径都得是对的账
        switch vm.grid {
        case .building(_, let total):
            XCTAssertEqual(total, 3, "总页数取自过滤后的文档条目数(plain 里的 note.txt / .DS_Store 不算页)")
        case .ready(let report):
            XCTAssertEqual(report.generated, 3, "上面那个 await 里已经扫完了 —— 那也必须是对的账")
        case nil:
            XCTFail("打开后网格状态必须已经建立起来 —— nil 意味着压根没开始扫")
        }
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
        try XCTSkipIf(!vm.canShowGrid, "fixture 不可读时不谈生成(算法层由 PageGridTests 覆盖)")

        // 打开就开扫了,所以这里**不重开**:直接等 `performOpen` 起的那一轮。
        // 若它已经在 await 期间收尾,`gridBuildTask` 是 nil,下面这句就是空转
        await vm.gridBuildTask?.value

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

    // MARK: - 层的双向往返:browse ⇄ read

    /// 从阅读层回网格**不重扫**:有现成结果就直接显示。
    /// 这条的收益是实打实的 —— solid 7z 上重扫一次是秒级,
    /// 而「看一眼大图、回来看目录」正是这个功能的典型用法
    func testReturningToGridReusesResultWithoutRescanning() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")
        await vm.gridBuildTask?.value

        vm.showReader()
        XCTAssertEqual(vm.layer, .read, "点了一格就该在阅读层")
        XCTAssertNotNil(vm.gridThumbnail(at: 0), "切到阅读层不该动池子 —— 它归网格管,寿命不同")

        let second = vm.showGrid()
        XCTAssertNil(second, "已有结果时不该再起任务(返回 nil = 没做任何异步工作)")
        XCTAssertEqual(vm.layer, .browse)
        guard case .ready(let report) = vm.grid else {
            return XCTFail("回到网格应当直接拿到上次的报告")
        }
        XCTAssertEqual(report.generated, 3)
    }

    /// 扫描在用户读大图时才收尾 —— 收尾**只许记报告,不许动层**。
    ///
    /// 这条用例有两个断言,各自拦的错不一样,别以为是同一件事:
    ///   · `layer` 仍为 `.read` —— 拦"收尾顺手把网格亮出来"(把用户从目录弹回大图,
    ///     或者反过来强行切层)。**这一条没做反向注入**(没有一个"真实旧行为"
    ///     会去写 `layer`),所以它是**预防性**的,不是被症状验证过的;
    ///   · 回来时零重扫(`showGrid()` 返回 nil)—— 这条**做过反向注入**:
    ///     把 `vm.lastGridReport = report` 一起挪进 `if vm.layer == .browse` 里
    ///     (一种很自然的"顺手收拾"式错误),实测立刻红在 `XCTAssertNil` 上,
    ///     且 `grid` 真的退回 `.building(done: 0, total: 3)` = 又起了一轮全档扫描。
    ///     报告必须**独立于层**被记下 —— 否则"读着读着回来"要付一次秒级重扫
    func testScanFinishingWhileReadingDoesNotPullTheUserBack() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")

        vm.showReader()
        XCTAssertEqual(vm.layer, .read)

        // 让扫描落定(可能早就落定了 —— 那也没关系,这条用例考的是"收尾时不动层")
        await vm.gridBuildTask?.value

        XCTAssertEqual(vm.layer, .read, "扫描收尾不许把用户从阅读层弹回网格层")
        // 报告已经记下 ⇒ 回来时零重扫
        XCTAssertNil(vm.showGrid(), "已经扫完的卷,回网格不该再起一轮")
        XCTAssertEqual(vm.layer, .browse)
        guard case .ready(let report) = vm.grid else {
            return XCTFail("回到网格必须立刻拿到现成报告,实际:\(String(describing: vm.grid))")
        }
        XCTAssertEqual(report.generated, 3)
    }

    /// 「生成在途时不许重开一轮」—— 这条守卫是「打开即网格」带出来的(2026-09-23)。
    /// 没有它,用户在第一轮扫描跑完前按「浏览」回来,就会**取消并重头顺序扫全档**:
    /// 越点越慢,而界面上只看得出"进度条又回到 0"(`buildGrid` 第一句就是
    /// `grid = .building(done: 0, total:)`),看不出自己刚把工作作废了一次
    ///
    /// 反向注入实测(2026-09-23),**两种真实旧行为各验过一次**:
    ///   · 去掉 `showGrid()` 里那句 `if let inFlight = gridBuildTask { return inFlight }`
    ///     → 红在 `XCTAssertFalse(inFlight.isCancelled, …)`;
    ///   · 让 `showReader()` 退回旧 `dismissGrid()` 的"切层顺手取消"
    ///     → 同一条红,且**另一条用例**(`testScanFinishingWhileReading…`)的
    ///     `report.generated` 从 3 掉到 2 —— 扫描被真的截断了,正是"半空的网格"
    func testShowGridWhileScanIsInFlightDoesNotRestartIt() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")

        // ⚠️ 用 `rebuildGrid()` 而不是 `open()` 自带那一轮来造「在途」:
        // `await open(...).value` 返回时,那一轮的收尾(`MainActor.run` 里把
        // `gridBuildTask` 置 nil)**可能已经排队执行过了** —— 赌它没执行,
        // 就是一条会随机器忙闲漂移的判据。而 `rebuildGrid()` 同步返回句柄,
        // 只要它与下面 `showGrid()` 之间**没有 await**,「MainActor 不可重入」
        // 这条保证就让 `gridBuildTask` 必定还活着
        let inFlight = try XCTUnwrap(vm.rebuildGrid(), "重新生成必须真的起一轮")

        // 走真实路径:看一眼大图,再按「浏览」回来
        vm.showReader()
        XCTAssertEqual(vm.layer, .read)
        let back = vm.showGrid()

        XCTAssertEqual(vm.layer, .browse, "「浏览」要回到网格层")
        // **判据选 `isCancelled` 而不是「返回的是不是同一个任务」**:
        // `Task` 是 struct,没有公开的身份比较手段;而「重开一轮」必然先
        // `gridBuildTask?.cancel()`(`buildGrid` 第一句),取消标志就在这个句柄上
        XCTAssertFalse(inFlight.isCancelled,
                       "在途时回来**不许**取消第一轮 —— 那等于把已扫到的部分全部作废,从头再顺序扫一遍")
        XCTAssertNotNil(back, "在途时必须把当前这一轮交回去,而不是让调用方以为「无事可做」")

        await back?.value
    }

    /// 「重新生成」是**另一个语义**:丢现有的重做。与「打开面板」分开,
    /// 是为了让「打开很快」这件事可预期
    func testRebuildDiscardsExistingPoolAndRescans() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")
        await vm.gridBuildTask?.value          // 先把打开时那一轮等完,免得它和下面这轮抢

        let task = vm.rebuildGrid()
        XCTAssertNotNil(task, "重新生成必须真的再跑一遍,而不是复用结果")
        await task?.value

        guard case .ready(let report) = vm.grid else {
            return XCTFail("重新生成后必须回到 .ready")
        }
        XCTAssertEqual(report.generated, 3)
        XCTAssertNotNil(vm.gridThumbnail(at: 2))
        XCTAssertEqual(vm.layer, .browse, "重新生成顺带把层切回网格 —— 这个入口本来就在网格层上")
    }

    // MARK: - 所有权:换书必须丢池子

    /// 旧包的缩略图**绝不能**落到新书上。这类错误的特征是没有报错:
    /// 格子里的图看着都正常,只是画的是另一本书
    func testOpeningAnotherArchiveDropsPreviousGrid() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")
        await vm.gridBuildTask?.value
        XCTAssertNotNil(vm.gridThumbnail(at: 0), "第一本得真的生成出缩略图,否则下面那条判据会退化成恒真")

        // 先把用户放到阅读层 —— 换书时层必须复位(新书是「打开即网格」)
        vm.showReader()
        XCTAssertEqual(vm.layer, .read)

        await vm.open(url: try fixture("damaged-page.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "第二份 fixture 可读性受限(测试宿主沙盒)")

        XCTAssertEqual(vm.layer, .browse, "换书后层要复位到网格 —— 上一本停在阅读层也不能带过来")

        await vm.gridBuildTask?.value
        guard case .ready(let report) = vm.grid else {
            return XCTFail("新书的生成必须跑出结果")
        }
        XCTAssertEqual(report.pages, 3)
        XCTAssertEqual(report.failedCount, 1,
                       "damaged-page.cbz 第 2 页损坏 ⇒ 必须如实记 1 页失败(若这拿到的是上一本 plain 的报告,会是 0)")

        // **「池子换没换」的判据**:新书的第 2 页解不出来,池子里那一格必须是空的。
        // 若旧池子被留着继续用,那格里躺着的就是**上一本 page2 的缩略图**(非 nil),
        // 而它在界面上看着完全正常 —— 这正是本条用例要拦的那种错误。
        // (不能用"越界查询"来验:没有任何 fixture 有 4 张以上可解码页,
        //  而 partial.cbz 的第 4 页是加密页、本来就不会有缩略图)
        //
        // 反向注入实测(2026-09-23):把"代次隔离"退回旧设计 —— `open()` 里那句换池
        // **和** `buildGrid` 里 `let pool = ThumbnailStore()` 一并改回"单一常驻池",
        // 本行立刻红:`XCTAssertNil failed: "<CGImage …>"`。也就是说**两层护栏互为备份**
        // (换书换池 + 每轮新建池),任一层单独保留都拦得住 —— 这条注入必须同时退两层
        // 才复现症状,正说明没有哪一层是"写了从不生效"的
        XCTAssertNil(vm.gridThumbnail(at: 1), "损坏页不许有缩略图:非 nil 说明拿到的是上一本 page2 的图")
        XCTAssertNotNil(vm.gridThumbnail(at: 0), "新书的第 1 页必须已经生成(证明这一轮确实跑完并写了新池子)")
    }

    // MARK: - 跳页预览

    /// 跳页预览必须取到**请求的那一页**,而且不论走哪条路都收得干净。
    ///
    /// ⚠️ 这条**刻意不断言「起了异步任务 / 正在转圈」**:「打开即网格」之后,
    /// 网格扫描会自动把可读页灌进池子,而 `previewJumpTarget` 是**先查池子**的
    /// (§5.14 的白拿收益)—— 同一页可能同步命中(返回 nil)。命不命中取决于
    /// 扫描跑到哪了,写死任一边都是会随机器忙闲漂移的判据。
    /// 异步那一条分支由 `testPreviewOnEncryptedPageReportsFailure` 钉住 ——
    /// 加密页**永远**不在池子里,只有那里是确定性可判的
    func testPreviewLoadsRequestedPage() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value

        let task = vm.previewJumpTarget(1)   // 池子命中时返回 nil:已经同步到位,没什么可等
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
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")
        await vm.gridBuildTask?.value          // 池子已经被填满

        let task = vm.previewJumpTarget(2)
        XCTAssertNil(task, "池子命中时不该起任务")
        XCTAssertNotNil(vm.jumpPreview, "而且必须同步就有图,不能先闪一下转圈")
        XCTAssertEqual(vm.jumpPreviewPage, 2)
        XCTAssertFalse(vm.isJumpPreviewLoading)
    }

    /// 加密页:如实报失败,**不崩、不假装在加载**。
    /// 面板上那格必须显示「此页已加密」这类明确说明 —— 一直转圈会被当成卡住了
    ///
    /// 这条同时是**异步分支的确定性判据**:加密页在生成阶段就被跳过
    /// (§5.14 约束⑥,`skippedEncrypted == 2`),池子里**永远**没有它 ⇒
    /// 「起了任务 + 正在转圈」在这里是必然,不是碰运气
    func testPreviewOnEncryptedPageReportsFailure() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("partial.cbz")).value

        let task = vm.previewJumpTarget(3)     // partial.cbz 的 page4 是加密页
        XCTAssertNotNil(task, "加密页不在池子里,必须真去读一次")
        XCTAssertTrue(vm.isJumpPreviewLoading, "真去读的时候必须先把转圈亮出来")
        await task?.value

        XCTAssertNil(vm.jumpPreview)
        let failure = try XCTUnwrap(vm.jumpPreviewFailure, "加密页必须给出可显示的原因")
        XCTAssertEqual(failure.titleKey, "archive.page.encrypted.title")
        XCTAssertFalse(vm.isJumpPreviewLoading, "失败也必须把加载态收掉")
    }

    /// 清预览:面板关闭时调用。**不清池子** —— 池子归网格管,寿命不同
    func testClearPreviewKeepsGridPool() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        try XCTSkipIf(!vm.canShowGrid, "fixture 可读性受限(测试宿主沙盒)")
        await vm.gridBuildTask?.value
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
