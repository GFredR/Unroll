// AI-Generated | 可修改
// HUDView —— 隐藏式阅读浮层(设计文档 §0-6 / §4.1,M3 实现;进度条可拖动见 2026-09-16)
// ----------------------------------------------------------------------------
// 内容:文件名 + 页码 x/y + 进度条。显隐由 ReaderCanvas 驱动
// (鼠标/触控板移动即现,静止 2.5s 自动淡出 —— 计时器在画布侧,
// 本视图只做纯渲染,不碰 NSEvent)。
//
// 命中测试(v2,2026-09-16):原先整块 `allowsHitTesting(false)`,因为浮层绝不能
// 拦截画布的翻页手势。加了可拖动的进度条之后要精细划分 ——
//   · 文字 / 背景:各自 false(点了照样翻页);
//   · 进度条:唯一可交互元素。
// 容器用 `.allowsHitTesting(visible)`:淡出后(opacity 0)**仍然参与命中测试**,
// 不显式关掉的话,底部会留一条看不见的"死区"吞掉半屏点击。
import SwiftUI

struct HUDView: View {

    @ObservedObject var viewModel: ReaderViewModel
    let visible: Bool
    /// 画布侧的活动通知。拖进度条 / 点轨道时调用,用于重置淡出计时 ——
    /// 否则拖到一半 HUD 淡出,滑杆看不见也就拖不下去了
    let onActivity: () -> Void

    /// 拖动中的目标页(0-based);nil = 未在拖动。
    /// **拖动只改这个本地值**,松手才 `goTo` —— 逐帧跳页会触发逐帧解码,
    /// 拖过 200 页就是 200 次解码,卡到没法用
    @State private var scrubTarget: Double?

    /// HUD 上显示的第几页(拖动中显示瞄准的那一页,1-based)
    private var displayPage: Int {
        guard let scrubTarget else { return viewModel.pageIndex + 1 }
        return Int(scrubTarget.rounded()) + 1
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if let name = viewModel.documentName {
                Text(name)
                    .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)   // 长文件名掐中间,保留扩展名可辨
                    .allowsHitTesting(false)
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                // 当前页已标记书签(2026-09-15):纯视觉指示,不参与布局计算
                if viewModel.isCurrentPageBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: DesignSystem.Typography.footnote))
                        .foregroundStyle(DesignSystem.Palette.brand)
                        .allowsHitTesting(false)
                }

                Text(L10n.tr("reader.page.progress", displayPage, viewModel.pageCount))
                    .font(.system(size: DesignSystem.Typography.hud).monospacedDigit())
                    .allowsHitTesting(false)
            }

            progressBar
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        // 背景层单独关掉命中测试:它是一块实心圆角矩形,不关会吃掉半屏单击
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                .fill(.black.opacity(0.55))
                .allowsHitTesting(false)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .allowsHitTesting(visible)
        .accessibilityElement(children: .combine)
    }

    // MARK: 进度条

    /// 可拖动跳页(2026-09-16)。单页文档(只有 1 页)退化为原样只读条 ——
    /// 没有可跳的目标,给个假滑杆只会让人白拖
    @ViewBuilder
    private var progressBar: some View {
        if viewModel.pageCount > 1 {
            Slider(value: scrubBinding,
                   in: 0...Double(viewModel.pageCount - 1),
                   onEditingChanged: { editing in
                       onActivity()
                       guard !editing, let target = scrubTarget else { return }
                       scrubTarget = nil
                       viewModel.goTo(Int(target.rounded()))
                   })
                .frame(width: 200)
                .controlSize(.small)
                .tint(DesignSystem.Palette.brand)
                .accessibilityLabel(L10n.tr("reader.hud.progress.hint"))
                .help(L10n.tr("reader.hud.progress.hint"))
        } else {
            ProgressView(value: viewModel.pageCount > 0
                         ? Double(viewModel.pageIndex + 1) / Double(viewModel.pageCount) : 0)
                .frame(width: 160)
                .allowsHitTesting(false)
        }
    }

    /// 读数取「拖动中的目标」优先,否则取真实页码。
    /// setter 里 poke 画布 = 拖动期间 HUD 不淡出
    private var scrubBinding: Binding<Double> {
        Binding(get: { scrubTarget ?? Double(viewModel.pageIndex) },
                set: { newValue in
                    scrubTarget = newValue
                    onActivity()
                })
    }
}
