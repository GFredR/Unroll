// AI-Generated | 可修改
// ReaderChromeView —— 阅读层周边控件(左侧缩略图栏 + 左右翻页箭头)
// 设计文档 §2.4 / §5.14；2026-09-23 落地
// ----------------------------------------------------------------------------
// 2026-09-23 用户一次提出四条缺口,本文件是其中三条的落点:
//
//   · **「返回按钮没找到」** —— 回网格层此前唯一可见的入口是 HUD 里那枚「浏览」
//     按钮,而 HUD 整块在鼠标静止 2.5s 后 `opacity → 0` **并关掉命中测试**。
//     也就是说按钮不是不存在,是"要先把鼠标晃醒它才可能出现"—— 那等于没有。
//     出路不是把 HUD 的淡出取消(沉浸阅读需要它),而是给这类**回头路**
//     一个常驻位置:左栏顶部,和缩略图栏一起永远在那儿。
//
//   · **「查看图片时左侧没有预览」** —— 大图页缺一个「我在全卷的哪个位置」的
//     常驻参照。此前唯一的全局视角是网格**层**,而进网格要离开当前页。
//
//   · **「左右两边的按钮应该有箭头提示」** —— 翻页此前只有键盘 / 半屏点击 /
//     滚轮三条路,屏幕上一个可点的翻页控件都没有。
//
// 显隐是这一处最要紧的设计(也就是用户第四条):
// **鼠标静默时淡化,而不是消失**。整组 chrome 共用一个透明度
// (`visible ? 1 : Chrome.idleOpacity`),永远看得见轮廓与位置,鼠标移回来立刻全亮。
// `chromeHovered` 是它的第二个输入:鼠标**停在**某件 chrome 上时不许淡出 ——
// 否则用户瞄准一个按钮的过程中它自己暗下去。计数器而不是布尔,理由见
// ReaderCanvas 里那个 `@State` 的说明。
//
// 命中测试刻意分成两类:
//   · **缩略图栏与返回按钮 —— 始终可点**。淡化不等于失效:用户抱怨的正是
//     "找不到",那就不该再叠一条"看不见就等于点不到";
//   · **左右箭头 —— 跟随可见性**。它们贴在画布左右边缘,而画布的左右半屏点击
//     本来就是翻页 —— 功能重合,但半屏点击范围大得多,是主路径。
//     鼠标静默时让箭头退出命中测试,半屏点击就一点不受影响。
//     (箭头淡化后只留 0.45 的轮廓,用户不会去点一个那样的东西;
//      真要点,鼠标一动它就亮起来并恢复命中)
import SwiftUI

// MARK: - 左侧缩略图栏(含回网格出口)

/// 单列缩略图 + 顶部的「回网格」按钮。
///
/// **数据来自网格池**(`viewModel.gridThumbnail(at:)`),零额外 I/O ——
/// 打开归档时 `performOpen` 已经起了一轮网格生成,池子通常已有图。
/// 这正是当初设计文档 §2.4 押后它时记下的第一个前提(「零额外 I/O,
/// 但必须绑网格池」);第二个前提(「窗口最小 720 会被压到约 560」)则由
/// 同一批把最小窗口一起放大来解决,见 `DesignSystem.Window.minWidth`。
///
/// 池子还没生成到某一页时,格子退化成**页码**而不是空白 —— 与网格层同款口径:
/// 空白会被读成「这一页是空的」,而真相是「还没生成到」
struct ThumbnailRail: View {

    @ObservedObject var viewModel: ReaderViewModel

    /// 鼠标活动通知(悬停 / 移动时续期 HUD 的淡出计时器)
    let onActivity: () -> Void
    /// 悬停状态上报(组进 chrome 的淡化判据)
    let onHoverChange: (Bool) -> Void

    /// 栏自己的滚动锚点。与网格层同一条纪律:它是**视图私有 state,不绑 VM** ——
    /// 用户滚栏时系统会往这里回写,而"栏滚到哪"不是当前阅读页
    @State private var scrollTarget: Int?

    var body: some View {
        VStack(spacing: 0) {
            backButton
            Divider().overlay(Color.white.opacity(0.14))
            rail
        }
        .frame(width: DesignSystem.Chrome.railWidth)
        .background(DesignSystem.Chrome.railBackground)
        // 栏内容紧贴窗口左缘,右边一条细线把它与画布分开(纯靠底色差不够)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .onHover { onHoverChange($0) }
        .onContinuousHover { _ in onActivity() }
    }

    // MARK: 回网格出口

