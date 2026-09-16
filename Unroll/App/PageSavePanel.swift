// AI-Generated | 可修改
// PageSavePanel —— 「另存当前页…」的保存面板与写盘(App 层,2026-09-16)
// ----------------------------------------------------------------------------
// 为什么要单独一层:Core 的 `PageExport` 是纯函数(可逐像素单测),**不碰文件系统**;
// 面板 / 写盘 / 失败提示这些带副作用的事全在这里。
//
// 沙盒:面板返回的 URL 由系统自动授予写权限,不需要额外 entitlement(与 ⌘O 读文件同理)。
//
// 「取消」与「失败」必须分开:取消是用户意图,静默;失败要说一句
// —— 存档这类操作最忌"点了没反应"(§5.9.4「绝不假装成功」的精神)。
import AppKit

@MainActor
enum PageSavePanel {

    enum Outcome: Equatable {
        case saved(URL)
        case cancelled
        case failed
    }

    /// 弹面板 → 编码 → 写盘。`format` 由用户所选扩展名回推(面板可切换 PNG / JPEG)
    @discardableResult
    static func save(image: CGImage, suggestedName: String) -> Outcome {
        let panel = NSSavePanel()
        panel.allowedContentTypes = PageExport.Format.allCases.map(\.utType)
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

        guard write(image: image, to: url) else {
            presentFailure()
            return .failed
        }
        return .saved(url)
    }

    /// 编码 + 写盘(**面板之外的完整链路**,所以能单测)。
    /// 失败原因不往外抛:一律 false,调用方负责说一句
    @discardableResult
    static func write(image: CGImage, to url: URL) -> Bool {
        guard let data = PageExport.encode(image, as: format(for: url)) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // 刻意不把 error.localizedDescription 摆到界面上:那串文字可能带完整路径
            // (与 §5.10.4 同一条口径 —— 路径不进 UI)
            return false
        }
    }

    /// 按用户敲定的扩展名回推格式;认不出来(比如手打 .tiff)按 PNG 处理
    private static func format(for url: URL) -> PageExport.Format {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        default:            return .png
        }
    }

    private static func presentFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("app.alert.saveFailed.title")
        alert.informativeText = L10n.tr("app.alert.saveFailed.body")
        alert.addButton(withTitle: L10n.tr("app.alert.ok"))
        alert.runModal()
    }
}
