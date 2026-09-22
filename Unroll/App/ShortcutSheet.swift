// AI-Generated | 可修改
// ShortcutSheet —— 「帮助 → 键盘快捷键…」面板(2026-09-22)
// ----------------------------------------------------------------------------
// 内容全部来自 `Core/ShortcutCatalog`,这里**只负责排版**。
// 清单绝不在视图里手写 —— 那会变成"第三份清单"(菜单一份、catalog 一份、
// 视图又一份),而多出来的那份没人钉。清单与真实菜单的一致性由
// `MenuStructureTests` 逐条对照,见该文件与 ShortcutCatalog 头注释。
import SwiftUI

struct ShortcutSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ForEach(ShortcutCatalog.groups) { group in
                        groupView(group)
                    }
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(L10n.tr("help.shortcuts.title"))
                .font(.system(size: DesignSystem.Typography.title, weight: .semibold))
            Text(L10n.tr("help.shortcuts.subtitle"))
                .font(.system(size: DesignSystem.Typography.caption))
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(L10n.tr(group.id))
                .font(.system(size: DesignSystem.Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(group.items) { item in
                row(item)
            }
        }
    }

    /// 一行 = 「操作描述 …… 组合键」。组合键用等宽字体加浅底,与描述分开
    /// (它是"可以作为符号去记"的东西,不该和句子混在一起)
    private func row(_ item: ShortcutItem) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text(L10n.tr(item.id))
                .font(.system(size: DesignSystem.Typography.body))

            Spacer(minLength: DesignSystem.Spacing.md)

            Text(item.shortcut)
                .font(.system(size: DesignSystem.Typography.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.control)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.tr("help.shortcuts.done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(DesignSystem.Spacing.md)
    }
}
