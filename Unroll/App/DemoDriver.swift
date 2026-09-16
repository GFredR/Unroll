// AI-Generated | 可修改
// DemoDriver.swift —— 演示驱动(仅 DEBUG 构建,不进 Release)
// ============================================================================
// 为什么需要它:录制 README 的演示 GIF 需要"自动翻页",而用 osascript/CGEvent
// 注入按键会被 TCC(辅助功能)拦掉 —— 那是系统安全边界,不该去绕。
// 这里改成 App 自己按固定时间轴驱动 ViewModel:零授权、可重现、每次录出来一样。
//
// 触发:launch argument `-demoScript`
//   open -a <Unroll.app> <样本.cbz> --args -demoScript
//
// 录制脚本见 Scripts/record-demo.sh。
// 不需要演示时:直接删掉本文件 + UnrollApp.swift 里那一处 #if DEBUG 调用即可。
//
// 调试:每个节点写一行到容器 tmp/demo-driver.log
//   ~/Library/Containers/com.gfredr.unroll/Data/tmp/demo-driver.log
// ============================================================================
#if DEBUG
import AppKit
import Foundation

@MainActor
enum DemoDriver {

    /// 触发标记文件:容器 tmp 下放一个空文件即可启用(录制脚本用这个)。
    /// 路径:~/Library/Containers/com.gfredr.unroll/Data/tmp/demo-enabled
    static let flagURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("demo-enabled")

    /// 由 launch argument / 环境变量 / 标记文件任一触发;Release 构建里本文件不参与编译。
    /// 支持三种是因为 `open --args` 在 macOS 15 上实测传不进 App(LaunchServices 会
    /// 过滤未知 argv),而 `open --env` 与标记文件都可靠 —— 标记文件最简单,故以它为主。
    static var isEnabled: Bool {
        // 测试宿主就是 App 本身:测试进程里绝不启动演示。否则标记文件一旦因录制
        // 中途异常而残留,自动翻页就会打乱用例,表现为「莫名其妙的失败」。
        guard !UnrollRuntime.isTesting else { return false }
        return ProcessInfo.processInfo.arguments.contains("-demoScript")
            || ProcessInfo.processInfo.environment["UNROLL_DEMO_SCRIPT"] != nil
            || FileManager.default.fileExists(atPath: flagURL.path)
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
    /// 所以这里先等 pageCount 出现,再开始演示。
    static func startIfNeeded(on viewModel: ReaderViewModel) {
        let argv = ProcessInfo.processInfo.arguments.joined(separator: " ")
        let envHit = ProcessInfo.processInfo.environment["UNROLL_DEMO_SCRIPT"] ?? "nil"
        let flagHit = FileManager.default.fileExists(atPath: flagURL.path)
        log("onAppear enabled=\(isEnabled) argv=[\(argv)] env=\(envHit) flag=\(flagHit)")
        guard isEnabled, !hasStarted else { return }
        hasStarted = true
        Task { await waitForDocumentThenRun(on: viewModel) }
    }

    private static func waitForDocumentThenRun(on vm: ReaderViewModel) async {
        // 最多等 30s 让外部 `open <file>` 把文档送进来
        var ticks = 0
        while vm.pageCount == 0 && ticks < 300 {
            try? await Task.sleep(for: .milliseconds(100))
            ticks += 1
        }
        log("document ready pageCount=\(vm.pageCount) waited=\(ticks * 100)ms")
        guard vm.pageCount > 0 else { return }

        // 进全屏再演示。两个理由:
        //   ① 窗口模式下 `screencapture -R` 会连同窗口圆角外的一圈桌面一起录进去
        //      (窗口 bounds 比可视窗口略大),而全屏没有这个问题;
        //   ② 全屏正是阅读器的主场景(沉浸阅读),演示效果更好。
        // 这只在演示模式下发生;录制脚本会备份并还原窗口偏好。
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
        await run(on: vm)
    }

    /// 固定时间轴。总长约 9s,配合录制脚本的时长设置。
    private static func run(on vm: ReaderViewModel) async {
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
}
#endif
