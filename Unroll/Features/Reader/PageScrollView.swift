// AI-Generated | 可修改
// PageScrollView —— 连续滚动(v2 候选池最后一项,2026-09-21)
// ----------------------------------------------------------------------------
// 与 `ReaderCanvas` 的摊位渲染是**两条独立的渲染路径**,不是一个 if 分支:
//   · 分页:一摊居中,缩放 / 平移 / 半屏点击全归它;
//   · 滚动:一列页纵向排开,滚轮与触控板归系统滚动视图,缩放平移整个让位。
//
// 为什么不合着写:挂在容器上的 `DragGesture` 会把子视图的滚动**整个吃掉**
// (缩放那套平移手势与纵向滚动方向完全重叠),合起来写的结果是两种模式里
// 必有一种的手势是坏的。所以宁可各写一份 —— 真正贵的那部分(页缓存、解码、
// 顺序扫描器)本来就在 `PageStore` 里共用,这里分开的只是视图层。
//
// 三条写死的规则:
//   1. **锚点双向绑定**:`scrollPosition(id:)` 直连 `viewModel.scrollTarget`,
//      页码由视口回填(`ReaderViewModel.scrollAnchorChanged`),绝不另存一份
//      「当前滚到哪」—— 两份状态必然会有一次对不上;
//   2. **活跃窗口**:只有锚点 ± `scrollActiveWindow` 的行保留全分辨率。
//      `LazyVStack` 只保证「不渲染」,不保证「不持有」:行里 `@State` 攥着的
//      `CGImage` 引用计数在我们手上,不在 `PageCache` 的预算账本里。
//      这条才是内存上限的真正落点(不变量由 `AppSkeletonTests` 断言);
//   3. **行高先估后正**:等图到达再定高,`LazyVStack` 会「上面那行一变高就把
//      下面全推走」,一路抖。先用 `lastKnownAspect` 撑住,图到了再按真实比例
//      微调 —— 同一本单行本页尺寸几乎恒定,所以初值基本必然命中。
//   4. **行宽取「滚动视图内容区实宽」,不是外层 GeometryReader 的宽度**。
//      系统「始终显示滚动条」时(`AppleShowScrollBars=Always`)macOS 用传统
//      滚动条,会从滚动视图里**挖走 15pt 占位** —— 外层 GeometryReader 量到的
//      是挖之前的 900pt,按 900 定宽的行比内容区宽 15pt,于是**左右各被裁
//      7.5pt**(页宽的 1.7%),页缘的内容是真的看不见了。改用
//      `containerRelativeFrame(.horizontal)` 让行自己认容器实宽。
//      判据:`verify-ui.sh ONLY=scroll` 拿样本页脚的进度条比对 ——
//      条宽 = 页宽的 n/总页数,按实宽算得出来;被裁时实测值会短 ~13 设备px。
import SwiftUI

/// 连续滚动容器:一列页(行 = 页,不是摊;见 `ReaderViewModel.PageLayout`)
struct PageScrollView: View {

    @ObservedObject var viewModel: ReaderViewModel
    /// 画布侧的活动通知(HUD 淡出计时重置;滚动本身也算活动)
    let onActivity: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: DesignSystem.Spacing.md) {
                ForEach(0..<viewModel.pageCount, id: \.self) { index in
                    PageScrollRow(viewModel: viewModel,
                                  index: index,
                                  isActive: isActive(index))
                }
            }
            .padding(.vertical, DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity)
        }
        // 双向:用户滚动时系统往里写,`goTo` / 换布局时我们往里写。
        // `anchor: .top` = 锚点取「视口顶部那一页」,与 HUD 页码含义一致
        .scrollPosition(id: $viewModel.scrollTarget, anchor: .top)
        .scrollIndicators(.visible)
        .onContinuousHover { _ in onActivity() }
    }

    /// 锚点附近才保留全分辨率(文件头第 2 条)。
    /// 用 `<=` 而不是 `<`:窗口是「两侧各 N 行」,总计 2N+1 行
    private func isActive(_ index: Int) -> Bool {
        abs(index - viewModel.pageIndex) <= DesignSystem.PageBudget.scrollActiveWindow
    }
}

