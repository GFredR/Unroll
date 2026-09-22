// AI-Generated | 可修改
// ReaderHintBar —— 首次阅读时贴在画布上方的一条提示(2026-09-22)
// ----------------------------------------------------------------------------
// **位置与行为**:它是布局里真实的一行(不是浮层)—— 于是它**不可能盖住任何一页**,
// 画布拿到的是扣掉这一行之后的高度。这与 HUD 的取舍正好相反:那个必须浮着,
// 因为它要能在沉浸阅读时淡出得不留痕迹;而提示条一旦浮起来就会压住页面顶部
// (页高是按窗口高度适配的,顶部一定贴着画布上缘)。
//
// **讲什么**:菜单里**没有**的那些动作(点半屏 / 滑动 / 双击捏合)。
// 三个展示面各管一段,刻意不重叠:
//   · 空态小抄(ReaderView.shortcuts)→ 菜单里有、但想不起存在的键(⌘0 / ⇧⌘G / ⌥⌘G / ⌘D)
//   · 本条(阅读中)                  → 只有手势能做、菜单栏里无处可查的动作 ← 只此一处能讲
//   · 帮助 → 键盘快捷键…(⌘?)        → 全量 28 条
// 中间那一类是这条提示条**唯一的理由**:手势既不进菜单,也没有"悬停提示"可挂,
// 不知道就永远不会知道 —— 而它们恰恰是把这个阅读器用得顺手的部分。
//
// 关闭:`×`。标记由 VM 写(见 Core/ReaderTips.swift 对"标记写在出现时"的说明)。
import SwiftUI

struct ReaderHintBar: View {

    /// 点「全部快捷键…」→ 打开帮助里的快捷键面板
    let onShowAll: () -> Void
    /// 点 `×`
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "hand.tap")
                .font(.system(size: DesignSystem.Typography.caption))
                .foregroundStyle(DesignSystem.Palette.brand)
                .accessibilityHidden(true)   // 装饰性图标不进 VoiceOver(AGENTS.md 十一.3)

            Text(L10n.tr("reader.hint.gestures"))
                .font(.system(size: DesignSystem.Typography.caption))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(L10n.tr("reader.hint.gestures"))   // 窄窗口被截断时仍读得到全文

            Spacer(minLength: DesignSystem.Spacing.md)

            Button(L10n.tr("reader.hint.all"), action: onShowAll)
                .buttonStyle(.plain)
                .font(.system(size: DesignSystem.Typography.caption))
                .foregroundStyle(DesignSystem.Palette.brand)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: DesignSystem.Typography.footnote, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    // 字形本身只有 11pt 见方,直接当按钮会点不中 ——
                    // 撑到 22×22(横条总高约 30pt,再大就要把这一条撑胖了)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("reader.hint.dismiss"))
            .accessibilityLabel(L10n.tr("reader.hint.dismiss"))
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        // 品牌色淡染而不是灰底:它是一条「提示」,不是窗口 chrome ——
        // 与 HUD 那块 .black.opacity(0.55) 也一眼分得开(那个是浮层,这个是布局)
        .background(DesignSystem.Palette.brand.opacity(0.18))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
