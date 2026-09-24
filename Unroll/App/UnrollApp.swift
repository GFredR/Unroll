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
    /// 「帮助 → 键盘快捷键…」面板(2026-09-22)
    @State private var isShortcutSheetPresented = false

    /// 项目主页。⚠️ **仓库尚未 push**(唯一阻塞是 `gh` 未登录,见发布清单 §2)——
    /// 首推之前点这一项会拿到 404。这是**已知且刻意**的:地址就是 `publish.sh`
    /// 将要创建的 `GFredR/Unroll`,不写成占位符也不留 TODO(仓库零 TODO 纪律)
    private let homepageURL = URL(string: "https://github.com/GFredR/Unroll")!

    /// M4:崩溃采集的会话标记要靠 AppKit 生命周期回调闭合
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        // 标题直接用 Localizable key,SwiftUI 会自动按系统语言解析(en / zh-Hans)
        WindowGroup("app.name") {
            ReaderView(viewModel: reader,
                       recentItems: emptyStateRecents,
                       onOpenRecent: { openRecent($0) },
                       // 提示条里的「全部快捷键…」与菜单里那一项开的是同一个面板:
                       // 一个状态、一处渲染,不给它第二条渲染路径
                       onShowShortcuts: { isShortcutSheetPresented = true })
                // 窗口尺寸(2026-09-23 用户要求"整体加大三分之一")。
                // 原先这里**只有下限**,默认尺寸由内容推导 —— 而空态内容并不高,
                // 于是开出来的初始窗口偏小。
                //
                // 具体数字与它们的来由搬到了 `DesignSystem.Window`(常量集中、
                // 且那条「最小窗口够不够放下左栏」的判断现在能被测试断言)
                .frame(minWidth: DesignSystem.Window.minWidth,
                       minHeight: DesignSystem.Window.minHeight)
                // 帮助 → 键盘快捷键…(2026-09-22)。挂在根视图上:它是 App 级面板,
                // 与阅读态 / 空态无关 —— 任何阶段都该能翻快捷键
                .sheet(isPresented: $isShortcutSheetPresented) {
                    ShortcutSheet()
                }
                // 窗口尺寸/位置记忆 = **自管**(2026-09-24,判据与存储见 `Core/WindowGeometry.swift`)。
                // 系统那两条路都实测过、都不生效,所以这里不再猜系统行为,自己存一个固定键;
                // 读写的时机由 `WindowChrome` 负责,两类证据(`probe-window-memory.sh` 的
                // 20 → 21 → 22,以及空的 `Saved Application State/`)记在它的文档注释里。
                // 接管窗口标题那部分与记忆无关(走 `WindowChrome.updateNSView`),一直是有效的
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
                    // 仅调试构建:窗口记忆探针(容器标记文件驱动,见本文件 WindowProbe)
                    WindowProbe.startIfNeeded()
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
        // 初始窗口 960×640 = 原最小尺寸 720×480 各乘 4/3(用户 2026-09-23 要求)。
        // `defaultSize` 是 **Scene** 的修饰符,不是 View 的 —— 写在 ReaderView 上会
        // 被静默忽略(它只作用在窗口内容,不影响 NSWindow 起手尺寸)。
        // 数字见 `DesignSystem.Window`(唯一来源)
        //
        // ⚠️ `.defaultSize` 现在是**真正的"首次"语义**(2026-09-24 起):
        // 自管记忆(`Core/WindowGeometry.swift`)一旦有记录,就会在窗口就位时覆盖它。
        // 在这之前它是"每次都生效" —— 因为记忆从来没工作过(见 `WindowChrome` 注释)。
        // 所以**开发机上看不出这一行的变化是正常的**(那台机器上有记录)。
        // 想回到默认值 = 清掉那个固定键 `window.frame.v1`,没有菜单入口
        // (`Scripts/probe-window-memory.sh` 的 clear 档就是干这个的)。
        // ⚠️ 别去删 SwiftUI 派生出来的那些 `NSWindow Frame SwiftUI.…` 键:它们与本记忆
        // 无关(造它们的那套机制读不回自己),而且 `defaults delete` 会让 cfprefsd
        // 拿缓存整份重写 plist —— 实测删 3 个键掉了 6 个,见测试文档 §22/§23.2
        .defaultSize(width: DesignSystem.Window.defaultWidth,
                     height: DesignSystem.Window.defaultHeight)
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

                // 批量导出(⇧⌘E,2026-09-21)。与上一项的分工要紧,别合并:
                // ⌘S 导出**屏幕上那一摊**(双页合成一张、JPEG 重编码,要的是所见即所得);
                // 这一项导出**归档里的每一页**(原始字节直通、按阅读顺序补零命名,
                // 要的是原素材)。⇧⌘E 取「Export」的联想键,与 ⌘S 同组相邻
                Button(L10n.tr("app.menu.exportPages")) {
                    exportPages()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!reader.canExportPages)

                Button(L10n.tr("app.menu.revealInFinder")) {
                    if let url = reader.documentURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(reader.documentURL == nil)

                // 部分加密包:输一次密码,把读不出的页一起解开(v2,2026-09-17)。
                // 全加密包不走这里 —— 它在打开阶段就直接弹密码视图了。
                // ⇧⌘K 取「Key」的联想键(⇧⌘L / ⇧⌘R 已被左右开方向占用)
                Button(L10n.tr("app.menu.unlock")) {
                    reader.beginUnlock()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!reader.hasLockedPages)

                Divider()

                // 完整性检查(⌥⌘V,2026-09-17):主动把每一页的字节读一遍验 CRC,
                // 在用户翻到坏页**之前**就给出「有几页读不出来」的结论 ——
                // 逐页报错的时机太晚,用户那时已经不知道该不该换源文件了。
                // ⇧⌘F / ⇧⌘K 已占用,⌥⌘V 取「Verify」的联想键
                Button(L10n.tr("app.menu.checkIntegrity")) {
                    reader.checkIntegrity()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!reader.canCheckIntegrity)
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
                // 连续滚动(v2 候选池最后一项,2026-09-21)。
                // 取 ⌘0 而不是 ⌘7:数字键里 3–6 已被缩放档位占满,而 0 与 1/2
                // **物理相邻** —— 这一组是「怎么排」,下一组是「怎么缩放」,
                // 中间那条 Divider 就是分界。放在 7 会让它看起来属于缩放那一组
                Button(L10n.tr("reader.layout.scroll")) {
                    reader.layout = .scroll
                }
                .keyboardShortcut("0", modifiers: .command)
                // 双页配对口径:日式单行本封面是独立一页,开着才是正确的摊
                // (见 Core/SpreadPaging.swift 的口径说明)。
                // 滚动模式下没有「摊」,这一项点了什么也不会发生 —— 灰掉而不是
                // 留一个空转的开关(单页模式同样无摊,但那是既有行为,不在本次改动内)
                Toggle(L10n.tr("app.menu.coverAlone"), isOn: $reader.coverAlone)
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(reader.layout == .scroll)
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
                // 缩略图网格(v1.1,2026-09-18)。取「Grid」的联想键 ⇧⌘G ——
                // ⌥⌘G 已被页码跳转占用,而这两项恰好是一对:
                // 一个是「我知道页号,直接去」,一个是「我看看有什么,再点」。
                // 放相邻位置,是因为用户找其中一个时往往需要另一个
                Button(L10n.tr("app.menu.thumbnailGrid")) {
                    reader.showGrid()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!reader.canShowGrid)
                Divider()
                // 缩放档位(§2.1-4):自由缩放叠加在档位基准之上。
                // **滚动模式下这四项全部灰掉**:它们定义的是「一摊怎么放进窗口」,
                // 而连续滚动按宽度铺满、横向是稳定轴,没有「摊」这个单位 ——
                // 留着会变成四个点了没反应的控件(比灰掉更让人困惑)
                Button(L10n.tr("reader.fit.window")) {
                    reader.fitMode = .fitWindow
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(reader.layout == .scroll)
                Button(L10n.tr("reader.fit.width")) {
                    reader.fitMode = .fitWidth
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(reader.layout == .scroll)
                Button(L10n.tr("reader.fit.height")) {
                    reader.fitMode = .fitHeight
                }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(reader.layout == .scroll)
                Button(L10n.tr("reader.fit.actual")) {
                    reader.fitMode = .actualSize
                }
                .keyboardShortcut("6", modifiers: .command)
                .disabled(reader.layout == .scroll)
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

            // 帮助(2026-09-22)。原先这里**什么都没有** —— 而「不知道就翻菜单栏 Help」
            // 正是 macOS 用户的肌肉记忆,菜单栏那条一直是空的。
            // 用 .help 位置(replacing)而不是另起一个菜单:用户找它时目光落在菜单栏
            // 最右端,不该让他去别处寻。
            // ⌘? 取系统惯例(⇧/ 打出 ?),与「帮助」这个键位本身的语义一致
            CommandGroup(replacing: .help) {
                Button(L10n.tr("help.menu.shortcuts")) {
                    isShortcutSheetPresented = true
                }
                .keyboardShortcut("?", modifiers: .command)

                // 首次阅读提示条的**重看入口**(2026-09-22)。那一条只自动出现
                // 一次(见 Core/ReaderTips.swift),之后就靠这里 ——
                // 灰掉而不是留一个点了没反应的开关:提示条是贴在画布上方的一行,
                // 没有文档时它无处可贴;而空态本来就把小抄摆在那儿了
                // (同款判断见「封面单独一页」在滚动模式下灰掉的说明)
                Button(L10n.tr("help.menu.showTips")) {
                    reader.showHintBar()
                }
                .disabled(reader.phase != .reading)

                Button(L10n.tr("help.menu.homepage")) {
                    NSWorkspace.shared.open(homepageURL)
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

    // MARK: - 导出本卷页文件(⇧⌘E,2026-09-21)

    /// 先选目录(取消即静默返回),再交给 VM 起后台任务。
    /// 顺序不能反过来:面板是**唯一**能拿到写权限的地方(沙盒),
    /// 先起任务再要目录的话,前几页会因为没权限而失败
    private func exportPages() {
        guard let directory = PageExportPanel.chooseDirectory() else { return }
        reader.exportPages(to: directory)
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

    /// 最近打开的菜单项标题。口径已抽到 `RecentPresentation`(空态欢迎页共用同一份 ——
    /// 两处各写一份的话,迟早出现「菜单标了 P.12/48、空态没标」这种分叉),
    /// 这里只做转发
    private func recentLabel(for entry: RecentDocuments.Entry) -> String {
        RecentPresentation.title(for: entry, progress: progressIndex, staleIDs: staleRecentIDs)
    }

    /// 空态欢迎页的最近列表:与菜单**同源同口径**,只取前几条
    /// (上限理由见 `RecentPresentation.visibleLimit`)
    private var emptyStateRecents: [RecentItem] {
        Array(RecentPresentation.items(from: recentList,
                                       progress: progressIndex,
                                       staleIDs: staleRecentIDs)
            .prefix(RecentPresentation.visibleLimit))
    }
}

// MARK: - 窗口外观:尺寸记忆 + 标题(v2,2026-09-15 / 2026-09-16;记忆 2026-09-24 改为自管)

/// 窗口尺寸/位置记忆 + 标题。**记忆是自管的**(2026-09-24):
/// 判据与存储都在 `Core/WindowGeometry.swift`,这里只负责两件不可单测的事 ——
/// **什么时候读**(窗口就位时一次)、**什么时候写**(用户真的动过 / 退出时)。
///
/// ⚠️ 为什么不用系统那两条路 —— 都实测过、都不生效(留档,别再改回去):
/// ① `window?.setFrameAutosaveName("UnrollMainWindow")`:2026-09-23 的原注释说它是
///    "借 AppKit 的 frameAutosaveName 实现零自管存储"。逐键检查容器 plist:
///    **`NSWindow Frame UnrollMainWindow` 这个键从未出现过** —— `viewDidMoveToWindow`
///    里那行不是记忆的实现,不要那样读它。
/// ② 同一次更正里还写过"记忆功能一直是好的,好的是另一条路 —— SwiftUI 那条",
///    以及"老用户看到的是记忆值。这不是 bug,是记忆在工作" —— **两句都不成立**:
///    SwiftUI 派生的键名里含**一次性的代码地址**
///    (`…ModifiedContent<(unknown context at $10b1fce30).WindowChrome>…`),
///    于是每次启动都是新键 ⇒ 永远读不到"上次"。取证:同一二进制连启两次,
///    frame 键数 **20 → 21 → 22**(`Scripts/probe-window-memory.sh`);
///    第二条独立证据:`Saved Application State/` 目录**是空的**。
///    ⇒ **2026-09-24 之前,窗口记忆在本 App 上从来没工作过。**
///
/// 写入的三处时机(每一处都对着一个具体的失败形态):
///   · `didEndLiveResize` —— 用户拖完尺寸。**只有真的手动缩放才会发**,
///     所以它是"用户意图"最干净的信号;
///   · `didMove` —— 移动窗口。它与上一条不同:程序化 `setFrame` 也会发,
///     所以要等**武装**(见 `armed`)之后才收。否则启动期 SwiftUI 自己设的那次
///     frame 会把用户存的几何当场擦成默认值 —— "一开机就被自己擦掉记忆"
///     是这类实现最典型的坏法,而且坏得完全无声;
///   · `willTerminate` —— 退出兜底:只移动、没缩放过就退出,靠它落盘。
/// 武装晚一拍的代价是"启动那一瞬间的几何变化一律不写",失败形态**偏向安全**:
/// 最坏是不写,不会把用户存的几何写坏。
///
/// 每次启动仍会在偏好文件里多留一个 SwiftUI 派生的 frame 键(那套机制读不回自己,
/// 却在关窗时照写;本地开发机已攒 20+ 个)。它无害、与本记忆无关,别去删。
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

        /// 恢复/落盘各做一次,别重复挂观察者(窗口在本生命周期内不变)
        private var didAdopt = false
        /// **武装**:`didMove` 只有武装之后才写盘。理由见文档注释 ——
        /// 启动期 SwiftUI 自己设的那次 frame 也会发 `didMove`
        private var armed = false
        /// 我们最后写过的几何。相同就不重复写(省一次磁盘写,也让"有没有动过"可读)
        private var lastWritten: WindowGeometry?
        private let store = WindowFrameStore()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(title: pendingTitle)
            adoptIfNeeded()
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func apply(title: String) {
            pendingTitle = title
            guard let window, window.title != title else { return }
            window.title = title
        }

        // MARK: - 恢复(窗口就位时一次)

        /// 读存储 → 交给纯判据解析 → 应用。解不出来或没有记录时**什么都不做**,
        /// 于是 `.defaultSize` 说了算(见 `WindowMemory.resolve` 的 nil 三种情况)
        private func adoptIfNeeded() {
            guard let window, !didAdopt else { return }
            didAdopt = true

            let restored = WindowMemory.resolve(
                saved: store.load(),
                screens: NSScreen.screens.map(\.visibleFrame),
                minSize: CGSize(width: DesignSystem.Window.minWidth,
                                height: DesignSystem.Window.minHeight))
            if let restored {
                lastWritten = restored
                window.setFrame(restored.rect, display: true)
            }
            observe(window)
        }

        // MARK: - 落盘(三处时机)

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            // 刻意用**选择子**而不是闭包:这几个通知都在主线程发,而块式 API 在
            // Swift 6 严格并发下要求 `@Sendable` 闭包 —— 捕获 self(NSView)会直接报错,
            // 绕开它只能加锁或包一层 box。选择子走 AppKit 原生路径,没有这个问题
            center.addObserver(self, selector: #selector(handleLiveResizeEnded(_:)),
                               name: NSWindow.didEndLiveResizeNotification, object: window)
            center.addObserver(self, selector: #selector(handleMoved(_:)),
                               name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(handleWillTerminate(_:)),
                               name: NSApplication.willTerminateNotification, object: nil)
            center.addObserver(self, selector: #selector(handleBecameKey(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            // 窗口可能**在我们挂上观察者之前就已经是 key** 了(启动顺序不保证),
            // 所以除了通知,这里还要自己查一次 —— 只挂通知会静默漏掉"从没武装过"
            if window.isKeyWindow { armAfterOneTurn() }
        }

        /// 武装 = 放**一个主队列回合**。选"一个回合"而不是固定秒数的理由:
        /// 要挡的是同一轮启动流程里 SwiftUI 自己那次 `setFrame`,它是紧接着发生的;
        /// 跨过一回合之后再来变化,就是用户的动作了
        private func armAfterOneTurn() {
            guard !armed else { return }
            DispatchQueue.main.async { [weak self] in self?.armed = true }
        }

        @objc private func handleBecameKey(_ note: Notification) { armAfterOneTurn() }

        @objc private func handleLiveResizeEnded(_ note: Notification) {
            // 手动缩放是**用户意图**最干净的信号:程序化 `setFrame` 不会发这个通知。
            // 顺带把它当"窗口已稳定"的证据 —— 一次手动缩放之后就没必要再等武装了
            armed = true
            persist()
        }

        @objc private func handleMoved(_ note: Notification) {
            guard armed else { return }
            persist()
        }

        @objc private func handleWillTerminate(_ note: Notification) {
            guard armed else { return }
            persist()
        }

        private func persist() {
            guard let window, window.isVisible else { return }
            let geometry = WindowGeometry(rect: window.frame)
            guard geometry != lastWritten else { return }
            lastWritten = geometry
            store.save(geometry)
        }
    }
}

#if DEBUG
// MARK: - 窗口记忆探针(仅调试构建,2026-09-24)

/// 让 App **自己**报出 / 改动自己的窗口几何 —— 因为从外面驱动窗口在这台机器上做不到:
/// `System Events` 注入被 TCC 拒(1002),`open --args` 在 macOS 15 上不转发 argv
/// (DemoDriver 也是因此改用容器标记文件的)。这里走同一条已验证的路:
/// 标记文件放容器 tmp,内容即指令,App 读完**立刻删**。
///
/// 指令(`<容器>/tmp/window-probe` 的内容):
///   `report` → 把自己**真实的** `NSWindow.frame` 写进 `<容器>/tmp/window-probe-report`
///   `set`    → 把窗口挪成「当前几何 + (宽+40, 高+40, x+40, y+30)」,并把**实际**几何写进报告
///   `clear`  → 清掉记忆键(`window.frame.v1`),报告 `cleared=1`
/// 三种模式收尾都走 `NSApp.terminate(nil)`:让「退出时落盘」那条真路径也走到,
/// 顺带把 `alive` 留成 `false`(不会给用户造出一个假的「上次异常退出」弹窗)。
///
/// 判据(`Scripts/probe-window-memory.sh`):
///   `set` 之后重启再 `report`,结果**必须等于** `set` 报出的实际几何(正向);
///   而 `clear` 之后 `report` **必须不等于**它(负向对照 —— 否则"回到原处"
///   分不清是记忆生效还是碰巧一样,这正是那个"从不失败的守卫"的形态)。
///
/// 不需要探针时:删掉本段 + 根视图 `.onAppear` 里那一处 `#if DEBUG` 调用即可。
@MainActor
enum WindowProbe {

    private static let markerName = "window-probe"
    private static let reportName = "window-probe-report"

    /// 根视图 `onAppear` 时调用;返回是否认到了指令(只用于日志)
    @discardableResult
    static func startIfNeeded() -> Bool {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(markerName)
        guard let raw = try? Data(contentsOf: marker),
              let text = String(data: raw, encoding: .utf8) else { return false }
        // 立刻删标记:残留会让**下一次正常启动**也跑探针(与 demo 场景同一条纪律 ——
        // 那边更狠,残留的 `demo-quit` 会让 App 起来就自己退出)
        try? FileManager.default.removeItem(at: marker)
        let mode = text.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            guard let window = await visibleWindow() else {
                writeReport("mode=\(mode) error=no-window")
                NSApp.terminate(nil)
                return
            }
            switch mode {
            case "report":
                // 多等一拍:给 SwiftUI 足够时间把它自己的布局/尺寸做完 ——
                // 若它会覆盖我们的恢复,这一步就该**看见**(探针的价值在此,
                // 而不是"喂它一个已经稳了的时刻,然后宣布恢复生效")
                try? await Task.sleep(for: .seconds(0.8))
                writeReport("mode=report frame=\(describe(WindowGeometry(rect: window.frame)))")
            case "clear":
                WindowFrameStore().clear()
                writeReport("mode=clear cleared=1")
            case "set":
                let target = WindowGeometry(x: window.frame.minX + 40,
                                            y: window.frame.minY + 30,
                                            width: window.frame.width + 40,
                                            height: window.frame.height + 40)
                window.setFrame(target.rect, display: true)
                // 停一拍再读数:让 `didMove` 走完(与"用户拖完"同一条码路),
                // 也避免 AppKit 还在收尾时就报数
                try? await Task.sleep(for: .seconds(0.8))
                writeReport("mode=set target=\(describe(target)) "
                            + "actual=\(describe(WindowGeometry(rect: window.frame)))")
            default:
                writeReport("mode=\(mode) error=unknown-mode")
            }
            NSApp.terminate(nil)
        }
        return true
    }

    /// 等一个可见窗口出现(最多 6s)。**不写死一次 sleep** —— 窗口出现时刻不固定
    private static func visibleWindow() async -> NSWindow? {
        for _ in 0..<20 {
            if let window = NSApp.windows.first(where: { $0.isVisible }) { return window }
            try? await Task.sleep(for: .seconds(0.3))
        }
        return NSApp.windows.first
    }

    private static func describe(_ geometry: WindowGeometry) -> String {
        String(format: "%.0f,%.0f,%.0f,%.0f",
               geometry.x, geometry.y, geometry.width, geometry.height)
    }

    private static func writeReport(_ line: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(reportName)
        try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif

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
