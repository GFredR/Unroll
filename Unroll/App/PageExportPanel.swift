// AI-Generated | 可修改
// PageExportPanel —— 「导出本卷页文件…」的目录选择(App 层,2026-09-21)
// ----------------------------------------------------------------------------
// 与 `PageSavePanel` 同一套沙盒口径:面板返回的 URL 由系统自动授予读写权限,
// **不需要额外 entitlement**(与 ⌘O 读文件、⌘S 写文件同理)。区别只在选的是目录。
//
// 刻意**不做**「记住上次导出到哪」:那要往 UserDefaults 里写一条用户目录路径,
// 而本项目有一条结构红线是「路径不进存储」(§5.10.4)。导出是低频动作,
// 每次重选一次的代价远小于多开一个隐私面。
//
// 取消是用户意图 → 静默(nil),不弹任何东西。这条与 `PageSavePanel` 同款:
// 存档类操作最忌「点了没反应」,但「取消」不属于那一类。
import AppKit

@MainActor
enum PageExportPanel {

    /// 选一个目录;nil = 用户取消
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        // 文案明说要发生什么 —— 只写「选择文件夹」的话,用户不知道下一步会往里面写东西
        panel.message = L10n.tr("app.export.chooseMessage")
        panel.prompt = L10n.tr("app.export.choosePrompt")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
