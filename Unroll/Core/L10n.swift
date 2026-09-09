// AI-Generated | 可修改
// L10n —— 本地化统一入口(DLNACast 同款模式,零依赖)
// ----------------------------------------------------------------------------
// 所有用户可见文案一律 L10n.tr("key"),key 命名遵循「模块.场景.语义」
// (AGENTS.md 十.2),文案进 en / zh-Hans 两份 Localizable.strings。
// 带参数时用 args 填充,如 L10n.tr("archive.page.encrypted.subtitle", readableCount)。
import Foundation

enum L10n {
    /// 取本地化字符串;带 `%@` / `%ld` 等占位符时用 `args` 填充
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
    }
}
