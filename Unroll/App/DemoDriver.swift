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
//
// 为什么用标记文件而不是 argv:`open --args` 在 macOS 15 上实测**传不进 App**
// (LaunchServices 会过滤未知 argv;2026-09-20 用探针 App 复核 —— 经 `open`
// 启动 argc=1,直接 exec 才有 4 个参数)。标记文件是唯一可靠的入口。
// 环境变量 UNROLL_DEMO_SCRIPT 仍作兜底(值 grid/jump 选场景,其它非空值 = 翻页)。
//
// 录制脚本见 Scripts/record-demo.sh;
// UI 取证见 Scripts/verify-ui.sh(ONLY=grid / ONLY=jump)。
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

        /// 认全名(`demo-grid`)与简写(`grid`)。**认不出返回 nil**,由调用方决定
        /// 兜底 —— 环境变量那条路的旧语义是「随便给个非空值就翻页」,
        /// 不能在这里硬塞默认值,否则以后加场景时会静默走错分支
        static func parse(_ token: String) -> Scene? {
            switch token {
            case Scene.grid.rawValue, "grid": return .grid
            case Scene.jump.rawValue, "jump": return .jump
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

        for scene in [Scene.grid, .jump, .paging]
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
}
#endif