// MARK: - 单行

/// 一页。三种终态:有图 / 失败卡片 / 占位(未加载 或 落在活跃窗口之外)
private struct PageScrollRow: View {

    @ObservedObject var viewModel: ReaderViewModel
    let index: Int
    let isActive: Bool

    @State private var image: CGImage?
    @State private var failure: ReaderViewModel.Failure?

    /// 页比例(宽 ÷ 高)。有图按真实比例,没图按上一页的比例估(文件头第 3 条)
    private var aspect: CGFloat {
        let raw = image.map { CGFloat($0.width) / max(CGFloat($0.height), 1) }
            ?? viewModel.lastKnownAspect
        return max(raw, 0.01)
    }

    var body: some View {
        // 宽度交给容器 —— 滚动视图的**内容区实宽**(已扣掉系统挖走的滚动条占位;
        // 文件头第 4 条),高度由 `aspect` 推出来。行高不再自己算,也就不会
        // 再出现「算宽用的数」和「容器实际给的宽」不一致
        slot
            .containerRelativeFrame(.horizontal)
            // 行没有文字标签(整页是图),给无障碍补一个「第几页」
            .accessibilityElement()
            .accessibilityLabel(L10n.tr("reader.page.progress", index + 1, viewModel.pageCount))
            // id 带上 `isActive`:出窗要**主动释放**行内那张大图(置 nil),
            // 光靠 LazyVStack 回收视图是不够的(见文件头第 2 条)
            .task(id: loadKey) { await load() }
    }

    /// 一行的槽位。三种终态占**同样大小**的槽:失败卡片若塌成自身高度,
    /// 它下面的页会整体上移,滚动位置就跟着跳
    private var slot: some View {
        Group {
            if let failure {
                ratioBox.overlay { PageFailureCard(failure: failure, viewModel: viewModel) }
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(aspect, contentMode: .fit)
            } else {
                ratioBox.overlay { placeholder }
            }
        }
    }

    /// 撑住槽位的无色底:比例盒 —— 宽度由外层给,高度 = 宽度 ÷ 比例
    private var ratioBox: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
    }

    private var loadKey: String { "\(index)|\(isActive)" }

    private func load() async {
        guard isActive else {
            image = nil
            failure = nil
            return
        }
        // 已经拿到图就不重复取(出窗/回窗之外,`scrollTarget` 的变化也会
        // 让 `pageIndex` 变、进而让本行的 `loadKey` 变,但那时 image 还在)
        guard image == nil, failure == nil else { return }

        guard let result = await viewModel.loadScrollPage(at: index) else { return }
        switch result {
        case .image(let loaded):
            image = loaded
            viewModel.notePageAspect(CGFloat(loaded.width) / max(CGFloat(loaded.height), 1))
        case .failure(let failed):
            failure = failed
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                .fill(Color.white.opacity(0.04))
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(L10n.tr("reader.page.progress", index + 1, viewModel.pageCount))
                    .font(.system(size: DesignSystem.Typography.footnote).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 单页失败卡片

/// 单页失败卡片(图 6 Failed 态:归档仍打开,可继续读别的页)。
///
/// 从 `ReaderCanvas` 抽出来共用(2026-09-21):滚动模式的行也要同一张卡 ——
/// 同一种失败在两种模式下长得不一样,是最容易让人以为「换模式把包弄坏了」的事
struct PageFailureCard: View {

    let failure: ReaderViewModel.Failure
    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.tr(failure.titleKey))
                .font(.system(size: DesignSystem.Typography.body, weight: .medium))
            if let bodyKey = failure.bodyKey {
                Text(failure.bodyArg.map { L10n.tr(bodyKey, $0) } ?? L10n.tr(bodyKey))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }
            // 加密页顺手给一条出路:否则用户看到「此页已加密」也不知道去哪输密码
            // (菜单里那一项不够显眼)。只在真有未解锁页时出现
            if viewModel.hasLockedPages {
                Button(L10n.tr("app.menu.unlock")) { viewModel.beginUnlock() }
                    .buttonStyle(.borderless)
                    .padding(.top, DesignSystem.Spacing.xs)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
    }
}
