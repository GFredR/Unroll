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
//   demo-grid     → 缩略图网格面板(⇧⌘G)取证
//   demo-jump     → 页码跳转面板 + 侧边预览(⌥⌘G)取证
//   demo-scroll   → 连续滚动(⌘0)取证(下行 + 回程,见 runScroll 的判据说明)
//   demo-export   → 导出本卷页文件(⇧⌘E)面板取证(真导一遍,见 runExport 的判据说明)
//
// 为什么用标记文件而不是 argv:`open --args` 在 macOS 15 上实测**传不进 App**
// (LaunchServices 会过滤未知 argv;2026-09-20 用探针 App 复核 —— 经 `open`
// 启动 argc=1,直接 exec 才有 4 个参数)。标记文件是唯一可靠的入口。
// 环境变量 UNROLL_DEMO_SCRIPT 仍作兜底(值 grid/jump 选场景,其它非空值 = 翻页)。
//
// 录制脚本见 Scripts/record-demo.sh;
// UI 取证见 Scripts/verify-ui.sh(ONLY=grid / ONLY=jump / ONLY=scroll / ONLY=export)。
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

        /// 认全名(`demo-grid`)与简写(`grid`)。**认不出返回 nil**,由调用方决定
        /// 兜底 —— 环境变量那条路的旧语义是「随便给个非空值就翻页」,
        /// 不能在这里硬塞默认值,否则以后加场景时会静默走错分支
        static func parse(_ token: String) -> Scene? {
            switch token {
            case Scene.grid.rawValue, "grid": return .grid
            case Scene.jump.rawValue, "jump": return .jump
            case Scene.scroll.rawValue, "scroll": return .scroll
            case Scene.export.rawValue, "export": return .export
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

        for scene in [Scene.grid, .jump, .scroll, .export, .paging]
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
        log("onAppear scene=\(scene?.rawValue ?? "none") flags=[\(flags)] argv=[\(argv)] env=\(envHit)")
        guard let scene, !hasStarted else { return }
        hasStarted = true
        Task { await waitForDocument(scene: scene, on: viewModel) }
    }

    private static func waitForDocument(scene: Scene, on vm: ReaderViewModel) async {
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

    /// 两个取证场景的公共准备:把可能被**续读**带偏的状态压回可预期的起点。
    /// 不复位的话,同一份样本第二次跑会因为进度记忆停在上次的页上,
    /// 截出来的图每次都不同 —— 取证最忌讳"看起来一样其实不一样"
    private static func prepareForProbe(on vm: ReaderViewModel) async {
        vm.layout = .single
        vm.direction = .leftToRight
        vm.fitMode = .fitWindow
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// 场景:缩略图网格(⇧⌘G)。
    ///
    /// 停在**第二页**而不是封面:当前页在网格里有一圈品牌色描边,
    /// 停在第 1 页的话那圈描边落在左上角第一格,不容易看出"它在跟页码走"。
    private static func runGrid(on vm: ReaderViewModel) async {
        vm.goTo(min(1, max(vm.pageCount - 1, 0)))
        try? await Task.sleep(for: .milliseconds(900))

        vm.showGrid()
        log("scene=grid sheet=opened")

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
}
#endif
