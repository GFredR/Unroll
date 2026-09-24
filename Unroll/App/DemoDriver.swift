// AI-Generated | 可修改
// DemoDriver.swift —— 演示 / 取证驱动(仅 DEBUG 构建,不进 Release)
// ============================================================================
// 为什么需要它:录制 README 的演示 GIF 需要"自动翻页",UI 取证需要"自动打开
// 某个面板",而这两件事都得靠按键 —— 用 osascript/CGEvent 注入按键会被
// TCC(辅助功能)拦掉,那是系统安全边界,不该去绕。这里改成 App 自己按固定
// 时间轴驱动 ViewModel:零授权、可重现、每次跑出来一模一样。
//
// 触发:标记文件(**用文件名区分场景**),放在容器 tmp/
//   demo-enabled  → 翻页演示(录 GIF 用,时间轴与 2026-09 完全一致)
//   demo-grid     → 缩略图网格**层**(⇧⌘G)取证
//   demo-jump     → 页码跳转面板 + 侧边预览(⌥⌘G)取证
//   demo-scroll   → 连续滚动(⌘0)取证(下行 + 回程,见 runScroll 的判据说明)
//   demo-export   → 导出本卷页文件(⇧⌘E)面板取证(真导一遍,见 runExport 的判据说明)
//   demo-hint     → 首次阅读提示条取证(见 runHint 的判据说明)
//   demo-chrome   → 阅读层周边控件(左栏 / 翻页箭头)取证(见 runChrome 的判据说明)
//   demo-quit     → **优雅退出**链路取证(见 runQuit 的判据说明)。⚠️ 它会真的把
//                   App 退掉,所以没有截图 —— 判据在磁盘上,用 Scripts/probe-graceful-exit.sh 跑
//
// 为什么用标记文件而不是 argv:`open --args` 在 macOS 15 上实测**传不进 App**
// (LaunchServices 会过滤未知 argv;2026-09-20 用探针 App 复核 —— 经 `open`
// 启动 argc=1,直接 exec 才有 4 个参数)。标记文件是唯一可靠的入口。
// 环境变量 UNROLL_DEMO_SCRIPT 仍作兜底(值 grid/jump 选场景,其它非空值 = 翻页)。
//
// 录制脚本见 Scripts/record-demo.sh;
// UI 取证见 Scripts/verify-ui.sh(ONLY=grid / ONLY=jump / ONLY=scroll / ONLY=export / ONLY=hint / ONLY=chrome)。
// 不需要演示时:直接删掉本文件 + UnrollApp.swift 里那一处 #if DEBUG 调用即可。
//
// 调试:每个节点写一行到容器 tmp/demo-driver.log
//   ~/Library/Containers/com.gfredr.unroll/Data/tmp/demo-driver.log
// grid / jump 收尾时多写一行 `scene=xx key=value …` —— 那是给 verify-ui.sh
// 做**机器断言**用的:截图只证明"长得对",状态行才证明"数据对"
// (比如网格的 generated 是否等于 pages、预览的 previewPage 是否等于当前页)。
// ============================================================================
#if DEBUG
import AppKit
import Foundation

@MainActor
enum DemoDriver {

    // MARK: - 场景

    /// 驱动场景。**标记文件名就是场景名**,一个文件名表达一件事,
    /// 不必再解析文件内容(内容为空、被截断、带 BOM 都不会误判)
    enum Scene: String, CaseIterable {
        /// 翻页演示(录 README 的 GIF)。时间轴刻意不动 —— record-demo.sh
        /// 靠它同步录制起点
        case paging = "demo-enabled"
        /// 缩略图网格面板(⇧⌘G)
        case grid = "demo-grid"
        /// 页码跳转面板 + 侧边预览(⌥⌘G)
        case jump = "demo-jump"
        /// 连续滚动(⌘0)。**必须真的是「滚」**:见 `runScroll` 的判据说明
        case scroll = "demo-scroll"
        /// 导出本卷页文件(⇧⌘E)。**真导一遍**并数磁盘:见 `runExport` 的判据说明
        case export = "demo-export"
        /// 首次阅读提示条(2026-09-22)。**它自己只出现一次**,所以这个场景
        /// 靠 `showHintBar()` 显式调出来 —— 与菜单里那一项走的是同一个方法
        case hint = "demo-hint"
        /// 阅读层周边控件(左侧缩略图栏 + 左右翻页箭头,2026-09-23)
        case chrome = "demo-chrome"
        /// **优雅退出**(2026-09-24)。它是唯一一个会真的结束进程的场景,
        /// 因此不能进 verify-ui.sh(那套流程要等一张截图,而这里没有窗口可拍)——
        /// 判据落在容器里的 `session.json` 与 `breadcrumbs.log` 上,
        /// 由 Scripts/probe-graceful-exit.sh 检查
        case quit = "demo-quit"

