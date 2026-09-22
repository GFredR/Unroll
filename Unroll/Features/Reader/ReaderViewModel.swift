// AI-Generated | 可修改
// ReaderViewModel —— 页面状态机(设计文档 §4.1 / §4.3 图 3,M2 实现;M4 加面包屑打点)
// ----------------------------------------------------------------------------
// 规范(AGENTS.md 三):@MainActor + ObservableObject,View 通过 @StateObject 监听;
// 状态驱动 UI 切换,View 不含业务逻辑。
//
// 状态设计(两层,职责不同):
//   · phase    —— 归档级:无文档 → 打开中 → 阅读 / 失败(终局,§5.9.3 图 10 分流);
//   · presentation —— 页级:上屏图 + 加载中 + 单页失败。
//     加载新页时**保留旧图**(isLoading 置位即可),避免每次翻页白屏闪烁;
//     单页失败只换当前页的失败卡片,归档保持打开(§5.9.4 约束 4:
//     「单页失败 ≠ 整档失败」—— 部分加密归档能工作的前提)。
//
// 错误文案:VM 只产出 key + 参数(§5.9.3.1 的分组),渲染归 View(L10n.tr)。
// archive_error_string() 原文永不进 UI(§5.9.4 约束 6,可能含完整路径)。
//
// M4 面包屑打点(§5.10.3-①):本文件是「用户动作」的观测点 ——
//   打开 / 索引 / 翻页 / 布局切换。**只记动作与页索引,绝不记文件名**(§5.10.4);
//   失败也只记错误码,不记 archive_error_string() 原文(可能含路径)。
import ArchiveKit
import CoreGraphics
import Foundation

@MainActor
final class ReaderViewModel: ObservableObject {

    // MARK: - 归档级状态

    /// 归档阶段(终局失败对应 §5.9.3.1 各错误组)
    enum Phase: Equatable {
        case noDocument            // 空态:等待拖入 / 双击
        case opening
        case reading
        /// 归档加密,等用户输入密码(v2,2026-09-17)。
        /// **刻意不叫 failed**:它不是终局错误,而是流程的一个中间态 ——
        /// 输对了就进阅读,取消就回空态。当成失败会让文案写成「打不开」,
        /// 而事实是「还没打开」(两者对用户的意义完全不同)
        case needsPassword
        case failed(Failure)
    }

    /// 归档级失败。key + 本地化参数,渲染在 View 完成
    struct Failure: Equatable {
        let titleKey: String
        let bodyKey: String?
        let bodyArg: Int?
    }

    // MARK: - 页级状态

    /// 上屏页的次页(双页模式;nil = 单页 / 越界尾页)。独立于 PagePresentation:
    /// 主图的「保留旧图防闪烁」语义不适用于次页(翻摊时次页直接换新)
    @Published var secondary: CGImage?

    /// 当前页的上屏呈现:旧图垫底防闪烁 + 加载态 + 单页失败卡片
    struct PagePresentation: Equatable {
        var image: CGImage?        // 当前上屏图(新页就绪前是旧图或缩略图)
        var isLoading = false
        var failure: Failure?
    }

    // MARK: - 阅读模式(M3)

    /// 单页 / 双页 / 连续滚动(v2 候选池「连续滚动」落地,2026-09-21)。
    ///
    /// **为什么做成三选一而不是「布局 × 浏览方式」两个正交轴**:
    /// 连续滚动的本质是**一行一页的纵向流** —— 跨页内容在滚动下本来就断开,
    /// 「双页」在这里没有意义。做成第三个 case 的额外好处是**零语义漂移**:
    /// `SpreadPaging` 的调用点全都写着 `dual: layout.isSpread`,滚动模式下
    /// 它们自动退化成正确的单页行为,不需要在十几处补判断(补漏一处就是
    /// 「滚动时冒出半个摊」这种肉眼可见的内容错乱)。
    ///
    /// **与双页互斥,但不丢配置**:`coverAlone` 在滚动模式下不参与配对,
    /// 切回双页时原值照旧生效(菜单项在该模式下灰掉,见 `UnrollApp`)。
    enum PageLayout: String {
        case single
        case dual
        /// 连续滚动(竖向);见 `PageScrollView`。行的单位是**页**,不是摊
        case scroll

        /// 是否按「摊」组织内容(决定 `SpreadPaging` 的 dual 参数)。
        /// **只有这里能回答这个问题** —— 别在各处重新写 `layout == .dual`
        var isSpread: Bool { self == .dual }
    }

    /// 阅读方向:左开 / 日漫右开(右→左)
    enum ReadingDirection: String {
        case leftToRight
        case rightToLeft
    }

    /// 缩放档位(§2.1-4:适应窗口/适应宽/适应高/1:1)。
    /// 自由缩放(捏合/双击)是叠加在档位基准上的临时系数,归 Canvas 管;
    /// 档位属于阅读会话 —— 翻页不重置,只换书才回到默认。
    enum FitMode: String {
        case fitWindow      // 适应窗口(默认,整页完整可见)
        case fitWidth       // 适应宽(宽屏看漫画的高频档)
        case fitHeight      // 适应高
        case actualSize     // 1:1 实际大小

        /// 面包屑标签(过 sanitize 白名单)
        var token: String {
            switch self {
            case .fitWindow:  return "fit"
            case .fitWidth:   return "width"
            case .fitHeight:  return "height"
            case .actualSize: return "1to1"
            }
        }
    }

    // MARK: - Published

