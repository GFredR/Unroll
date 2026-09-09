// AI-Generated | 可修改
// M0PlaceholderView —— 工程骨架占位页(M2 完成阅读器后【整文件删除】)
// ----------------------------------------------------------------------------
// 存在意义:
//   1. 让 M0 验收「空壳 App 能编译运行」有东西可看;
//   2. 顺手把 DesignSystem / L10n 两条基础设施链路跑通(颜色经 Token、文案经 key),
//      M2 换成 ReaderView 时不必再踩「散落字面值 / 硬编码中文」的坑(AGENTS.md 六.8/六.9)。
import SwiftUI

struct M0PlaceholderView: View {

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "book")
                .font(.system(size: 64))
                .foregroundStyle(DesignSystem.Palette.accent)
                .accessibilityHidden(true)   // 装饰性图标,不进 VoiceOver(AGENTS.md 十一.3)

            Text("placeholder.title")
                .font(.system(size: DesignSystem.Typography.title, weight: .bold))

            Text("placeholder.subtitle")
                .font(.system(size: DesignSystem.Typography.body))
                .foregroundStyle(.secondary)

            Text("placeholder.hint")
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Palette.background)
    }
}

#Preview {
    M0PlaceholderView()
}
