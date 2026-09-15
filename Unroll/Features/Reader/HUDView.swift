// AI-Generated | 可修改
// HUDView —— 隐藏式阅读浮层(设计文档 §0-6 / §4.1,M3 实现)
// ----------------------------------------------------------------------------
// 内容:文件名 + 页码 x/y + 进度条。显隐由 ReaderCanvas 驱动
// (鼠标/触控板移动即现,静止 2.5s 自动淡出 —— 计时器在画布侧,
// 本视图只做纯渲染,不碰 NSEvent)。
// 纯展示层 + allowsHitTesting(false):浮层绝不拦截画布的翻页手势。
import SwiftUI

struct HUDView: View {

    @ObservedObject var viewModel: ReaderViewModel
    let visible: Bool

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if let name = viewModel.documentName {
                Text(name)
                    .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)   // 长文件名掐中间,保留扩展名可辨
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                // 当前页已标记书签(2026-09-15):纯视觉指示,不参与布局计算
                if viewModel.isCurrentPageBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: DesignSystem.Typography.footnote))
                        .foregroundStyle(DesignSystem.Palette.brand)
                }

                Text(L10n.tr("reader.page.progress", viewModel.pageIndex + 1, viewModel.pageCount))
                    .font(.system(size: DesignSystem.Typography.hud).monospacedDigit())
            }

            ProgressView(value: viewModel.pageCount > 0
                         ? Double(viewModel.pageIndex + 1) / Double(viewModel.pageCount) : 0)
                .frame(width: 160)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
