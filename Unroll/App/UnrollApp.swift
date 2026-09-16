// AI-Generated | 可修改
// UnrollApp —— App 入口与生命周期(设计文档 §4.1 App/ 职责)
// ----------------------------------------------------------------------------
// M2:窗口根视图换成 ReaderView(空态/打开中/错误态/画布四态由 VM 驱动);
//     Finder 双击经 onOpenURL 进来(Info.plist 已声明四种漫画归档的 Default 关联),
//     拖拽由 ReaderView 根部的 dropDestination 承接(全阶段可用)。
// M3:菜单命令体系(纯键盘可完成全部操作 —— M3 验收标准):
//     文件菜单(⌘O 打开 / 最近打开,security-scoped bookmark 重开,§5.7);
//     视图菜单(单页/双页 ⌘1/⌘2,封面单独一页 ⌥⌘C,左开/右开 ⇧⌘L/⇧⌘R,回到封面)。
//     全屏 HUD、滚轮翻页在 ReaderView / HUDView 内实现。
// M4:崩溃采集 L0 的会话标记(SwiftUI 无 applicationWillTerminate 对应物,
//     故用 NSApplicationDelegateAdaptor 接 AppKit 回调,见 AppLifecycle);
//     窗口根视图挂 .crashPrompt() 做「上次似乎异常退出」延迟询问(§5.10)。
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct UnrollApp: App {

    @StateObject private var reader = ReaderViewModel()
    @State private var recents = RecentDocuments()
    /// 菜单展示的最近列表(open 后与翻页时刷新)
    @State private var recentList: [RecentDocuments.Entry] = []
    /// 文件名 → 续读条目(菜单标注「读到第几页」用;与 recentList 同步刷新)
    @State private var progressIndex = RecentProgressIndex(entries: [:])
    /// 探测出的失效条目 id(菜单标「找不到文件」用,2026-09-15)
    @State private var staleRecentIDs: Set<UUID> = []
    /// 点击失效条目后的说明(非 nil → 弹一句,不再无声消失)
    @State private var missingRecentName: String?

    /// M4:崩溃采集的会话标记要靠 AppKit 生命周期回调闭合
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        // 标题直接用 Localizable key,SwiftUI 会自动按系统语言解析(en / zh-Hans)
        WindowGroup("app.name") {
            ReaderView(viewModel: reader)
                .frame(minWidth: 720, minHeight: 480)
                // 窗口大小/位置记忆:AppKit setFrameAutosaveName 自动持久化并恢复
                // (2026-09-16 顺带接管窗口标题:带文件名与页码,见 WindowChrome)
                .background(WindowChrome(title: reader.windowTitle))
                // Finder 双击 / 系统打开方式:文件访问权由系统自动授予(沙盒下同理)
                .onOpenURL { url in
                    openArchive(url: url)
                }
                .onAppear {
                    reloadRecents(probe: true)
                    #if DEBUG
                    // 仅调试构建:launch argument `-demoScript` 时按时间轴自动演示(录 GIF 用)
                    DemoDriver.startIfNeeded(on: reader)
                    #endif
                }
                // 翻页后刷新进度索引:最近打开菜单里的「P.3/200」要跟得上阅读位置
                .onChange(of: reader.pageIndex) { _, _ in reloadRecents() }
                // M4:启动 1.5s 后自检「上次是否异常退出」,是则问一次(§5.10.5-①)
                .crashPrompt()
                // 2026-09-15:失效的最近条目点击后不只剔除,还要说清原因
                .alert(L10n.tr("app.alert.recentMissing.title"),
                       isPresented: Binding(get: { missingRecentName != nil },
                                            set: { if !$0 { missingRecentName = nil } })) {
                    Button(L10n.tr("app.alert.ok"), role: .cancel) { missingRecentName = nil }
                } message: {
                    Text(L10n.tr("app.alert.recentMissing.message", missingRecentName ?? ""))
                }
        }
        .windowStyle(.automatic)
        .commands {
            // 替换「新建」组:漫画阅读器没有「新建」,只留「打开」
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("app.menu.open")) {
                    if let url = ArchivePicker.pick() {
                        openArchive(url: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // v2(2026-09-16):「另存当前页…」与「在访达中显示」。
            // 用 .saveItem 而不是 .newItem —— 只读阅读器本来就没有「保存文稿」,
            // 正好把系统的 Save 位夺过来;⌘S 与 macOS 惯例一致。
            // ⇧⌘F 取「File / Finder」的联想键:⇧⌘R 已被「从右往左读」占用
            CommandGroup(replacing: .saveItem) {
                Button(L10n.tr("app.menu.saveCurrentPage")) {
                    saveCurrentPage()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(reader.phase != .reading)

                Button(L10n.tr("app.menu.revealInFinder")) {
                    if let url = reader.documentURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(reader.documentURL == nil)
            }

            CommandMenu(L10n.tr("app.menu.openRecent")) {
                ForEach(recentList) { entry in
                    Button(recentLabel(for: entry)) {
                        openRecent(entry)
                    }
                }
                if !recentList.isEmpty {
                    Divider()
                    Button(L10n.tr("app.menu.clearRecent"), role: .destructive) {
                        recents.clear()
                        reader.clearProgress()   // 连带清续读进度,不留无主数据
                        reloadRecents()
                    }
                }
            }

            CommandMenu(L10n.tr("app.menu.view")) {
                Button(L10n.tr("reader.layout.single")) {
                    reader.layout = .single
                }
                .keyboardShortcut("1", modifiers: .command)
                Button(L10n.tr("reader.layout.dual")) {
                    reader.layout = .dual
                }
                .keyboardShortcut("2", modifiers: .command)
                // 双页配对口径:日式单行本封面是独立一页,开着才是正确的摊
                // (见 Core/SpreadPaging.swift 的口径说明)
                Toggle(L10n.tr("app.menu.coverAlone"), isOn: $reader.coverAlone)
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button(L10n.tr("reader.direction.ltr")) {
                    reader.direction = .leftToRight
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button(L10n.tr("reader.direction.rtl")) {
                    reader.direction = .rightToLeft
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(L10n.tr("app.menu.firstPage")) {
                    reader.goTo(0)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button(L10n.tr("app.menu.lastPage")) {
                    reader.goTo(reader.pageCount - 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                Button(L10n.tr("app.menu.jumpToPage")) {
                    reader.isJumpSheetPresented = true
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(reader.phase != .reading)
                Divider()
                // 缩放档位(§2.1-4):自由缩放叠加在档位基准之上
                Button(L10n.tr("reader.fit.window")) {
                    reader.fitMode = .fitWindow
                }
                .keyboardShortcut("3", modifiers: .command)
                Button(L10n.tr("reader.fit.width")) {
                    reader.fitMode = .fitWidth
                }
                .keyboardShortcut("4", modifiers: .command)
                Button(L10n.tr("reader.fit.height")) {
                    reader.fitMode = .fitHeight
                }
                .keyboardShortcut("5", modifiers: .command)
                Button(L10n.tr("reader.fit.actual")) {
                    reader.fitMode = .actualSize
                }
                .keyboardShortcut("6", modifiers: .command)
            }

            // 书签(2026-09-15):标记当前页 + 在书签间跳转 + 直达某一页
            CommandMenu(L10n.tr("app.menu.bookmarks")) {
                Button(reader.isCurrentPageBookmarked
                       ? L10n.tr("app.menu.removeBookmark")
                       : L10n.tr("app.menu.addBookmark")) {
                    reader.toggleBookmark()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(reader.phase != .reading)

                Divider()

                Button(L10n.tr("app.menu.previousBookmark")) {
                    reader.goToPreviousBookmark()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(reader.bookmarkedPages.isEmpty)
                Button(L10n.tr("app.menu.nextBookmark")) {
                    reader.goToNextBookmark()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(reader.bookmarkedPages.isEmpty)

                if !reader.bookmarkedPages.isEmpty {
                    Divider()
                    // 直达某一页;上限 20 条(菜单过长反而难用,大数量场景属 v3 的书签面板)
                    ForEach(reader.bookmarkedPages.prefix(20), id: \.self) { page in
                        Button(L10n.tr("reader.bookmark.pageItem", page + 1)) {
                            reader.goTo(page)
                        }
                    }
                    Divider()
                    Button(L10n.tr("app.menu.clearBookmarks"), role: .destructive) {
                        reader.clearBookmarks()
                    }
                }
            }
        }
    }

    // MARK: - 另存当前页(v2,2026-09-16)

    /// 双页模式下导出的是**屏幕上那一摊**(两张拼一张,顺序跟随阅读方向)——
    /// 见 `PageExport` 的口径说明;单页模式就是当前页本身
    private func saveCurrentPage() {
        guard let image = reader.exportImage() else { return }
        PageSavePanel.save(image: image,
                           suggestedName: reader.exportFileName(format: .png))
    }

    // MARK: - 打开链路(唯一入口:面板 / 拖拽 / 双击 / 最近打开 全走这里)

    private func openArchive(url: URL) {
        recents.add(url: url)
        reloadRecents()
        reader.open(url: url)
    }

    /// 最近打开:书签解析(沙盒重授权)成功才打开;失效条目剔除 + **说一句**
    /// (2026-09-15:原先静默 return,菜单项无声消失,用户不知道发生了什么)
    private func openRecent(_ entry: RecentDocuments.Entry) {
        guard let url = recents.resolve(entry) else {
            recents.remove(entry)
            staleRecentIDs.remove(entry.id)
            reloadRecents()
            missingRecentName = entry.displayName
            return
        }
        // 真的打开了 → 撤销本次会话里的失效标记(探测不挂载网络卷,可能误判;
        // 这里以「实际打开成功」为准,避免标记与事实打架)
        staleRecentIDs.remove(entry.id)
        openArchive(url: url)
    }

    /// 刷新菜单列表。`probe` = 顺带探测失效条目(要解析每条书签,较贵)——
    /// 只在启动时开一次;翻页触发的高频刷新只读列表,不探测(也不在用户背后
    /// 挂载网络卷或弹授权框,探测走 `resolveQuietly`)。
    private func reloadRecents(probe: Bool = false) {
        recentList = recents.entries()
        progressIndex = RecentProgressIndex(entries: ReadingProgress().allEntries())
        if probe {
            staleRecentIDs = recents.unresolvableIDs()
        }
    }

    /// 最近打开的菜单项标题:有续读记录则带上进度(缺总页数的老记录只显示页码);
    /// 探测出文件已不在的条目补一句「找不到文件」,点之前就能看出来
    private func recentLabel(for entry: RecentDocuments.Entry) -> String {
        let base: String
        if let saved = progressIndex.entry(forDocument: entry.displayName) {
            if let total = saved.total, total > 0 {
                base = L10n.tr("app.menu.recentProgress", entry.displayName, saved.page + 1, total)
            } else {
                base = L10n.tr("app.menu.recentProgressUnknownTotal", entry.displayName, saved.page + 1)
            }
        } else {
            base = entry.displayName
        }
        return staleRecentIDs.contains(entry.id)
            ? base + L10n.tr("app.menu.recentMissingSuffix")
            : base
    }
}

// MARK: - 窗口外观:尺寸记忆 + 标题(v2,2026-09-15 / 2026-09-16)

/// 借 AppKit 的 frameAutosaveName 实现零自管存储:
/// NSWindow 自动把 frame 写进 UserDefaults(`NSWindow Frame …`),启动时自动恢复。
/// 隐私上只有窗口几何数据,无任何文档信息。
///
/// 2026-09-16 顺带接管标题(`文件名 · P.3/200`):`WindowGroup("app.name")` 的标题是
/// 静态的,而 Window 菜单 / Dock 悬停 / 多窗口辨认都需要**动态**页码。
/// 标题由 VM 产出(`ReaderViewModel.windowTitle`),这里只负责写进 NSWindow ——
/// 窗口标题同样是纯内存态,不落盘。
private struct WindowChrome: NSViewRepresentable {

    let title: String

    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.apply(title: title)
    }

    private final class ChromeView: NSView {
        /// 视图先于窗口就位(macOS 的 NSViewRepresentable 生命周期如此),
        /// 故标题要缓存一份,等 `viewDidMoveToWindow` 再补写
        private var pendingTitle = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.setFrameAutosaveName("UnrollMainWindow")
            apply(title: pendingTitle)
        }

        func apply(title: String) {
            pendingTitle = title
            guard let window, window.title != title else { return }
            window.title = title
        }
    }
}

// MARK: - App 生命周期钩子(M4 崩溃采集)

/// SwiftUI 没有 `applicationWillTerminate` 的对应物,而「正常退出」的定义
/// 恰恰就是这一刻 —— 崩溃采集的会话标记靠这两个回调闭合(§5.10.3-②):
/// 启动写 `alive = true`,⌘Q / 关窗口写 `alive = false`。
/// 崩溃时永远写不到 false,于是下次启动就能检出「上次异常退出」。
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 诊断模块自身失败一律静默(§5.10.5-②),绝不阻断启动
        CrashReporter.shared.beginSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Breadcrumbs.shared.record(.appTerminated)
        CrashReporter.shared.endSession()
    }
}

// MARK: - 归档文件选择器(FailureView「打开其他文件」与本菜单共用,防两处分叉)

@MainActor
enum ArchivePicker {

    /// NSOpenPanel 限漫画归档 + 裸 zip/rar/7z(与 Info.plist 关联一致)
    static func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedTypes.compactMap { UTType($0) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static let allowedTypes = [
        "com.gfredr.unroll.cbz",
        "com.gfredr.unroll.cbr",
        "com.gfredr.unroll.cb7",
        "com.gfredr.unroll.cbt",
        "public.zip-archive",
        "com.gfredr.unroll.rar",
        "com.gfredr.unroll.sevenzip",
    ]
}