        /// 认全名(`demo-grid`)与简写(`grid`)。**认不出返回 nil**,由调用方决定
        /// 兜底 —— 环境变量那条路的旧语义是「随便给个非空值就翻页」,
        /// 不能在这里硬塞默认值,否则以后加场景时会静默走错分支
        static func parse(_ token: String) -> Scene? {
            switch token {
            case Scene.grid.rawValue, "grid": return .grid
            case Scene.jump.rawValue, "jump": return .jump
            case Scene.scroll.rawValue, "scroll": return .scroll
            case Scene.export.rawValue, "export": return .export
            case Scene.hint.rawValue, "hint": return .hint
            case Scene.chrome.rawValue, "chrome": return .chrome
            case Scene.quit.rawValue, "quit": return .quit
            default: return nil
            }
        }
    }

    static let flagDir = FileManager.default.temporaryDirectory

    /// 某场景的标记文件路径。容器的 tmp/ 目录
    static func flagURL(for scene: Scene) -> URL {
        flagDir.appendingPathComponent(scene.rawValue)
    }

    /// 当前生效的场景;nil = 不驱动。
    ///
    /// 判定顺序:**专有场景优先,最后才是 paging** —— 于是「同时存在多个标记
    /// 文件」也不会随机选一个(grid 与 paging 并存时走 grid,因为放 grid 标记的
    /// 人显式要的就是 grid)。历史行为(随便放个标记就开始翻页)原样保留。
    static var activeScene: Scene? {
        // 测试宿主就是 App 本身:测试进程里绝不启动驱动。否则标记文件一旦因录制
        // 中途异常而残留,自动翻页就会打乱用例,表现为「莫名其妙的失败」。
        guard !UnrollRuntime.isTesting else { return nil }

        // ⚠️ `.quit` 排在最前:它会结束进程,若某个旧标记没清干净而它排在后头,
        //    就等于"取证跑完了却没验退出"。其余顺序沿用历史行为。
        for scene in [Scene.quit, .grid, .jump, .scroll, .export, .hint, .chrome, .paging]
        where FileManager.default.fileExists(atPath: flagURL(for: scene).path) {
            return scene
        }
        // argv / env 兜底(本机通常到不了这儿,保留是为别的执行环境与手工调试)
        if let raw = ProcessInfo.processInfo.environment["UNROLL_DEMO_SCRIPT"] {
            return Scene.parse(raw) ?? .paging
        }
        if ProcessInfo.processInfo.arguments.contains("-demoScript") { return .paging }
        return nil
    }

    private static var hasStarted = false
    private static let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("demo-driver.log")