    @Published private(set) var phase: Phase = .noDocument
    @Published private(set) var presentation = PagePresentation()
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    /// HUD 显示用:仅文件名,绝不存完整路径(隐私红线同 §5.10.4)
    @Published private(set) var documentName: String?
    /// 当前文档 URL —— **只留在内存**,绝不持久化(续读/最近打开一律只落文件名,§5.7)。
    /// 用途只有两个:另存当前页的默认文件名、以及「在访达中显示」
    @Published private(set) var documentURL: URL?
    @Published var layout: PageLayout = .single {
        didSet {
            guard oldValue != layout, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.layoutChanged(layout.rawValue))
            realignSpread()
        }
    }
    /// 封面单独一页(2026-09-16)。双页配对口径见 `SpreadPaging`:
    /// 日式单行本的封面是独立一页,关掉它每翻一摊就错位一面。
    /// 默认关 = 与旧版本行为逐位一致(不改变既有用户的手感)
    @Published var coverAlone = false {
        didSet {
            guard oldValue != coverAlone, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.coverAloneChanged(coverAlone))
            realignSpread()
        }
    }
    @Published var direction: ReadingDirection = .leftToRight {
        didSet {
            guard oldValue != direction, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.directionChanged(direction == .leftToRight ? "ltr" : "rtl"))
            saveProgressNow()
            refreshSecondary()
        }
    }
    /// 缩放档位(§2.1-4):切换只影响渲染基准,与页面数据无关,不触发加载
    @Published var fitMode: FitMode = .fitWindow {
        didSet {
            guard oldValue != fitMode, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.fitModeChanged(fitMode.token))
            saveProgressNow()
        }
    }

    /// 双页模式下的次页下标(越界尾页 / 封面单独那一摊 → nil,View 退化为单页)。
    /// 配对口径全在 `SpreadPaging`(纯函数,独立单测)—— 本处只做转发
    var secondaryIndex: Int? {
        SpreadPaging.secondaryIndex(for: pageIndex, pageCount: pageCount,
                                   dual: layout.isSpread, coverAlone: coverAlone)
    }

    // MARK: - 私有

    private var store: PageStore?
    /// 当前文档。PageStore 里也有一份(它自己持有),这里是 VM 侧的引用 ——
    /// 给**完整性检查**用:它要顺序读全档,但不需要缓存与解码,走 PageStore
    /// 会把每一页都解码并塞进 LRU(「检查」变成「预热」,内存白吃一轮)
    private var document: ArchiveDocument?
    private var openTask: Task<Void, Never>?
    private var integrityTask: Task<Void, Never>?
    /// 「这一轮检查」的代号(2026-09-17)。每启动一次检查 +1,换书 / 换文档 /
    /// 关面板也 +1 —— 于是**过期的回调认不出自己已经作废**。
    ///
    /// 为什么必须有它(不是防御性代码,是实测缺陷):Task 的取消是**协作式**的,
    /// `cancel()` 只置一个标志,后台那个同步 C 循环要跑到下一次检查点才发现。
    /// 在它发现之前,用户可能已经打开另一本书了;那一刻整段 MainActor.run 收尾
    /// 照常执行,把**旧包的结论**写进**新包的界面**。
    /// 结论本身没错,错的是归属 —— 而用户会据此判断刚打开的这个包有没有坏。
    /// 取消标志管的是「别白干活」,代号管的是「别写错地方」,两件事
    private var integrityGeneration = 0
    /// 部分加密包的加密页数(单页失败卡片的「其余 %d 页可读」用)
    private var encryptedPageCount = 0

    // MARK: - 解压密码(v2,2026-09-17)

    /// 上一次密码尝试的失败提示(nil = 没失败过 / 已成功)。
    /// 全屏密码视图与阅读中的解锁面板共用 —— 它们本就是同一件事的两个入口
    @Published private(set) var passwordFailure: Failure?

    /// 阅读中解锁面板的显隐(部分加密包用;菜单命令置位,View 渲染 sheet)
    @Published var isUnlockSheetPresented = false

    /// 当前阅读的包里还有未解锁的加密页 → 「输入解压密码…」菜单可用。
    /// 全加密包在 open 阶段就进了 needsPassword,走不到这里
    var hasLockedPages: Bool {
        phase == .reading && encryptedPageCount > 0
    }

    /// 等待密码的归档 URL。**只在内存里** —— 与密码本身同一条规则:不落盘、
    /// 不进面包屑、不进崩溃报告。输入成功后立刻用它带密码重开
    private var pendingPasswordURL: URL?

    // MARK: - 续读记忆 / 书签(2026-09-15)

    private let progressStore: ReadingProgress
    private let bookmarkStore: Bookmarks
    /// 当前文档的身份键(打开成功后才有;nil = 未在阅读,不落进度/书签)
    private var documentKey: String?
    /// 恢复期间不回写进度(否则切档位的 didSet 会用页 0 覆盖掉已存的进度)
    private var isRestoringProgress = false

    /// 本书已标记的页(升序);换书时随文档刷新
    @Published private(set) var bookmarkedPages: [Int] = []
    /// 页码跳转面板显隐(菜单命令置位,View 渲染 sheet —— 命令不持有 View 状态)
    @Published var isJumpSheetPresented = false

    // MARK: - 完整性检查(2026-09-17)

    /// 检查状态。nil = 既没在检查也没有结果
    @Published private(set) var integrity: IntegrityState?

    /// 结果面板的显隐。与 `integrity` 分开:面板的显隐是**视图状态**,
    /// 而检查状态还要被测试直接断言 —— 混在一个字段里,测试就得为了
    /// 关面板而去动业务状态
    @Published var isIntegritySheetPresented = false

    enum IntegrityState: Equatable {
        /// 进行中(带进度:已检查 / 总页数)
        case running(checked: Int, total: Int)
        /// 结束(结果见 ArchiveIntegrityReport)。**取消也算结束** ——
        /// 报告里带着 stoppedEarly,界面上说「查到第 N 页就停了」比
        /// 「没有结果」有用得多
        case finished(ArchiveIntegrityReport)
    }

    /// 菜单可用性:只有正在阅读一份真实文档时才谈得上检查它
    var canCheckIntegrity: Bool {
        phase == .reading && document != nil && pageCount > 0
    }

    /// 开始检查(菜单命令入口)。重复触发 = 重新开始。
    ///
    /// 返回本次检查任务(与 `open(url:)` 同一套路):UI 忽略返回值,
    /// 测试可以 await 等状态机落定 —— 否则「等检查跑完」只能靠 sleep 猜时间,
    /// 而猜出来的时间既慢又不稳
    @discardableResult
    func checkIntegrity() -> Task<Void, Never>? {
        guard canCheckIntegrity, let document else { return nil }
        integrityTask?.cancel()

        let total = document.entries.count
        integrityGeneration += 1
        let generation = integrityGeneration
        integrity = .running(checked: 0, total: total)
        isIntegritySheetPresented = true
        Breadcrumbs.shared.record(.integrityCheckStarted(pages: total))

        // ⚠️ 闭包结构是刻意的(2026-09-17,写错过一次):
        // 外层 `Task.detached` 先 `[weak self]` + 一次 `guard let vm = self`,
        // 之后内外两层回调都只用这个**局部强引用 vm**。不要在里层再写
        // `[weak self]` —— 那会去捕获外层那个已经被弱化的 self,
        // 编译期直接报 "reference to captured var 'self' in concurrently-executing code"。
        // 代价是这次检查期间 VM 被强持有,而 VM 本就是 App 生命周期的对象,无妨
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let vm = self else { return }

            let report = ArchiveIntegrityChecker.check(
                document: document,
                // Task.isCancelled 在这里读到的是**本 detached 任务**的取消状态
                // (闭包是在它的线程上被同步调用的)—— 于是 VM 的 cancel 能穿到
                // 检查循环里去
                isCancelled: { Task.isCancelled },
                onProgress: { done in
                    Task { @MainActor in
                        // 代号不符 = 这一轮已经作废(换书了 / 又点了一次检查),
                        // 迟到进度不许写进当前状态
                        guard vm.integrityGeneration == generation,
                              case .running = vm.integrity else { return }
                        vm.integrity = .running(checked: done, total: total)
                    }
                })

            await MainActor.run {
                // 代号守卫:取消是协作式的,cancel() 之后后台循环可能还要跑一会儿。
                // 若这期间用户换了书,这一轮的结论已经**不属于**当前文档了
                guard vm.integrityGeneration == generation else { return }
                vm.integrity = .finished(report)
                vm.integrityTask = nil
                Breadcrumbs.shared.record(.integrityCheckFinished(
                    damaged: report.damagedCount, stoppedEarly: report.stoppedEarly))
            }
        }
        integrityTask = task
        return task
    }

    /// 中断检查(面板上的「停止」)。**保留已查到的结论** ——
    /// 报告会带 stoppedEarly,不是「白干了」
    func cancelIntegrityCheck() {
        integrityTask?.cancel()
    }

    /// 关掉结果面板。**同时清掉结论** —— 于是「点菜单」的语义永远是
    /// 「现在跑一遍」,不会出现「这次点开看到的是上次的结论」这种要命的歧义
    /// (检查结果关乎「要不要换源文件」,不能让人怀疑它是不是旧的)。
    /// 面板开着时点「完成」/按 Esc 也走这里,所以要顺手把还在跑的任务停掉
    func dismissIntegrity() {
        integrityTask?.cancel()
        integrityTask = nil
        integrityGeneration += 1
        isIntegritySheetPresented = false
        integrity = nil
    }

    // MARK: - 缩略图网格(v1.1,2026-09-18)

    /// 网格生成状态。形状与 `integrity` 同源(building/终态报告),
    /// 但多一层考虑:`building` 里带进度,是因为网格的**生成过程本身可见** ——
    /// 用户盯着面板看缩略图一张张出来,进度条告诉他「快好了」还是「别等了」
    @Published private(set) var grid: GridState?

    /// 网格面板的显隐。与 `grid` 分开的理由同 `isIntegritySheetPresented`:
    /// 面板开合是**视图状态**,而生成状态要被测试直接断言
    @Published var isGridSheetPresented = false

    enum GridState: Equatable {
        case building(done: Int, total: Int)
        /// 结束(结果见 `PageGridReport`)。**取消也算结束** ——
        /// 报告里带着 `.cancelled`,界面据此说「已停止 · 已生成 N 张」,
        /// 比「没有结果」有用得多
        case ready(PageGridReport)
    }

    /// 网格缩略图池。**跨面板开合保留** —— 重建一次要顺序扫全档
    /// (solid 7z 上是秒级),而缩略图**不会过期**:归档在打开期间不可变,
    /// 重扫只会得到一模一样的结果。真正的释放点是换书 / 关窗(见 `open` 与 teardown)。
    /// 上界由 `DesignSystem.PageBudget` 的两个网格预算钉住
    ///
    /// **每一轮生成新建一个池子**(而不是清空复用):后台扫描是同步写入的,
    /// 换书时旧扫描可能还在跑 —— 它继续写它那一轮创建出来的池子,
    /// 而 VM 已经指向新池子,污染不到。代次隔离靠**对象身份**,不靠标志位
    private var gridThumbs = ThumbnailStore()

    /// 上一次生成完成的报告。与池子同寿命 —— 有它就说明「池子里的东西是完整的」,
    /// 于是重开面板可以直接显示,不必重扫
    private var lastGridReport: PageGridReport?

    private var gridBuildTask: Task<Void, Never>?

    /// 「这一轮生成」的代号。理由与 `integrityGeneration` 完全一致:
    /// Task 的取消是**协作式**的,`cancel()` 之后后台那个同步 C 循环还要跑到
    /// 下一个检查点才发现。在它发现之前用户可能已经换了书 —— 那一刻收尾照常
    /// 执行,把**旧包的缩略图**塞进**新包的池子**。取消标志管「别白干活」,
    /// 代号管「别写错地方」,两件事
    private var gridGeneration = 0

    /// 菜单可用性:只有正在阅读一份真实文档时才谈得上生成它的缩略图
    var canShowGrid: Bool {
        phase == .reading && document != nil && pageCount > 0
    }

    /// 是否正在生成(面板据此把「停止」按钮画出来)
    var isGridBuilding: Bool {
        if case .building = grid { return true }
        return false
    }

    /// 打开网格面板。已有现成结果 → **直接显示,不重扫**(见 `lastGridReport`);
    /// 否则开始生成。返回本次生成任务(已有结果时为 nil)
    @discardableResult
    func showGrid() -> Task<Void, Never>? {
        guard canShowGrid else { return nil }
        isGridSheetPresented = true
        if let report = lastGridReport {
            grid = .ready(report)
            return nil
        }
        return buildGrid()
    }

    /// 重新生成(面板上的「重新生成」)。**丢弃现成的重扫一遍** ——
    /// 与「打开面板」分开,是因为两者的语义不同:打开是「给我看」,
    /// 重新生成是「我不信这份,重做」。混成一个动作会让「打开很快」
    /// 这件事变得不可预期
    @discardableResult
    func rebuildGrid() -> Task<Void, Never>? {
        lastGridReport = nil
        gridThumbs = ThumbnailStore()   // 丢弃旧池子(后台旧扫描写的是它,污染不到新的)
        return buildGrid()
    }

    /// 开始生成。重复触发 = 重新开始
    ///
    /// 返回本次生成任务(与 `checkIntegrity()` 同一套路):UI 忽略返回值,
    /// 测试可以 await 等状态机落定 —— 否则「等生成跑完」只能靠 sleep 猜时间
    @discardableResult
    func buildGrid() -> Task<Void, Never>? {
        guard canShowGrid, let document else { return nil }
        gridBuildTask?.cancel()

        let total = document.entries.count
        gridGeneration += 1
        let generation = gridGeneration
        // 本轮独占的池子:后台扫描**同步**写它,所以下面 `await task.value`
        // 返回时它已经填满 —— 不留「生成完成但图还没到」的时间窗。
        // 换一轮生成就换一个对象,旧扫描继续写旧对象(无害)
        let pool = ThumbnailStore()
        gridThumbs = pool
        grid = .building(done: 0, total: total)
        isGridSheetPresented = true
        Breadcrumbs.shared.record(.gridBuildStarted(pages: total))

        let maxPixel = DesignSystem.PageBudget.gridThumbnailLongEdge
        let budget = PageGridBudget.default

        // ⚠️ 闭包结构照抄 `checkIntegrity`(那里写错过一次,注释也留在那):
        // 外层 `Task.detached` 先 `[weak self]` + 一次 `guard let vm = self`,
        // 之后内外两层回调都只用这个**局部强引用 vm**。不要在里层再写
        // `[weak self]` —— 那会去捕获外层已被弱化的 self,编译期直接报
        // "reference to captured var 'self' in concurrently-executing code"
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let vm = self else { return }

            let report = PageGridBuilder.build(
                document: document,
                maxPixel: maxPixel,
                budget: budget,
                // `Task.isCancelled` 在这里读到的是**本 detached 任务**的取消状态
                // (闭包在它的线程上被同步调用)—— 于是 VM 的 cancel 能穿进扫描循环
                isCancelled: { Task.isCancelled },
                // **同步写池子**(不跳主线程):池子自带锁,扫描线程是它的合法写者。
                // 每张图回跳一次主线程的写法会凭空造 500 个任务,还会让
                // 「生成完成」与「图画得出来」之间隔出一个没人能断言的时间窗
                onThumbnail: { page, image in
                    pool.store(image, at: page)
                },
                onProgress: { done in
                    // 进度要回主线程(它是 @Published 状态),但**每 progressStride 页才一次**
                    // ——逐页回跳是另一个"500 个任务"的来源
                    Task { @MainActor in
                        guard vm.gridGeneration == generation,
                              case .building = vm.grid else { return }
                        vm.grid = .building(done: done, total: total)
                    }
                })

            await MainActor.run {
                // 代号守卫:取消是协作式的,cancel() 之后后台循环可能还要跑一会儿。
                // 若这期间用户换了书,这一轮的缩略图已经**不属于**当前文档了
                guard vm.gridGeneration == generation else { return }
                vm.lastGridReport = report
                // 面板可能已经被关掉了(关面板会 cancel 本轮)——
                // 那就只留报告,不往 `grid` 写一个没人看的终态
                if vm.isGridSheetPresented {
                    vm.grid = .ready(report)
                }
                vm.gridBuildTask = nil
                Breadcrumbs.shared.record(.gridBuildFinished(generated: report.generated,
                                                             stop: report.stop.token))
            }
        }
        gridBuildTask = task
        return task
    }

    /// 中断生成(面板上的「停止」)。**保留已生成的缩略图** ——
    /// 报告会带 `.cancelled`,不是「白干了」
    func cancelGridBuild() {
        gridBuildTask?.cancel()
    }

    /// 关掉网格面板。**池子与报告留着**(见 `gridThumbs` 的说明)——
    /// 真正的释放点是换书 / 关窗。这里只清视图状态
    ///
    /// 生成中关面板会**停掉生成**:不可见的重活不该继续烧 CPU 与磁盘
    /// (与 `dismissIntegrity` 同款判断)。已生成的部分留在池子里,
    /// 重开面板即见,想接着做得点「重新生成」
    func dismissGrid() {
        gridBuildTask?.cancel()
        isGridSheetPresented = false
        grid = nil
    }

    /// 取某页缩略图(nil = 还没生成到它 / 该页没有缩略图)。
    /// 纯查询,不触发任何工作 —— 网格滚动时每帧都会调它
    func gridThumbnail(at index: Int) -> CGImage? {
        gridThumbs.image(at: index)
    }

    // MARK: - 导出本卷页文件(⇧⌘E,2026-09-21)

    /// 导出状态。形状与 `grid` 同源(building/终态报告),同样是「用户主动触发的重活 + 过程可见」
    @Published private(set) var exportState: ExportState?

    /// 导出面板的显隐。与 `exportState` 分开的理由同前两个面板:
    /// 面板开合是**视图状态**,导出结论要被测试直接断言
    @Published var isExportSheetPresented = false

    enum ExportState: Equatable {
        case running(done: Int, total: Int)
        /// 结束(结果见 `PageSequenceReport`,来自 ArchiveKit)。**取消也算结束** ——
        /// 报告里带 `.cancelled`,界面据此说「已停止 · 已导出 N 页」,
        /// 比「没有结果」有用得多
        case ready(PageSequenceReport)
    }

    private var exportTask: Task<Void, Never>?

    /// 「这一轮导出」的代号。理由与 `gridGeneration` 完全一致:取消是**协作式**的,
    /// `cancel()` 之后后台那个同步循环还要跑到下一个检查点才发现;
    /// 在它发现之前用户可能已经换了书 —— 那一刻收尾照常执行,
    /// 会把**旧包的结论**贴到新书上
    private var exportGeneration = 0

    /// 菜单可用性:只有正在阅读一份真实文档时才谈得上导出它的页
    var canExportPages: Bool {
        phase == .reading && document != nil && pageCount > 0
    }

    /// 是否正在导出(面板据此把「停止」按钮画出来)
    var isExportRunning: Bool {
        if case .running = exportState { return true }
        return false
    }

    /// 导出全卷页文件到指定目录(目录由 `PageExportPanel` 授予写权限)。
    ///
    /// 返回本次导出任务(UI 忽略返回值;测试可 await 等待状态机落定)
    @discardableResult
    func exportPages(to directory: URL) -> Task<Void, Never>? {
        guard canExportPages, let document else { return nil }
        exportTask?.cancel()

        let total = document.entries.count
        let name = documentName
        exportGeneration += 1
        let generation = exportGeneration
        exportState = .running(done: 0, total: total)
        isExportSheetPresented = true
        Breadcrumbs.shared.record(.pageExportStarted(pages: total))

        // ⚠️ 闭包结构照抄 `buildGrid`(那里写错过一次,注释也留在那):
        // 外层 `Task.detached` 先 `[weak self]` + 一次 `guard let vm = self`,
        // 之后内外两层回调都只用这个**局部强引用 vm**。不要在里层再写
        // `[weak self]` —— 那会去捕获外层已被弱化的 self,编译期直接报错
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let vm = self else { return }

            let report = PageSequenceExporter.run(
                document: document,
                documentName: name,
                directory: directory,
                // `Task.isCancelled` 在这里读到的是**本 detached 任务**的取消状态
                // (闭包在它的线程上被同步调用)—— 于是 VM 的 cancel 能穿进导出循环
                isCancelled: { Task.isCancelled },
                onProgress: { done in
                    // 进度要回主线程(它是 @Published 状态),但循环里已按
                    // `progressStride` 节流过了 —— 逐页回跳是「几百个任务」的来源
                    Task { @MainActor in
                        guard vm.exportGeneration == generation,
                              case .running = vm.exportState else { return }
                        vm.exportState = .running(done: done, total: total)
                    }
                })

            await MainActor.run {
                // 代号守卫:取消是协作式的,cancel() 之后后台循环可能还要跑一会儿。
                // 若这期间用户换了书,这份报告已经**不属于**当前文档了
                guard vm.exportGeneration == generation else { return }
                // 面板可能已经被关掉了(关面板会 cancel 本轮)——
                // 那就只留着不往 `exportState` 写一个没人看的终态
                if vm.isExportSheetPresented {
                    vm.exportState = .ready(report)
                }
                vm.exportTask = nil
                Breadcrumbs.shared.record(.pageExportFinished(written: report.delivered,
                                                              stop: report.stop.token))
            }
        }
        exportTask = task
        return task
    }

    /// 中断导出(**已写出的文件留在磁盘上** —— 报告会带 `.cancelled`,
    /// 界面说的是「已停止 · 已导出 N 页」,不是「白干了」)。
    ///
    /// 刻意**不做回滚**:删掉用户看得见的文件比留着更糟 —— 他可能正要把那几张拿走,
    /// 而回滚一旦删错(比如目录里本来就有同名文件)是不可逆的
    func cancelExport() {
        exportTask?.cancel()
    }

    /// 关掉导出面板。导出中关面板会**停掉导出**(不可见的重活不该继续烧 CPU 与磁盘,
    /// 与 `dismissGrid` 同款判断),已写出的文件保留
    func dismissExport() {
        exportTask?.cancel()
        isExportSheetPresented = false
        exportState = nil
    }

    /// 存储可注入(单测用隔离 suite)
    init(progressStore: ReadingProgress = ReadingProgress(),
         bookmarkStore: Bookmarks = Bookmarks()) {
        self.progressStore = progressStore
        self.bookmarkStore = bookmarkStore
    }

    /// 清空全部续读进度与书签(「清空最近打开」连带调用,不留无主数据)
    func clearProgress() {
        progressStore.clear()
        bookmarkStore.clear()
        bookmarkedPages = []
    }

    // MARK: - 打开(图 3 主时序)

    /// 打开归档。重复调用 = 换书:旧 store 先 teardown,新任务不受旧任务干扰。
    ///
    /// passphrase(v2,2026-09-17):解压密码。nil = 未提供 —— 加密包不会被当成
    /// 失败,而是落到 `.needsPassword`,由 UI 提示输入后再带密码调一次本方法。
    /// 密码只以参数形式经过这里,不落任何存储。
    ///
    /// 返回本次打开任务(UI 忽略返回值;测试可 await 等待状态机落定)
    @discardableResult
    func open(url: URL, passphrase: String? = nil) -> Task<Void, Never> {
        openTask?.cancel()
        // 换书/重开:进行中的完整性检查针对的是**旧文档**,必须停掉 ——
        // 光 cancel 不够(协作式取消要等下一个检查点),代号 +1 才能让
        // 已经跑完、正排队等待回主线程的那次收尾**认出自己已作废**
        integrityTask?.cancel()
        integrityTask = nil
        integrityGeneration += 1
        integrity = nil
        // 面板也要关:旧包的结论留在屏幕上,用户会以为说的是刚打开这本
        isIntegritySheetPresented = false
        // 缩略图网格(v1.1):这是网格池**唯一**的释放点(关面板不清池子,
        // 见 `gridThumbs` 的说明)。同时代号 +1 —— 取消是协作式的,
        // 旧包的扫描循环可能还在后台跑,代号让它认不出自己已经作废,
        // 于是不会把旧包的缩略图塞进新书的池子
        gridBuildTask?.cancel()
        gridBuildTask = nil
        gridGeneration += 1
        lastGridReport = nil
        gridThumbs = ThumbnailStore()   // 换池子(对象身份即代次隔离,见 gridThumbs 说明)
        grid = nil
        isGridSheetPresented = false
        // 导出同理:进行中的导出读的是**旧文档**,而它的文件名前缀也来自旧书
        // (沿用旧的名字就会把新书的页写成一堆旧书名的文件)。只 cancel 不够 ——
        // 协作式取消要等一个检查点,代号 +1 才能让已经跑完、正排队等回主线程的
        // 那次收尾**认出自己已作废**
        exportTask?.cancel()
        exportTask = nil
        exportGeneration += 1
        exportState = nil
        isExportSheetPresented = false
        // 跳页预览同理:上一本书的预览图留在面板里是最容易发生的"张冠李戴"
        clearJumpPreview()
        let oldStore = store
        store = nil
        document = nil
        if let oldStore {
            Task { await oldStore.teardown() }
        }

        pageCount = 0
        pageIndex = 0
        // 滚动视角也是「上一本书的状态」:不清掉,换书后第一帧会先滚到旧书的页码
        // 再弹回来(新书往往页数更少,那一滚还可能被夹到末页)
        scrollTarget = nil
        scrollRowLoads = 0
        lastKnownAspect = 2.0 / 3.0
        encryptedPageCount = 0
        documentKey = nil          // 旧文档的进度键立即失效,换书后不得误写
        bookmarkedPages = []
        presentation = PagePresentation()
        secondary = nil
        documentName = url.lastPathComponent
        // 失败也保留:打开失败时「在访达里显示」恰恰最有用(去看一眼这文件到底是什么)
        documentURL = url
        // 上一轮的密码提示不跨书:换一个包就该干干净净地重新问
        passwordFailure = nil
        let task = Task { await performOpen(url: url, passphrase: passphrase) }
        openTask = task
        return task
    }

    private func performOpen(url: URL, passphrase: String?) async {
        phase = .opening
        do {
            // 加密四态预检 + 建索引全在 open 里(§5.9 图 10);终局态在此抛错。
            // 带密码打开时 ArchiveKit 已就地验证过密码(读得动才算对,见
            // ArchiveDocument.verifyPassphrase),所以走到这里就说明密码可用 ——
            // VM 不必也不该自己再验一次(那会多读一遍加密数据)
            //
            // ⚠️ **必须走 openOffMain**(2026-09-17 修):本方法是 @MainActor 隔离的,
            // 直接调 `ArchiveDocument.open` 会让列目录那段同步 I/O **在主线程跑完**。
            // 一个几万条目的大包或在网络卷上,就是几秒的整窗冻结 ——「打开大压缩包
            // 时转菊花假死」的根因。跨 actor 的 `await` 会把结果送回主线程,
            // 而重活留在后台
            let document = try await Self.openOffMain(url: url, passphrase: passphrase)
            try Task.checkCancellation()

            let store = PageStore(document: document)
            self.store = store
            self.document = document
            pageCount = document.entries.count
            if case .partial(let count) = document.protection {
                encryptedPageCount = count
            }
            // 打开成功 → 清掉密码流程的临时状态。密码本身住在 document 里
            // (读每一页都要用),VM 不留副本
            if passphrase != nil {
                // 只有真带密码打开过才记 —— 明文包不该产生这条事件
                Breadcrumbs.shared.record(.passphraseAttempt(success: true))
            }
            pendingPasswordURL = nil
            passwordFailure = nil
            isUnlockSheetPresented = false
            phase = .reading

            // 续读键:文件名 + 文件大小(stat 放后台,不占主线程,AGENTS.md 十二.1)
            let bytes = await fileSize(of: url)
            documentKey = ReadingProgress.key(name: url.lastPathComponent, size: bytes)

            // 面包屑:格式 + 大小桶(不含文件名)/ 页数 / 加密页数(§5.10.4 允许字段)
            Breadcrumbs.shared.record(.openArchive(format: Self.formatToken(document.format),
                                                   sizeBucket: Breadcrumbs.sizeBucket(bytes: bytes)))
            Breadcrumbs.shared.record(.indexBuilt(pages: document.entries.count))
            if encryptedPageCount > 0 {
                Breadcrumbs.shared.record(.encryptedPages(count: encryptedPageCount))
            }

            // 续读恢复:有记录 → 套用阅读模式 + 跳到上次页码;无记录 → 从封面开始
            var startPage = 0
            if let key = documentKey {
                bookmarkedPages = bookmarkStore.pages(forKey: key)
            }
            if let key = documentKey, let saved = progressStore.entry(forKey: key),
               document.entries.indices.contains(saved.page), saved.page > 0 {
                isRestoringProgress = true
                if let l = PageLayout(rawValue: saved.layout) { layout = l }
                if let d = ReadingDirection(rawValue: saved.direction) { direction = d }
                if let f = FitMode(rawValue: saved.fitMode) { fitMode = f }
                coverAlone = saved.coverAlone ?? false   // 老记录无此字段 → 关(旧行为)
                isRestoringProgress = false
                // 归一:存的是「当时在上屏的那一页」,双页下要落回所属摊的首面,
                // 否则会恢复出「主图是摊第二面」的错位摊(配对口径变过时尤其明显)
                startPage = layout.isSpread
                    ? SpreadPaging.spreadStart(for: saved.page, coverAlone: coverAlone)
                    : saved.page
                pageIndex = startPage    // 状态机页码同步(翻页语义全走 goTo,这里是对齐)
                Breadcrumbs.shared.record(.progressRestored(page: startPage))
            }

            // 滚动模式下还要把**视口**对齐到开篇页 —— 且必须在分支**外面**:
            // 无续读记录时 startPage = 0,视口同样需要一个显式的「回顶部」请求。
            // 否则就只剩「scrollTarget 为 nil 时系统会停在顶部」这种隐式约定,
            // 而它成立与否取决于 SwiftUI 换书时是否重建滚动容器(不该赌这个)
            requestScroll(to: startPage)
            await loadPage(startPage)
            await store.anchorDidChange(to: startPage)
        } catch is CancellationError {
            // 被更新的 open 抢占:不做任何状态写入,别覆盖新任务的结果
        } catch let error as ArchiveError {
            switch error {
            case .encrypted, .wrongPassphrase:
                // 需要密码 / 密码不对 —— 两者都是**流程中间态,不是失败**。
                // 刻意不记 openFailed:把它记成「打开失败」会让崩溃报告里出现
                // 一堆并不存在的故障。面包屑只记「要密码了」/「试错了一次」,
                // **密码本身绝不记录**(白名单也只放行 on/off 这种布尔标签)
                pendingPasswordURL = url
                if error == .wrongPassphrase {
                    Breadcrumbs.shared.record(.passphraseAttempt(success: false))
                    passwordFailure = Self.passwordFailure(for: error)
                } else {
                    Breadcrumbs.shared.record(.passphraseRequired)
                }
                phase = .needsPassword
            default:
                pendingPasswordURL = nil
                Breadcrumbs.shared.record(.openFailed(code: Self.failureCode(error)))
                phase = .failed(openFailure(for: error, url: url))
            }
        } catch {
            pendingPasswordURL = nil
            Breadcrumbs.shared.record(.openFailed(code: "unknown"))
            phase = .failed(openFailure(for: .corrupted, url: url))
        }
    }

    // MARK: - 在后台打开(2026-09-17)

    /// 把 `ArchiveDocument.open` 挪出主线程,并把**父任务的取消**转达给它。
    ///
    /// 两个都必须自己动手,不能指望语言默认行为:
    ///   · **线程**:`Task { }` 在 @MainActor 类型里会继承 MainActor 隔离,
    ///     所以「在 Task 里调 open」= 还是在主线程调 open。真正换线程要靠
    ///     `Task.detached`(它的闭包不继承 actor 上下文);
    ///   · **取消**:`Task.detached` 是**独立顶层任务**,父任务被 cancel 时
    ///     它不会收到任何通知。列目录循环是同步 C 代码,唯一的叫停方式就是
    ///     它自己轮询一个标志位 —— 故用 `withTaskCancellationHandler` 接住
    ///     父任务的取消,翻成标志位喂给 ArchiveKit 的 `isCancelled`。
    ///
    /// 少掉第二点会怎样:用户误开了一个 2GB 的包,马上改开另一个 —— 前一个
    /// 仍在后台一路啃到列完目录(几秒的 CPU + 随机读),白烧。
    private nonisolated static func openOffMain(url: URL,
                                                passphrase: String?) async throws -> ArchiveDocument {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try ArchiveDocument.open(url: url, passphrase: passphrase) { flag.isCancelled }
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: - 解压密码的输入与取消(v2,2026-09-17)

    /// 打开阶段的密码提交(全屏密码视图)。
    ///
    /// 刻意**不做 trim**:密码首尾的空格可能是有意义的字符,
    /// 替用户"顺手修正"输入是密码框最经典的 bug。空串直接忽略(UI 也会禁用按钮)
    func submitPassword(_ password: String) {
        guard !password.isEmpty, let url = pendingPasswordURL else { return }
        open(url: url, passphrase: password)
    }

    /// 阅读中解锁(部分加密包)的密码提交。与打开阶段**分开走两条路**,
    /// 原因见 `unlockWithPassword` 的说明
    func submitUnlockPassword(_ password: String) {
        guard !password.isEmpty else { return }
        Task { await unlockWithPassword(password) }
    }

    /// 放弃输入密码。两个入口的"放弃"含义不同:
    /// 打开阶段 → 回空态(就当没开过);阅读中 → 只关面板,阅读不动
    func cancelPasswordPrompt() {
        passwordFailure = nil
        if isUnlockSheetPresented {
            isUnlockSheetPresented = false
            return
        }
        pendingPasswordURL = nil
        // 不留「半打开」状态:清掉 documentURL,免得「在访达中显示」
        // 指向一个从未真正打开的归档(菜单可用但点了没意义,是很隐蔽的假状态)
        documentURL = nil
        documentName = nil
        phase = .noDocument
    }

    /// 阅读中触发解锁(部分加密包):菜单命令只置位,面板归 View 渲染
    func beginUnlock() {
        guard hasLockedPages else { return }
        passwordFailure = nil
        isUnlockSheetPresented = true
    }

    /// 阅读中解锁部分加密包。
    ///
    /// **刻意不走 `open()`** —— 那条路是"换书"语义:一上来就 teardown 旧 store、
    /// 清空页码与布局,于是密码打错一次就白屏一次,阅读上下文全丢。
    /// 这里反过来:**先带密码试开,成功了才替换 store**;失败则原地不动,
    /// 只在面板里说一句。页码 / 单双页 / 方向 / 缩放档位都没经过本次操作,自然保留。
    ///
    /// 解开之后 `encryptedPageCount` 归 0:不再有"读不出的页",
    /// 占位卡片与「其余 N 页可读」的文案随之消失
    private func unlockWithPassword(_ password: String) async {
        guard let url = documentURL else { return }
        do {
            // 同样必须走后台:带密码的 open 除了列目录还要**试读最多 8MB 加密数据**
            // 来验证密码(见 ArchiveDocument.verifyPassphrase),在主线程做就是
            // 实打实的可见卡顿
            let document = try await Self.openOffMain(url: url, passphrase: password)

            // 走到这里说明密码已确认可用(ArchiveKit 在 open 里就地验证过),
            // 下面这段是本次操作**唯一**会改动现状的地方
            let newStore = PageStore(document: document)
            let oldStore = store
            store = newStore
            self.document = document
            pageCount = document.entries.count
            encryptedPageCount = 0
            // 解锁换了文档:旧的完整性检查结果针对旧文档(加密页多、结论偏灰),
            // 留着会让用户以为「这个包有问题」——其实只是当时没密码
            integrityTask?.cancel()
            integrityTask = nil
            integrityGeneration += 1
            integrity = nil
            isIntegritySheetPresented = false
            // 网格同理:解锁前的池子里,加密页是**永久空白**(不是"还没扫到")。
            // 留着它,用户会以为那几页本来就没有缩略图 —— 其实只要重新生成就有。
            // 换的是 document,所以池子与报告一起作废
            gridBuildTask?.cancel()
            gridBuildTask = nil
            gridGeneration += 1
            lastGridReport = nil
            gridThumbs = ThumbnailStore()
            grid = nil
            isGridSheetPresented = false
            // 导出同理:解锁前的导出里,加密页是被**跳过**的(报告里那些是
            // 「没给密码」而不是读不出来)。留着那份结论,用户会以为那几页本来
            // 就导不出来 —— 其实再导一次就有了。换的是 document,报告一起作废
            exportTask?.cancel()
            exportTask = nil
            exportGeneration += 1
            exportState = nil
            isExportSheetPresented = false
            clearJumpPreview()
            Breadcrumbs.shared.record(.passphraseAttempt(success: true))
            await oldStore?.teardown()

            // 当前页用新 store 重取:之前那张是加密失败卡,现在该换成真图
            presentation.failure = nil
            presentation.isLoading = true
            secondary = nil
            isUnlockSheetPresented = false
            passwordFailure = nil
            await loadPage(pageIndex)
            await newStore.anchorDidChange(to: pageIndex)
        } catch is CancellationError {
            // 被取消(换书 / 关窗):不改任何状态,更不能报「密码不对」——
            // 用户什么都没输错,只是中途换了文件
        } catch let error as ArchiveError {
            Breadcrumbs.shared.record(.passphraseAttempt(success: false))
            passwordFailure = Self.passwordFailure(for: error)
        } catch {
            Breadcrumbs.shared.record(.passphraseAttempt(success: false))
            passwordFailure = Self.passwordFailure(for: .wrongPassphrase)
        }
    }

    /// 密码不通过时给用户看的那一句(全屏视图与解锁面板共用)。
    /// 文案 key 归 VM 产出、渲染归 View —— 与其余 Failure 同一套约定
    private static func passwordFailure(for error: ArchiveError) -> Failure {
        switch error {
        case .encryptedUnsupportedFormat, .headerEncrypted:
            // 库层面解不开:如实说明,别让用户继续对着密码框试
            return Failure(titleKey: "archive.password.unsupported.title",
                           bodyKey: "archive.password.unsupported.body", bodyArg: nil)
        default:
            return Failure(titleKey: "archive.password.wrong.title",
                           bodyKey: "archive.password.wrong.body", bodyArg: nil)
        }
    }

    // MARK: - 翻页(图 5 主链入口)

    /// 跳到指定页(越界自动夹紧;失败页重试:同页 + 已有失败卡也放行)。
    /// 双页模式下目标页会**归一到它所属那一摊的首面** —— 见 `SpreadPaging.spreadStart`
    func goTo(_ index: Int) {
        guard phase == .reading, store != nil, pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        let target = layout.isSpread
            ? SpreadPaging.spreadStart(for: clamped, coverAlone: coverAlone)
            : clamped

        // 滚动模式:页码由**视口**说了算(见 `scrollAnchorChanged`),这里只把
        // 视口挪过去。**不能顺手写 pageIndex** —— 那样在视口跟上之前的这一帧里,
        // HUD 会显示一个屏幕上根本没在看的页号
        if layout == .scroll {
            requestScroll(to: target)
            return
        }

        guard target != pageIndex || presentation.failure != nil else { return }

        pageIndex = target
        saveProgressNow()
        presentation.failure = nil
        presentation.isLoading = true
        secondary = nil   // 旧次页已失效,留白待新次页(不垫旧图,视觉上是「下一摊」)
        Task { await loadPage(target) }
    }

    func nextPage() {
        goTo(SpreadPaging.next(from: pageIndex, pageCount: pageCount,
                               dual: layout.isSpread, coverAlone: coverAlone))
    }

    func previousPage() {
        goTo(SpreadPaging.previous(from: pageIndex, pageCount: pageCount,
                                   dual: layout.isSpread, coverAlone: coverAlone))
    }

    // MARK: - 连续滚动(v2 候选池最后一项,2026-09-21)

    /// 视口顶部那一页 —— 驱动 `PageScrollView` 的 `scrollPosition(id:)`。
    /// **双向**:用户滚动时 SwiftUI 往里写;`goTo` / 换布局时我们也往里写。
    /// 分页模式下它是个惰性值(没人读也没人写),不参与渲染
    @Published var scrollTarget: Int? {
        didSet {
            guard let index = scrollTarget else { return }
            scrollAnchorChanged(to: index)
        }
    }

    /// 视口锚点变化 —— **滚动模式下页码的唯一来源**。
    ///
    /// 与分页模式的 `goTo` 是两条路:那边是「按下翻页 → 页码变 → 加载」,
    /// 这边是「视口滚到哪 → 页码跟着变」。把 `pageIndex` 的写权收在这一处,
    /// 才不会出现「页码和屏幕上那一页各说各话」——
    /// 而 HUD、书签、续读、窗口标题全都读 `pageIndex`。
    ///
    /// 预读不在这里另开一份:`loadPage` 末尾本来就会 `anchorDidChange`,
    /// 于是顺序扫描器的预读窗口天然跟着视口走(这正是滚动模式最需要的)——
    /// 少了它,solid 7z 上「滚下去」会退化成每页一次随机访问
    private func scrollAnchorChanged(to index: Int) {
        guard layout == .scroll, phase == .reading, pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        guard clamped != pageIndex else { return }
        pageIndex = clamped
        saveProgressNow()
        // 顺带把锚点页灌进 `presentation`(缓存在 `PageStore` 里,行视图多半
        // 已经解过,这里几乎不额外花钱)。用途两个:另存当前页(⌘S)在滚动模式下
        // 照常可用,以及切回分页模式时第一帧就是对的页
        Task { await loadPage(clamped) }
    }

    /// 滚动模式:请求把视口挪到某一页。**只请求,不写页码** ——
    /// 页码由 `scrollAnchorChanged` 回填,保证「页码 == 屏幕上那一页」恒成立
    private func requestScroll(to index: Int) {
        guard layout == .scroll, pageCount > 0 else { return }
        scrollTarget = min(max(index, 0), pageCount - 1)
    }

    /// 滚动模式:**行视图**取图的累计次数(诊断/取证用)。
    ///
    /// 为什么需要它:VM 自己也会读图(锚点页 + 预读),所以「缓存里有图」这件事
    /// **证明不了「行真的渲染了」** —— 而这两种失败长得完全不一样:
    /// 前者对后者错,屏幕上就是一片占位框。这个计数是「行在干活」的最小可核对证据,
    /// 也是唯一能证明**视口真的移动过**的机器信号(视口不动 → 新行不会 materialize
    /// → 计数不动)
    private(set) var scrollRowLoads = 0

    /// 滚动模式单行的加载结果。**带失败详情而不是只给 nil** ——
    /// 分页模式的失败卡片里有「此页已加密 → 去输密码」与「其余 %d 页可读」,
    /// 滚动模式的行同样需要它们(把错误吞成一个 nil 就等于把这些出路一起吞了)
    enum ScrollPageLoad {
        case image(CGImage)
        case failure(Failure)
    }

    /// 滚动模式:某一页的图(行视图按需调用)。缓存 / 去重 / 解码全在 `PageStore`,
    /// 这里只是转发(顺带计一次 `scrollRowLoads`)。
    ///
    /// **刻意不写「解码成功」面包屑**:一屏可能同时铺开好几行,每行都记会把诊断
    /// 文件淹成一片成功记录;真正有价值的信号是**锚点跨页**,那条已由
    /// `scrollAnchorChanged` → `loadPage` 记下。失败则相反 —— 一定要记
    func loadScrollPage(at index: Int) async -> ScrollPageLoad? {
        guard let store, phase == .reading else { return nil }
        do {
            let image = try await store.image(at: index)
            scrollRowLoads += 1
            return .image(image)
        } catch let error as ArchiveError {
            Breadcrumbs.shared.record(.pageFailed(index: index))
            return .failure(pageFailure(for: error))
        } catch {
            Breadcrumbs.shared.record(.pageFailed(index: index))
            return .failure(pageFailure(for: .corrupted))
        }
    }

    /// 滚动模式的行高估算基准:最近一次成功解码页的长宽比(宽 / 高)。
    ///
    /// **为什么必须有它**:行高若等图片到达才定,`LazyVStack` 里「上面那行一变高
    /// 就把下面全推走」会一路抖。同一本单行本的页尺寸几乎恒定,拿上一页的比例
    /// 当初值基本必然命中;混排的包也只是一次微调,而不是从零开始跳
    @Published private(set) var lastKnownAspect: CGFloat = 2.0 / 3.0

    func notePageAspect(_ aspect: CGFloat) {
        guard aspect > 0.01, abs(aspect - lastKnownAspect) > 0.001 else { return }
        lastKnownAspect = aspect
    }

    /// 配对口径变化(布局 / 封面单独)后,把当前页归一到所属摊并刷新两面。
    /// 不是摊首面时主图本身要换(否则会出现「主图是摊的第二面」的错位),
    /// 是摊首面时只补次页(主图不动、无闪烁)。
    /// **切换布局的唯一收口** —— 也是「进滚动模式时把视口对齐到当前页」的落点
    private func realignSpread() {
        guard phase == .reading, pageCount > 0 else { return }
        let target = layout.isSpread
            ? SpreadPaging.spreadStart(for: pageIndex, coverAlone: coverAlone)
            : pageIndex
        if target != pageIndex {
            pageIndex = target
            presentation.failure = nil
            presentation.isLoading = true
            secondary = nil
            Task { await loadPage(target) }
        } else {
            refreshSecondary()
        }
        requestScroll(to: pageIndex)
        saveProgressNow()
    }

    /// 布局/方向切换后,次页图立刻跟上(主图不动,无闪烁)
    private func refreshSecondary() {
        guard phase == .reading else { return }
        if let idx = secondaryIndex {
            Task { await loadSecondary(idx) }
        } else {
            secondary = nil
        }
    }

    /// 次页加载(仅双页;失败静默 —— 次页失败不换主图,与「单页失败 ≠ 整档失败」一致)
    private func loadSecondary(_ index: Int) async {
        guard let store, index == secondaryIndex else { return }
        secondary = try? await store.image(at: index)
    }

    private func loadPage(_ index: Int) async {
        guard let store else { return }

        // 无旧图时先垫缩略图(图 5 PLACE 分支:Trimmed 态翻回来不白屏)
        if presentation.image == nil,
           let thumb = await store.cachedThumbnail(at: index) {
            presentation.image = thumb
        }

        do {
            let image = try await store.image(at: index)
            // 竞态守卫:快速连翻时,迟到的旧页结果不得覆盖新页
            guard index == pageIndex, phase == .reading else { return }
            presentation.image = image
            presentation.isLoading = false
            presentation.failure = nil
            Breadcrumbs.shared.record(.pageDecode(index: index))
            await store.anchorDidChange(to: index)
            if let sec = secondaryIndex {
                await loadSecondary(sec)
            }
        } catch let error as ArchiveError {
            guard index == pageIndex, phase == .reading else { return }
            presentation.isLoading = false
            presentation.failure = pageFailure(for: error)
            Breadcrumbs.shared.record(.pageFailed(index: index))
        } catch {
            // 解码层只抛 ArchiveError,这里是防御性兜底(例如取消)
            guard index == pageIndex, phase == .reading else { return }
            presentation.isLoading = false
            presentation.failure = pageFailure(for: .corrupted)
            Breadcrumbs.shared.record(.pageFailed(index: index))
        }
    }

    // MARK: - 面包屑辅助(§5.10.4:只产「短标签」,绝不产路径 / 文件名)

    /// libarchive 判定的格式 → 短标签(sanitize 白名单内)
    private static func formatToken(_ format: ArchiveFormat) -> String {
        switch format {
        case .zip:      return "zip"
        case .sevenZip: return "7z"
        case .rar:      return "rar"
        case .tar:      return "tar"
        case .other:    return "other"
        }
    }

    /// 归档错误 → 短码。**刻意不记 `archive_error_string()` 原文**
    /// (§5.9.4 约束 6:那串英文可能含完整路径 —— 比设计文档 §5.9 的措辞更严一档)
    private static func failureCode(_ error: ArchiveError) -> String {
        switch error {
        case .corrupted:                return "corrupted"
        case .empty:                    return "empty"
        case .noImages:                 return "noImages"
        case .headerEncrypted:          return "headerEncrypted"
        case .encrypted:                return "encrypted"
        case .wrongPassphrase:          return "wrongPassphrase"
        case .encryptedUnsupportedFormat: return "encryptedUnsupported"
        case .unknown:                  return "unknown"
        }
    }

    /// 文件大小(字节)。stat 放后台,不占主线程(AGENTS.md 十二.1);
    /// 续读键与面包屑大小桶共用这一次 stat
    private func fileSize(of url: URL) async -> Int {
        await Task.detached(priority: .utility) {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        }.value
    }

    /// 回写续读进度(仅在阅读态且有进度键时;失败静默 —— 续读绝不致命)
    private func saveProgressNow() {
        guard phase == .reading, let key = documentKey, !isRestoringProgress else { return }
        progressStore.save(key: key,
                           page: pageIndex,
                           total: pageCount,
                           layout: layout.rawValue,
                           direction: direction.rawValue,
                           fitMode: fitMode.rawValue,
                           coverAlone: coverAlone)
    }

    // MARK: - 书签(2026-09-15)

    /// 当前页是否已标记
    var isCurrentPageBookmarked: Bool {
        bookmarkedPages.contains(pageIndex)
    }

    /// 标记 / 取消标记当前页
    func toggleBookmark() {
        guard phase == .reading, let key = documentKey else { return }
        let marked = bookmarkStore.toggle(page: pageIndex, key: key)
        bookmarkedPages = bookmarkStore.pages(forKey: key)
        Breadcrumbs.shared.record(.bookmarkToggled(page: pageIndex, marked: marked))
    }

    /// 跳到下一个书签(无更后面的书签 → 回到第一个;没有书签 → 不动)
    func goToNextBookmark() {
        guard phase == .reading, !bookmarkedPages.isEmpty else { return }
        let next = bookmarkedPages.first { $0 > pageIndex } ?? bookmarkedPages[0]
        goTo(next)
    }

    /// 跳到上一个书签(无更前面的书签 → 绕到最后一个)
    func goToPreviousBookmark() {
        guard phase == .reading, !bookmarkedPages.isEmpty else { return }
        let previous = bookmarkedPages.last { $0 < pageIndex } ?? bookmarkedPages[bookmarkedPages.count - 1]
        goTo(previous)
    }

    /// 清空本书全部书签
    func clearBookmarks() {
        guard let key = documentKey else { return }
        bookmarkStore.clearDocument(key: key)
        bookmarkedPages = []
    }

    // MARK: - 导出 / 窗口标题(v2,2026-09-16)

    /// 窗口标题:`文件名 · P.3/200`。多窗口与 Dock 悬停时能分辨「哪本、读到哪」
    /// (窗口标题由 App 层写进 NSWindow,VM 只产出文本)
    var windowTitle: String {
        guard phase == .reading, let documentName else { return L10n.tr("app.name") }
        return L10n.tr("reader.window.title", documentName, pageIndex + 1, pageCount)
    }

    /// 当前摊的上屏图用于导出(双页合成一张,并排顺序跟随阅读方向,见 `PageExport`)。
    /// 非阅读态 / 上屏图还没就绪 → nil(调用方据此禁用菜单项,不留"点了没反应")
    func exportImage() -> CGImage? {
        guard phase == .reading, let primary = presentation.image else { return nil }
        return PageExport.compose(primary: primary,
                                  secondary: layout.isSpread ? secondary : nil,
                                  rightToLeft: direction == .rightToLeft)
    }

    /// 导出建议文件名(与当前显示一致;只含文件名,不含路径)
    func exportFileName(format: PageExport.Format) -> String {
        PageExport.suggestedFileName(documentName: documentName, page: pageIndex,
                                     pageCount: pageCount, format: format)
    }

    // MARK: - 页码跳转(⌥⌘G)

    /// 解析用户输入 → 页码下标(1-based 输入,返回 0-based)。
    /// 容忍空格与全角数字;非法/越界 → nil(调用方不跳转,不留副作用)
    static func parsePageInput(_ text: String, pageCount: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pageCount > 0 else { return nil }
        // 全角数字 → 半角(中文输入法下很常见)
        let normalized = trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed
        guard let number = Int(normalized), number >= 1, number <= pageCount else { return nil }
        return number - 1
    }

    // MARK: - 跳页面板的目标页预览(v1.1,2026-09-18)

    /// 面板里那张目标页预览。nil = 还没取到(加载中 / 该页取不出来)
    @Published private(set) var jumpPreview: CGImage?
    /// 预览对应的页(0 起)。与 `jumpPreview` **配对**断言 ——
    /// 快速改输入时旧图可能比新图晚到,只有配对才判得出「这张是哪一页的」
    @Published private(set) var jumpPreviewPage: Int?
    /// 预览是否在取(界面显示小转圈)。**必须由 VM 说** ——
    /// 让 View 自己猜「输入变了但图还是旧的」会把同一件事的判断散到两处
    @Published private(set) var isJumpPreviewLoading = false
    /// 取不出来时的原因(加密 / 读不出)。**复用页级失败那套 key**,
    /// 不另造一套文案 —— 用户看到的是同一件事(这一页读不出来)
    @Published private(set) var jumpPreviewFailure: Failure?

    private var jumpPreviewTask: Task<Void, Never>?
    /// 代号守卫(与完整性检查、网格同一套):取消是协作式的,
    /// 迟到的预览不得覆盖新输入的结果
    private var jumpPreviewGeneration = 0

    /// 为某页取一张预览图(页码 0 起)。
    ///
    /// **防抖刻意放在 View 侧** —— 防抖长度是「打字节奏」这种界面感受,
    /// 不是业务规则;本方法只管「给我第 N 页的预览」,于是可被单测直接调用。
    ///
    /// 取值**优先走网格池**:已经生成过就直接命中,零 I/O —— 这是
    /// 「先开了网格再跳页」这条常见路径的白拿收益。池子没有才真去读一页。
    ///
    /// 返回本次取图任务(与 `open` / `checkIntegrity` 同一约定):UI 忽略返回值,
    /// 测试可以 await 等状态落定。**池子命中时返回 nil** —— 那是同步完成的,
    /// 没有任务可等,而这一点本身也值得被断言(命中就不该产生任何异步工作)
    @discardableResult
    func previewJumpTarget(_ index: Int) -> Task<Void, Never>? {
        guard phase == .reading, let store, pageCount > 0 else { return nil }
        let clamped = min(max(index, 0), pageCount - 1)

        // 同一页重复请求直接吃掉:防抖后仍可能连点,而每次请求在包里都是
        // 一次真实读取 —— 去重比让它们排队便宜得多
        if jumpPreviewPage == clamped, jumpPreview != nil || isJumpPreviewLoading {
            return nil
        }

        jumpPreviewTask?.cancel()
        jumpPreviewGeneration += 1
        let generation = jumpPreviewGeneration

        // 池子命中:同步返回,连转圈都不该闪一下
        if let cached = gridThumbs.image(at: clamped) {
            jumpPreview = cached
            jumpPreviewPage = clamped
            jumpPreviewFailure = nil
            isJumpPreviewLoading = false
            return nil
        }

        jumpPreviewFailure = nil
        isJumpPreviewLoading = true
        let maxPixel = DesignSystem.PageBudget.jumpPreviewLongEdge

        let task = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<CGImage, Error>
            do {
                outcome = .success(try await store.previewImage(at: clamped, maxPixel: maxPixel))
            } catch {
                outcome = .failure(error)
            }
            // 取消 / 过期一律丢弃:用户已经改了输入,这张图不再是他要的
            guard !Task.isCancelled, self.jumpPreviewGeneration == generation else { return }
            switch outcome {
            case .success(let image):
                self.jumpPreview = image
                self.jumpPreviewFailure = nil
            case .failure(let error):
                self.jumpPreview = nil
                self.jumpPreviewFailure = self.pageFailure(for: error as? ArchiveError ?? .corrupted)
            }
            self.jumpPreviewPage = clamped
            self.isJumpPreviewLoading = false
        }
        jumpPreviewTask = task
        return task
    }

    /// 清掉预览(面板关闭时调)。**不清池子** —— 池子归网格管,寿命不同
    func clearJumpPreview() {
        jumpPreviewTask?.cancel()
        jumpPreviewGeneration += 1
        jumpPreview = nil
        jumpPreviewPage = nil
        jumpPreviewFailure = nil
        isJumpPreviewLoading = false
    }

    // MARK: - 错误 → 文案 key(§5.9.3.1 分流)

    /// 归档级失败分流。7z 与 RAR 共用 encryptedUnsupportedFormat 但文案措辞
    /// 必须区分(§5.9.1:7z 实测不支持,RAR 是推断)—— open 失败拿不到 libarchive
    /// 的 format 判定,按扩展名分流(用户视角等价)
    private func openFailure(for error: ArchiveError, url: URL) -> Failure {
        switch error {
        case .corrupted, .unknown:
            return Failure(titleKey: "archive.corrupted.title",
                           bodyKey: "archive.corrupted.body", bodyArg: nil)
        case .empty:
            // §5.9.3.1 未定义「0 条目」组,M2 补最小文案,M3 一并润色
            return Failure(titleKey: "archive.empty.title",
                           bodyKey: "archive.empty.body", bodyArg: nil)
        case .noImages(let found):
            return Failure(titleKey: "archive.noImages.title",
                           bodyKey: "archive.noImages.body", bodyArg: found)
        case .headerEncrypted:
            return Failure(titleKey: "archive.encrypted.header.title",
                           bodyKey: "archive.encrypted.header.body", bodyArg: nil)
        case .encrypted:
            return Failure(titleKey: "archive.encrypted.title",
                           bodyKey: "archive.encrypted.zip.body", bodyArg: nil)
        case .wrongPassphrase:
            // 正常流程到不了这里:`.encrypted` / `.wrongPassphrase` 在 performOpen
            // 里已被分流到 .needsPassword(它们不是失败)。留这条只为 switch 穷尽,
            // 万一将来有人改了分流,也不会掉进"无文案可显示"的空洞
            return Self.passwordFailure(for: .wrongPassphrase)
        case .encryptedUnsupportedFormat:
            let isRar = ["cbr", "rar"].contains(url.pathExtension.lowercased())
            return Failure(titleKey: isRar ? "archive.encrypted.rar.title" : "archive.encrypted.7z.title",
                           bodyKey: isRar ? "archive.encrypted.rar.body" : "archive.encrypted.7z.body",
                           bodyArg: nil)
        }
    }

    /// 页级失败分流(部分加密包里的加密页 → 占位卡片;其余 → 单页读取失败)
    private func pageFailure(for error: ArchiveError) -> Failure {
        switch error {
        case .encrypted, .encryptedUnsupportedFormat, .wrongPassphrase:
            // wrongPassphrase 与 encrypted 同路:都是「这一页没解开」。
            // 密码不对在 open 阶段就被拦下了,走到这里只可能是
            // 「部分加密包没输密码」(占位卡片的常规场景)
            let readable = max(pageCount - encryptedPageCount, 0)
            return Failure(titleKey: "archive.page.encrypted.title",
                           bodyKey: "archive.page.encrypted.subtitle", bodyArg: readable)
        case .corrupted, .unknown, .headerEncrypted, .empty, .noImages:
            return Failure(titleKey: "archive.page.failed.title",
                           bodyKey: "archive.page.failed.body", bodyArg: nil)
        }
    }
}

// MARK: - 取消标志(2026-09-17,配合 openOffMain)

/// 只做一件事:把一个「父任务已被取消」的布尔,安全地从 `onCancel` 递给
/// 后台线程上那个**同步**列目录循环。
///
/// 为什么不用 actor:读它的一方是 libarchive 的 C 循环,同步执行、不能 await ——
/// 而 actor 的访问点全是 async。这正是「必须同步共享」的场合,锁是唯一解。
/// `@unchecked Sendable` 是诚实声明:线程安全靠下面那把 NSLock,**不是**靠
/// 编译器能证明的隔离(别把这两个混为一谈)
private final class CancellationFlag: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

