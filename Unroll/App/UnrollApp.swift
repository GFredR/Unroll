// AI-Generated | 可修改
// UnrollApp —— App 入口与生命周期(设计文档 §4.1 App/ 职责)
// ----------------------------------------------------------------------------
// M2:窗口根视图换成 ReaderView(空态/打开中/错误态/画布四态由 VM 驱动);
//     Finder 双击经 onOpenURL 进来(Info.plist 已声明四种漫画归档的 Default 关联),
//     拖拽由 ReaderView 根部的 dropDestination 承接(全阶段可用)。
// M3:菜单命令体系(纯键盘可完成全部操作 —— M3 验收标准):
//     文件菜单(⌘O 打开 / 最近打开,security-scoped bookmark 重开,§5.7);
//     视图菜单(单页/双页 ⌘1/⌘2,左开/右开 ⇧⌘L/⇧⌘R,回到封面)。
//     全屏 HUD、滚轮翻页在 ReaderView / HUDView 内实现。
import SwiftUI
import UniformTypeIdentifiers

@main
struct UnrollApp: App {

    @StateObject private var reader = ReaderViewModel()
    @State private var recents = RecentDocuments()
    /// 菜单展示的最近列表(open 后与菜单即将显示时刷新)
    @State private var recentList: [RecentDocuments.Entry] = []

    var body: some Scene {
        // 标题直接用 Localizable key,SwiftUI 会自动按系统语言解析(en / zh-Hans)
        WindowGroup("app.name") {
            ReaderView(viewModel: reader)
                .frame(minWidth: 720, minHeight: 480)
                // Finder 双击 / 系统打开方式:文件访问权由系统自动授予(沙盒下同理)
                .onOpenURL { url in
                    openArchive(url: url)
                }
                .onAppear { reloadRecents() }
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

            CommandMenu(L10n.tr("app.menu.openRecent")) {
                ForEach(recentList) { entry in
                    Button(entry.displayName) {
                        openRecent(entry)
                    }
                }
                if !recentList.isEmpty {
                    Divider()
                    Button(L10n.tr("app.menu.clearRecent"), role: .destructive) {
                        recents.clear()
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
            }
        }
    }

    // MARK: - 打开链路(唯一入口:面板 / 拖拽 / 双击 / 最近打开 全走这里)

    private func openArchive(url: URL) {
        recents.add(url: url)
        reloadRecents()
        reader.open(url: url)
    }

    /// 最近打开:书签解析(沙盒重授权)成功才打开;失效条目当场剔除
    private func openRecent(_ entry: RecentDocuments.Entry) {
        guard let url = recents.resolve(entry) else {
            recents.remove(entry)
            reloadRecents()
            return
        }
        openArchive(url: url)
    }

    private func reloadRecents() {
        recentList = recents.entries()
    }
}

// MARK: - 归档文件选择器(FailureView「打开其他文件」与本菜单共用,防两处分叉)

@MainActor
enum ArchivePicker {

    /// NSOpenPanel 限四种漫画归档 + zip(与 Info.plist 关联一致)
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
    ]
}