    private static func log(_ message: String) {
        let line = String(format: "%.2f %@\n", Date().timeIntervalSince1970, message)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// 在 App 视图 onAppear 时调用。文档可能还没打开(外部 `open <file>` 随后才到),
    /// 所以这里先等 pageCount 出现,再开始。
    static func startIfNeeded(on viewModel: ReaderViewModel) {
        let argv = ProcessInfo.processInfo.arguments.joined(separator: " ")
        let envHit = ProcessInfo.processInfo.environment["UNROLL_DEMO_SCRIPT"] ?? "nil"
        let scene = activeScene
        let flags = Scene.allCases
            .filter { FileManager.default.fileExists(atPath: flagURL(for: $0).path) }
            .map(\.rawValue).joined(separator: ",")
        log("onAppear scene=\(scene?.rawValue ?? "none") flags=[\(flags)] argv=[\(argv)] env=\(envHit) "
            + "markerAtAppear=\(ReaderTips().hasShownHintBar ? 1 : 0)")
        guard let scene, !hasStarted else { return }
        hasStarted = true
        Task { await waitForDocument(scene: scene, on: viewModel) }
    }

    private static func waitForDocument(scene: Scene, on vm: ReaderViewModel) async {
        // 退出场景**不等文档**:要验的是"退出那一刻的收尾",它与有没有打开归档无关。
        // 硬等一个文档只会把一个能跑的取证变成"样本没送到就什么都不做" —— 而
        // "什么都没做"在这类脚本里的表现是超时,看起来像退出链路坏了,实际不是。
        if scene == .quit {
            log("scene=\(scene.rawValue) 跳过等文档(退出链路与是否打开归档无关)")
            await runQuit()
            return
        }

        // 最多等 30s 让外部 `open <file>` 把文档送进来
        var ticks = 0
        while vm.pageCount == 0 && ticks < 300 {
            try? await Task.sleep(for: .milliseconds(100))
            ticks += 1
        }
        log("document ready pageCount=\(vm.pageCount) waited=\(ticks * 100)ms")
        guard vm.pageCount > 0 else {
            log("scene=\(scene.rawValue) aborted: no document")
            return
        }

        switch scene {
        case .paging:
            await enterFullScreen()
            await runPaging(on: vm)
        case .grid:
            await prepareForProbe(on: vm)
            await runGrid(on: vm)
        case .jump:
            await prepareForProbe(on: vm)
            await runJump(on: vm)
        case .scroll:
            await runScroll(on: vm)
        case .export:
            await prepareForProbe(on: vm)
            await runExport(on: vm)
        case .hint:
            await prepareForProbe(on: vm)
            await runHint(on: vm)
        case .chrome:
            await prepareForProbe(on: vm)
            await runChrome(on: vm)
        case .quit:
            // 正常情况下到不了这里(上面已提前 return);留着是为了让 switch 保持
            // 穷尽 —— 少一个 case 编译不过,这是**好事**:以后加场景时会当场被提醒,
            // 而不是静默走不到。
            await runQuit()
        }
    }

    // MARK: - 翻页演示(录 GIF)

    /// 进全屏再演示。两个理由:
    ///   ① 窗口模式下 `screencapture -R` 会连同窗口圆角外的一圈桌面一起录进去
    ///      (窗口 bounds 比可视窗口略大),而全屏没有这个问题;
    ///   ② 全屏正是阅读器的主场景(沉浸阅读),演示效果更好。
    /// 这只在演示模式下发生;录制脚本会备份并还原窗口偏好。
    private static func enterFullScreen() async {
        try? await Task.sleep(for: .milliseconds(500))
        let windows = NSApp.windows
        log("windows=\(windows.count) " + windows.map {
            "[vis=\($0.isVisible) main=\($0.canBecomeMain) \(Int($0.frame.width))x\(Int($0.frame.height))]"
        }.joined(separator: " "))
        if let window = NSApp.mainWindow ?? windows.first(where: { $0.isVisible }) {
            window.toggleFullScreen(nil)
            log("fullscreen toggled")
        } else {
            log("no visible window found")
        }
        // 等全屏动画 + 重新布局 + 首页解码,免得录到加载态
        try? await Task.sleep(for: .seconds(2.4))
    }

    /// 固定时间轴。总长约 9s,配合录制脚本的时长设置。
    /// ⚠️ **不要改动这里的节奏**:record-demo.sh 按时间点抽静态帧
    /// (`-ss 5.8` 取跨页、`-ss 2.0` 取单页),改了就得同步改脚本。
    private static func runPaging(on vm: ReaderViewModel) async {
        log("run start")
        // 2026-09-23 起文档打开后停在**网格层**。这条时间轴录的是"翻页"这件事,
        // 所以先切进阅读层 —— 否则 GIF 的开头会是一张网格。
        // ⚠️ 想让 GIF 反而**展示**"打开 → 网格 → 点进大图"这条新主链的话,
        // 要重排时间轴并同步改 record-demo.sh 的抽帧点,那是另一件事(未做)
        vm.showReader()
        // 从上一次录制的续读状态复位(样本可能被读过,续读会把人带到中间页)
        vm.layout = .single
        vm.direction = .leftToRight
        vm.fitMode = .fitWindow
        vm.goTo(0)
        try? await Task.sleep(for: .seconds(1.6))   // 封面停留(让观众看清)

        vm.nextPage()                                // → p2
        log("page \(vm.pageIndex)")
        try? await Task.sleep(for: .seconds(0.9))
        vm.nextPage()                                // → p3
        log("page \(vm.pageIndex)")
        try? await Task.sleep(for: .seconds(0.9))
        vm.nextPage()                                // → p4
        log("page \(vm.pageIndex)")
        try? await Task.sleep(for: .seconds(0.9))

        vm.layout = .dual                            // p4 + p5 跨页
        log("dual")
        try? await Task.sleep(for: .seconds(1.2))
        vm.nextPage()                                // → p6 + p7
        log("page \(vm.pageIndex)")
        try? await Task.sleep(for: .seconds(1.2))
        vm.nextPage()                                // → p8
        log("page \(vm.pageIndex)")
        try? await Task.sleep(for: .seconds(1.3))

        vm.layout = .single                          // 回封面,便于 GIF 无缝循环
        vm.goTo(0)
        log("run done")
    }

    // MARK: - 取证场景(网格 / 跳转面板)

    /// 取证场景的公共准备。两件事:
    ///
    /// ① 把可能被**续读**带偏的状态压回可预期的起点。不复位的话,同一份样本
    ///    第二次跑会因为进度记忆停在上次的页上,截出来的图每次都不同 ——
    ///    取证最忌讳"看起来一样其实不一样";
    ///
    /// ② **切到阅读层**(2026-09-23 加「打开即网格」时补)。文档一就绪,界面停在
    ///    **网格层**;而调本方法的这几个场景(grid 之外)验的都是**画布**上的东西。
    ///    不切层的话每张截图拍到的都是网格 —— 而状态行仍然是对的,于是
    ///    「截图证观感」这一半**静默失效**(与 §11.9 那条"守卫的第二种失效"同型:
    ///    把正常状态说成故障只是其中一种,这里是把失效说成正常)
    private static func prepareForProbe(on vm: ReaderViewModel) async {
        vm.layout = .single
        vm.direction = .leftToRight
        vm.fitMode = .fitWindow
        vm.showReader()
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// 场景:缩略图网格层(⇧⌘G)。
    ///
    /// 停在**第二页**而不是封面:当前页在网格里有一圈品牌色描边,
    /// 停在第 1 页的话那圈描边落在左上角第一格,不容易看出"它在跟页码走"。
    /// (2026-09-23 起还多一层:网格会自动滚到当前页,而第 1 页恰好就是初始位置,
    /// 于是"自动定位"这件事在封面页上根本看不出来)
    private static func runGrid(on vm: ReaderViewModel) async {
        vm.goTo(min(1, max(vm.pageCount - 1, 0)))
        try? await Task.sleep(for: .milliseconds(900))

        // ⚠️ 打开即网格之后网格**本来就是默认层**(`prepareForProbe` 刚切到阅读层,
        // 这里再切回来)。这一步仍然要显式调 —— 它走的正是「阅读层按浏览回来」
        // 那条路径,顺带把那条路径也覆盖进取证
        vm.showGrid()
        log("scene=grid layer=browse")

        // 等生成**真正结束**。面板上的进度条在生成中是个中间值,
        // 拿它当截图依据会拍到半成品 —— 而半成品恰好是"看起来没问题"的假证据
        var ticks = 0
        while vm.isGridBuilding, ticks < 300 {          // 上限 30s
            try? await Task.sleep(for: .milliseconds(100))
            ticks += 1
        }
        // 生成结束 ≠ 画完:给 SwiftUI 一拍时间把最后几张摆上去
        try? await Task.sleep(for: .milliseconds(700))

        var thumbs = 0
        for i in 0..<vm.pageCount where vm.gridThumbnail(at: i) != nil { thumbs += 1 }

        var stop = "nil", pages = vm.pageCount, generated = 0, skipped = 0, failed = 0
        if let state = vm.grid, case .ready(let report) = state {
            stop = report.stop.token
            pages = report.pages
            generated = report.generated
            skipped = report.skippedEncrypted
            failed = report.failedCount
        }
        log("scene=grid pages=\(pages) generated=\(generated) stop=\(stop) "
            + "skipped=\(skipped) failed=\(failed) thumbs=\(thumbs) "
            + "current=\(vm.pageIndex) waited=\(ticks * 100)ms")
    }

    /// 场景:页码跳转面板的侧边预览(⌥⌘G)。
    ///
    /// **刻意不去动输入框里的文字**:那是面板 View 的私有 `@State`,
    /// 从外面改不了。而面板 `onAppear` 本来就会预填当前页并立刻取一张预览 ——
    /// 于是"输入框显示几"与"预览是哪一页"天然一致,截图不会自相矛盾。
    /// 想看另一页的预览:先把阅读位置移过去,再开面板。
    private static func runJump(on vm: ReaderViewModel) async {
        // 停在中间某页:拿封面当预览说服力太弱(第一页容易被当成占位图)
        vm.goTo(min(2, max(vm.pageCount - 1, 0)))
        try? await Task.sleep(for: .milliseconds(900))

        vm.isJumpSheetPresented = true
        // onAppear 预填 + 输入防抖 300ms 之后才真正去取图,先给它一拍
        try? await Task.sleep(for: .milliseconds(600))

        var ticks = 0
        while ticks < 150 {                              // 上限 15s
            if !vm.isJumpPreviewLoading,
               vm.jumpPreview != nil || vm.jumpPreviewFailure != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
            ticks += 1
        }
        try? await Task.sleep(for: .milliseconds(400))

        let hasPreview = vm.jumpPreview != nil ? 1 : 0
        let hasFailure = vm.jumpPreviewFailure != nil ? 1 : 0
        let loading = vm.isJumpPreviewLoading ? 1 : 0
        log("scene=jump current=\(vm.pageIndex) "
            + "previewPage=\(vm.jumpPreviewPage.map(String.init) ?? "nil") "
            + "hasPreview=\(hasPreview) failure=\(hasFailure) loading=\(loading) "
            + "waited=\(ticks * 100)ms")
    }

    /// 场景:连续滚动(⌘0)。
    ///
    /// **判据怎么分**(这条场景比前两条更需要说清):
    ///   · `first` / `mid` / `back` 三个锚点值证明的是**锚点漏斗接通了**
    ///     —— 写 `scrollTarget` 之后 `pageIndex` 跟着走、且来回都对得上。
    ///     它**不是**「视口真的滚了」的证据:程序化设值会在同一次设值里同步回填,
    ///     所以哪怕滚动视图根本没动,这三个数也会是对的。
    ///   · 「视口真的动了」只能靠 **`rowLoads` 的增量**:那个计数**只由行视图**
    ///     累加(VM 自己读图与预读都不计入)。视口不动 → 新行不会 materialize
    ///     → 计数不涨。这是本场景里唯一的机器硬证据。
    ///   · 观感(一列铺开、图与图之间的间距、滚动条)仍然由截图负责。
    ///
    /// 只验"能滚"是不够的,所以刻意排了**下行 + 回程**两段:回程覆盖的是
    /// 「向上滚动」那条路 —— solid 7z 上后向访问会让顺序扫描器重开(O(已读页数)),
    /// 一趟回程就能把「有没有退化到卡死」直接暴露出来
    private static func runScroll(on vm: ReaderViewModel) async {
        // 本场景不调 `prepareForProbe`(它自己设 layout),但**同样必须先进阅读层** ——
        // 连续滚动是画布的第三种版面,在网格层上根本不存在
        vm.showReader()
        vm.layout = .scroll
        try? await Task.sleep(for: .milliseconds(900))

        // 起点:第 2 页(封面当锚点太容易被误读成"只有一页")
        vm.goTo(min(1, max(vm.pageCount - 1, 0)))
        try? await Task.sleep(for: .seconds(1.4))
        let first = vm.pageIndex
        let loadsBefore = vm.scrollRowLoads

        // 下行:跳到最后几页之前(留几行在后面,让视口下方仍有内容)
        let expectedMid = max(vm.pageCount - 3, 0)
        vm.scrollTarget = expectedMid
        try? await Task.sleep(for: .seconds(2.0))
        let mid = vm.pageIndex
        let loadsAfter = vm.scrollRowLoads

        // 回程:回到起点
        vm.scrollTarget = first
        try? await Task.sleep(for: .seconds(2.0))
        let back = vm.pageIndex

        log("scene=scroll layout=\(vm.layout.rawValue) pages=\(vm.pageCount) "
            + "first=\(first) mid=\(mid) expectedMid=\(expectedMid) back=\(back) "
            + "loadsBefore=\(loadsBefore) loadsAfter=\(loadsAfter) rowLoads=\(vm.scrollRowLoads) "
            + "aspect=\(String(format: "%.3f", vm.lastKnownAspect))")
    }

    /// 场景:导出本卷页文件(⇧⌘E)的面板取证。
    ///
    /// **判据怎么分**(与 scroll 那条不同,要单独说清):
    ///   · `written` 来自 `PageSequenceReport.delivered` —— 它是**报告说**写了几页;
    ///   · `onDisk` 是本驱动自己 `contentsOfDirectory` 数出来的**磁盘事实**。
    ///     两者必须相等 —— 与网格那条 `thumbs` 是同一个道理:`generated=30` 只说明
    ///     Kit 交出了 30 份字节,**不等于**磁盘上真有 30 个文件。报告与磁盘是两条路,
    ///     各验一次才知道它们一致(写盘失败时报告会记 `failed`,但「报告说成功、
    ///     文件却不在」这种事只有数磁盘才拦得住)。
    ///   · `covers` = `coversWholeArchive`(delivered + skipped + failed == pages)。
    ///     这是报告自带的「有没有漏页」判据,**不在这里自己再算一遍** —— 算错的方向
    ///     恰好是「把没弄完的说成弄完了」。
    ///
    /// **为什么不顺带验「按阅读顺序」**:那条性质由 `PageSequenceExportTests` 在
    /// **无沙盒的 swift test** 里逐字节断言(用的是乱序条目名的 fixture);取证样本的
    /// 条目名本身有序(`p0001.jpg`…`p0030.jpg`),在这里根本看不出顺序的价值。
    /// 这一段负责的是**面板本身**,不重复单元测试的活。
    ///
    /// ⚠️ **本段明确未覆盖两处**(别把这里的绿读成"导出功能全验了"):
    ///   ① `running` 中途那一帧 —— 30 页写盘太快,截图竞态赢不了,而为了拍它去
    ///      人为拖慢导出是本末倒置。「停止」按钮的落点因此仍没进过图;
    ///   ② 真实入口是 `PageExportPanel` 的 `NSOpenPanel`(**用户选目录**)——
    ///      驱动直接给了一个目录,所以"选目录那一步"不在本段范围内。
    private static func runExport(on vm: ReaderViewModel) async {
        // 目标目录:容器 tmp/ 下的固定子目录。两个理由:
        //   ① App 在沙盒里对它天然有写权限,不需要走 NSOpenPanel 授权;
        //   ② verify-ui.sh 认得这个路径,能自己去数一遍文件 —— 于是判据是两条路
        //      (驱动数一次、脚本再数一次),不是同一条路自证。
        // 导出前先清空:残留文件会让 onDisk 虚高,而虚高恰好能让「报告与磁盘一致」
        // 这条判据**假绿** —— 假绿的守卫比没有守卫更糟(§11.9 那条教训的同型)。
        // 清理放在驱动里而不是脚本里:这是 App 自己的 tmp 子目录,由它自己建、自己清,
        // 不经任何外部工具的删除配额,也没有"删错用户文件"的可能。
        let dir = flagDir.appendingPathComponent("export-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 等阅读器那枚**页码 HUD** 自己淡出(打开文档后静止 2.5s 消失)。
        // 不等它的话,它会压在页面上一起进图 —— 而那张图的用途正是"看清面板本身",
        // HUD 是干扰项。2026-09-22 首次取证实测:导出只花 200ms,不等就一定拍到它。
        // 这不是给画面加修饰(面板的位置/尺寸/文案一个字没动),只是把"恰好还没消失
        // 的浮层"等掉。3s 的成本对整个脚本可以忽略。
        try? await Task.sleep(for: .seconds(3))

        let task = vm.exportPages(to: dir)
        guard task != nil else {
            // 真失败(不是前提不满足):文档在、但导出入口不可用。把原因写清楚,
            // 免得人从"没有状态行"倒推
            log("scene=export aborted: exportPages 返回 nil "
                + "(canExport=\(vm.canExportPages) phase=\(String(describing: vm.phase)))")
            return
        }
        log("scene=export sheet=opened")

        // 等导出落定。上限 60s:300 页的包要读要写
        var ticks = 0
        while vm.isExportRunning, ticks < 600 {
            try? await Task.sleep(for: .milliseconds(100))
            ticks += 1
        }
        // 结束 ≠ 画完:给 SwiftUI 一拍把终态摆上去(同 runGrid 的理由),并等任务真正收尾
        try? await Task.sleep(for: .milliseconds(700))
        await task?.value

        var written = 0, skipped = 0, failed = 0, pages = vm.pageCount
        var stop = "nil", covers = 0
        if let state = vm.exportState, case .ready(let report) = state {
            written = report.delivered
            skipped = report.skippedEncrypted
            failed = report.failedCount
            pages = report.pages
            stop = report.stop.token
            covers = report.coversWholeArchive ? 1 : 0
        }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? -1

        log("scene=export pages=\(pages) written=\(written) skipped=\(skipped) "
            + "failed=\(failed) stop=\(stop) covers=\(covers) onDisk=\(onDisk) "
            + "waited=\(ticks * 100)ms")
    }

    /// 场景:首次阅读提示条(2026-09-22)。
    ///
    /// **判据怎么分**:
    ///   · `visible` —— 显式调 `showHintBar()` 之后它在不在屏上。**这是断言项**:
    ///     菜单「帮助 → 显示阅读提示」走的就是这同一个方法,它为 0 说明重看入口是坏的。
    ///   · `auto` —— 打开文档时它**是不是自己出现的**。同样是**事实,不是断言项**:
    ///     它只自动出现一次,所以同一个容器再跑一遍必然是 0。
    ///     把 `auto=0` 当失败会把人送去查一个没坏的功能(§11.9 那条教训的同型);
    ///     要看 `auto=1`,得让容器回到"没见过这条提示"的状态再跑(新装 / 清过容器)。
    ///
    /// ⚠️ **本段明确没覆盖两处**(别把这里的绿读成"提示条全验了"):
    ///   ① 「没盖住页面」这件观感。它在代码里由**结构**保证(提示条是布局里的一行,
    ///      画布拿到的是扣掉它之后的高度,见 ReaderView 的 `.reading` 分支);
    ///      截图只负责让人看一眼那一行与页面是分开的。变成机器判据需要一把
    ///      像 page_metrics.swift 那样的尺子(量"页面顶缘是否在提示条下缘之下"),
    ///      本批没做,也就**不声称验过**;
    ///   ② `×` 按钮的**接线**。本驱动调的是 ViewModel 那一层,证明不了那个按钮
    ///      真的接到了它 —— 那一下只能人点(与 §13 里"文案是否得体"同一类)。
    private static func runHint(on vm: ReaderViewModel) async {
        // ⚠️ 别拿 `isHintBarVisible` 当"自动出现"的依据,也别在这里读一次性标记:
        // 两者都分不出"它自己出现的"和"刚被 showHintBar() 调出来的"。
        // 2026-09-22 第一版就是这么错的 —— 日志里出现过 `auto=1 seenBefore=1`
        // 这样自相矛盾的一对(标记与显示是同一段同步代码写的,事后读必为 true)
        let auto = vm.didAutoShowHintBar ? 1 : 0

        // 停在第 2 页:封面当背景太容易被误读成"这一页什么都没有"
        vm.goTo(min(1, max(vm.pageCount - 1, 0)))
        try? await Task.sleep(for: .milliseconds(700))

        // 菜单「帮助 → 显示阅读提示」走的就是这个方法
        vm.showHintBar()
        try? await Task.sleep(for: .milliseconds(900))

        log("scene=hint auto=\(auto) visible=\(vm.isHintBarVisible ? 1 : 0) "
            + "markerNow=\(ReaderTips().hasShownHintBar ? 1 : 0) "
            + "current=\(vm.pageIndex) pages=\(vm.pageCount)")
    }

    /// 场景:阅读层周边控件 —— 左侧缩略图栏 + 左右翻页箭头(2026-09-23)。
    ///
    /// 为什么需要它:`ONLY=reader` 那一段截的是**打开归档后的第一屏**,而
    /// 2026-09-23 起那是**网格层**;周边控件只长在阅读层上,于是这套 UI 一度
    /// 完全没有取证入口。`ONLY=hint` 的图里虽然也有它们,但那条图的主题是提示条,
    /// 拿它当控件的证据属于"顺手蹭到"。
    ///
    /// **判据怎么分**(与 grid 那条同一套分工):
    ///   · `layer=read` —— 确实停在阅读层。**这是断言项**:网格层没有这套控件,
    ///     层不对则整张图与主题无关;
    ///   · `thumbs` —— 左栏的数据源(网格池)里有多少张图,证明"栏里有东西可显示"。
    ///     它**不等于**"栏画出来了" —— 画没画出来只有截图能证。
    ///
    /// ⚠️ **本段明确没覆盖两处**(别把这里的绿读成"周边控件全验了"):
    ///   ① **鼠标静默时的淡化**(用户 2026-09-23 的第四条诉求)。淡化由
    ///      `hudVisible` 与悬停两个输入驱动,而截图那一刻鼠标在哪、停了多久
    ///      都不可控 —— 拍到的必然是**全亮态**。要断言它得能读像素亮度,
    ///      本批没做,也就**不声称验过**;
    ///   ② **箭头的方向语义**(右开时"下一页"在左)。状态行里的 `dir` 只证明
    ///      **变量值**,证明不了它渲染在了正确的一侧 —— 那同样只有截图能看,
    ///      而且要切一次右开再拍第二张。本批没做。
    private static func runChrome(on vm: ReaderViewModel) async {
        // 停在第 3 页:封面(第 1 页)的缩略图高亮恰好落在栏顶,看不出"高亮跟着
        // 页码走";而第 3 页能把高亮推到栏里第二、三格,一眼可辨
        vm.goTo(min(2, max(vm.pageCount - 1, 0)))
        try? await Task.sleep(for: .milliseconds(900))

        var thumbs = 0
        for i in 0..<vm.pageCount where vm.gridThumbnail(at: i) != nil { thumbs += 1 }

        log("scene=chrome layer=\(vm.layer == .read ? "read" : "browse") "
            + "pages=\(vm.pageCount) thumbs=\(thumbs) current=\(vm.pageIndex) "
            + "layout=\(vm.layout.rawValue) "
            + "dir=\(vm.direction == .rightToLeft ? "rtl" : "ltr")")
    }

    /// 场景:**优雅退出**(2026-09-24)。
    ///
    /// 为什么需要它 —— 这条路本机**从来没被走到过**:
    ///   · 真实 ⌘Q 要靠 AppleEvent / 按键注入,而 Ad-hoc 重签之后 TCC 授权失效
    ///     (`-10004`),注入被系统直接拒掉;
    ///   · 于是此前只剩 `kill -TERM` 这条替代证据。但信号走的是**异常**分支:
    ///     进程被直接终结,`applicationWillTerminate` 根本不会被调用,session 标记
    ///     停在 `alive=true`。它证明的恰恰是"异常退出下能被检出",与"优雅退出会
    ///     收尾"是**方向相反**的两件事,不能互相顶替。
    ///
    /// ★ 关键选择:发的是 **`NSApp.sendAction(#selector(terminate:), to: nil, from: nil)`**,
    ///   **不是**直接调 `NSApplication.terminate(_:)`。
    ///   前者把 `terminate:` 交给**响应者链**去找实现,与菜单里那个「退出 Unroll」
    ///   项做的事逐字相同(菜单项的 action 就是 `terminate:`、target 为 nil);
    ///   后者绕开"菜单有没有接上线"这一层,于是**菜单项接错线 / 换菜单后漏接**
    ///   这类故障会被漏掉 —— 而那正是本场景存在的理由。既然要验,就验真的那条路。
    ///
    /// 判据不在这里(进程马上就没了,App 没法断言自己),而在磁盘上:
    /// `session.json` 的 `alive` 必须变成 false、面包屑末条必须是 `appTerminated`。
    /// 那两条由 Scripts/probe-graceful-exit.sh 检查。
    private static func runQuit() async {
        log("run quit: 准备把 terminate: 发给响应者链(与菜单「退出」同一条路)")
        // 留一点时间:① 让 LaunchServices 那侧把窗口画出来(与真实使用一致);
        // ② 让 probe 脚本先把"App 在跑"这件事观察到位,免得它把"还没起来"
        //    误读成"已经退出了"
        try? await Task.sleep(for: .milliseconds(1200))
        log("quit: sendAction(terminate:) now")
        NSApp.sendAction(#selector(NSApplication.terminate(_:)), to: nil, from: nil)

        // 正常情况写不到这一行 —— 进程已经退出了。
        // 它**刻意保留**:一旦出现在日志里就说明 terminate: 没生效(响应者链里没人接、
        // 或 NSApp 为 nil)。probe 脚本会把它当成一条明确的失败线索,而不是等超时。
        try? await Task.sleep(for: .milliseconds(600))
        log("quit: FATAL 已发出 terminate: 但进程仍然活着 —— 响应者链里没人接")
    }
}
#endif