    /// 「回头路要看得见」—— 这枚按钮就是这句话的兑现物。
    ///
    /// 与 HUD 里那枚「浏览」是**同一条路**(都调 `showGrid()`,不会各自长出一套
    /// 状态),区别只在可见性:那枚活在一个会整体淡出到 0 的浮层里,这一枚
    /// 跟着左栏常驻。两处都留着不是冗余 —— 一个是"读着读着顺手回头",
    /// 一个是"停下鼠标也能看见出口"
    private var backButton: some View {
        Button {
            _ = viewModel.showGrid()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "chevron.left")
                    .accessibilityHidden(true)   // 装饰性图标(AGENTS.md 十一.3)
                Text(L10n.tr("reader.chrome.backToGrid"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.sm)
            // 整行可点(不只是文字本身)—— 栏很窄,命中面必须给足
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 用 HUD 同款的白色而不是品牌色:teal 600 本身很暗,叠在纯黑画布上
        // 再乘上淡化系数就几乎看不见了,而这一枚的全部意义是"看得见"
        .foregroundStyle(.white)
        .help(L10n.tr("reader.chrome.backToGrid.hint"))
    }

    // MARK: 单列缩略图

    /// 按需实例化:`pageCount` 可以是几千,只有滚进视野的格子才被创建。
    /// 缩略图本身由网格池提供(纯查询),没有 I/O 也不触发解码 ——
    /// 滚这一栏因此永远不会把读盘带进渲染路径(与网格层同一个理由)
    ///
    /// **进入阅读层时自动滚到当前页**,翻页时跟随 —— 否则"当前页高亮"
    /// 会像网格层那样掉在视野之外:高亮一直在,缺的是把它带到眼前
    private var rail: some View {
        ScrollView {
            LazyVStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(0..<viewModel.pageCount, id: \.self) { index in
                    cell(index)
                }
            }
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
        .scrollPosition(id: $scrollTarget, anchor: .center)
        .onAppear { scrollTarget = viewModel.pageIndex }
        // 翻页(键盘 / 半屏点击 / 滚轮 / HUD 进度条,四条路都算)时把当前页带回眼前
        .onChange(of: viewModel.pageIndex) { _, newValue in
            scrollTarget = newValue
        }
    }

    private func cell(_ index: Int) -> some View {
        let isCurrent = index == viewModel.pageIndex
        return Button {
            // 栏内点格 = 只跳页,**不切层** —— 用户已经在阅读层里了。
            // (网格层的点格是「goTo + showReader」,那是两层之间的动作;
            //  这里若也调 showReader() 是空操作,但语义上是错的说法)
            viewModel.goTo(index)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.control)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.30))

                if let image = viewModel.gridThumbnail(at: index) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(1)
                } else {
                    // 还没生成到 / 读不出来。**显示页码而不是空白** ——
                    // 空白会被读成"这一页是空的",而它仍然可以点进去
                    Text("\(index + 1)")
                        .font(.system(size: DesignSystem.Typography.footnote).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: DesignSystem.Chrome.railThumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.control)
                    .strokeBorder(isCurrent ? DesignSystem.Palette.brand : Color.clear,
                                  lineWidth: 2)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
        }
        .buttonStyle(.plain)
        .help(L10n.tr("reader.chrome.rail.cellHint", index + 1))
        .accessibilityLabel(L10n.tr("reader.chrome.rail.cellHint", index + 1))
    }
}

// MARK: - 左右翻页箭头

/// 贴在画布左右两侧、纵向居中的翻页按钮。
///
/// **方向跟随阅读方向**(设计文档 §0 决策 3):右开时"下一页"在左边。
/// 图标永远指向它所处的那一侧(`chevron.left` 恒在左),**语义**随之反转 ——
/// 半屏点击、方向键、滚轮三处已经是这套口径了,这里必须是第四处一致的地方;
/// 否则右开用户会遇到「按右键往后翻、点左边却也是往后翻」这种自相矛盾
struct PageArrows: View {

    @ObservedObject var viewModel: ReaderViewModel
    let onHoverChange: (Bool) -> Void

    /// 右开 = 前进方向在左
    private var forwardIsLeading: Bool { viewModel.direction == .rightToLeft }

    var body: some View {
        HStack(spacing: 0) {
            arrow(icon: "chevron.left", isForward: forwardIsLeading)
            Spacer(minLength: 0)
            arrow(icon: "chevron.right", isForward: !forwardIsLeading)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
    }

    private func arrow(icon: String, isForward: Bool) -> some View {
        Button {
            if isForward {
                viewModel.nextPage()
            } else {
                viewModel.previousPage()
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: DesignSystem.Chrome.arrowHitWidth,
                       height: DesignSystem.Chrome.arrowHitHeight)
                .background {
                    // 底色必须是「暗底 + 亮描边」这一对,不能只有暗底 ——
                    // 画布本身就是纯黑,`.black.opacity()` 叠上去等于什么都没画,
                    // 箭头会变成两个飘着的符号(2026-09-23 首次取证当场撞上:
                    // 截图里 `<` `>` 在画布上完全看不出是个按钮)。
                    // 描边同时解决另一半:页面图压过来时,暗底负责把箭头从亮图上摘出来
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                        .fill(.black.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr(isForward ? "reader.chrome.nextPage" : "reader.chrome.prevPage"))
        .accessibilityLabel(L10n.tr(isForward ? "reader.chrome.nextPage"
                                              : "reader.chrome.prevPage"))
        .onHover { onHoverChange($0) }
    }
}
