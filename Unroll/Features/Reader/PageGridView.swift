// AI-Generated | 可修改
// PageGridView —— 缩略图网格层(设计文档 §5.14;2026-09-18 落地为面板,
//                                          2026-09-23 提升为**默认层**)
// ----------------------------------------------------------------------------
// 它是「让你看看有什么」的入口。此前所有快速移动手段
// (⌥⌘G 页码跳转 / ⌘D 书签 / ⇧⌘↑↓ 首末页)都属于「你已经知道要去哪」型 ——
// 想找某一页只能一张张翻着认。
//
// **2026-09-23 的定位变化**(这一段决定了本文件为什么不再是 sheet):
// 它从「⇧⌘G 弹出的浮层面板」变成了**打开归档后的默认落点**,与阅读层构成两级
// 结构。于是:
//   · 尺寸不再是"面板的上限" —— 它撑满窗口。原先那组
//     `720–1100 × 520–900` 是**面板**口径,留着会在宽窗口里缩成一块居中浮岛;
//   · 没有「完成」按钮 —— "关掉面板"这个动作不存在了。离开网格只有两条路:
//     点一格(进阅读层)、或 Esc / ⇧⌘G(切回阅读层);
//   · 切走**不取消生成**(原先 `dismissGrid()` 会取消):切到阅读层是最常见的
//     动作,而用户随时会按「浏览」回来 —— 半空的网格比什么都糟。
//     取消只剩「停止」这一个入口(见 ReaderViewModel.cancelGridBuild 的说明);
//   · **必须锁定深色语义** —— 它现在落在画布黑底上(不再有 sheet 自带的系统
//     背景),而浅色系统外观下 `primary` / `secondary` 会解析成深色文字,
//     黑底上直接看不见(与密码页同一个坑,见 ReaderView 那一处的注释)。
//
// 视图只做三件事:把池子里的图铺出来、把没有图的格子说清楚、点一下跳过去。
// 生成、预算、取消语义全在 `PageGridBuilder` / `ReaderViewModel`,
// 本文件不碰任何 I/O。
//
// 两个刻意的呈现选择:
//   · **没图的格子不是空白** —— 显示页码。空白格子会被读成「这一页是空的」,
//     而真相是「这一页还没生成到」或「这一页读不出来」,两者都必须能分辨;
//   · **进度条与「停止」常驻顶部** —— 生成要几秒到几十秒(顺序扫 + 逐页解码),
//     没有进度就是"卡住了";没有停止就变成了"关不掉的重活"。这两条在它变成
//     默认层之后**更要紧**了:现在是**每次打开归档都跑**这段顺序扫描
import SwiftUI

struct PageGridView: View {

    @ObservedObject var viewModel: ReaderViewModel

    /// 格子最小宽度。140pt 是「一眼能认出画的是哪一页」的下限,
    /// 再小就退化成色块了
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignSystem.Spacing.md)]

    /// 网格自己的滚动锚点(2026-09-23)。**刻意是视图私有 state,不绑 VM** ——
    /// 用户滚动网格时系统会往这里回写,而"网格滚到哪"**不是**当前阅读页:
    /// 绑到 `viewModel.pageIndex` 会让"滚一下网格"变成"换一页"。
    /// Binding 只是借 `scrollPosition(id:)` 这个 API 把初始位置摆好
    @State private var scrollTarget: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            grid
            actions
        }
        .padding(DesignSystem.Spacing.lg)
        // 撑满窗口 —— 网格需要的是**面积**(与它还是面板时同一个理由,
        // 只是那时受 sheet 的尺寸上限约束)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        // Esc = 切回阅读层。与阅读层里「浏览」按钮的方向相反 ——
        // 两层互相可返,这是「点击返回可以回到缩略图」的对称面
        .onExitCommand { viewModel.showReader() }
    }

    // MARK: - 顶部:标题 + 进度

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(L10n.tr("reader.grid.title", viewModel.pageCount))
                .font(.system(size: DesignSystem.Typography.title, weight: .semibold))

            if let state = viewModel.grid {
                switch state {
                case .building(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(maxWidth: .infinity)
                    Text(L10n.tr("reader.grid.building", done, total))
                        .font(.system(size: DesignSystem.Typography.footnote))
                        .foregroundStyle(.secondary)
                case .ready(let report):
                    statusLine(report)
                }
            }
        }
    }

    /// 结论行。**四种停止原因分开说** —— 合成一句必然要说谎:
    ///   · 预算到顶 → 后面的页**永远不会有图**,不说清用户会一直等;
    ///   · 加密跳过 → 那不是损坏,是"没给密码";
    ///   · 提前停下 → "没查到"不等于"没有",不能说得像全查过了
    @ViewBuilder
    private func statusLine(_ report: PageGridReport) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(L10n.tr("reader.grid.generated", report.generated, report.pages))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)

            switch report.stop {
            case .finished:
                // 「正常结束且无跳过无坏页」时**故意不多说一句**(2026-09-23)。
                // 这一层从面板变成**默认层**之后,"怎么用"的说明搬到了底栏那行常驻
                // 提示(`reader.grid.leaveHint`)。这里再写一遍不只是啰嗦 —— 旧文案
                // 写的是"点任意一页即可**跳过去**",而底栏写的是"点一格**开始阅读**":
                // 同一个动作两种说法,读到的人得自己判断哪个才算数。
                // 状态行只报事实(说「已生成 30 / 30 张」就够),操作说明只有一处。
                // (`EmptyView` 而不是 `break` —— ViewBuilder 里不许出现跳转语句)
                EmptyView()
            case .budgetReached:
                warning("exclamationmark.triangle.fill",
                        L10n.tr("reader.grid.budgetReached"))
            case .cancelled:
                warning("pause.circle.fill", L10n.tr("reader.grid.cancelled"))
            case .scannerStalled:
                warning("exclamationmark.triangle.fill",
                        L10n.tr("reader.grid.stalled"))
            }

            if report.skippedEncrypted > 0 {
                Text(L10n.tr("reader.grid.skippedEncrypted", report.skippedEncrypted))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }
            if report.failedCount > 0 {
                Text(L10n.tr("reader.grid.failed", report.failedCount))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .accessibilityHidden(true)   // 装饰性图标不进 VoiceOver(AGENTS.md 十一.3)
            Text(text)
                .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
        }
        .foregroundStyle(DesignSystem.Palette.brand)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 网格

    /// LazyVGrid 按需实例化:`pageCount` 可以是几千,只有滚进视野的格子才被创建。
    /// 缩略图本身由 VM 的池子提供(纯查询),没有 I/O 也不触发解码 ——
    /// 滚动因此永远不会把读盘带进渲染路径
    ///
    /// **进入本层时自动滚到当前页**(2026-09-23)。此前打开面板**永远从顶部开始**:
    /// 读到第 150 页时按 ⇧⌘G,看到的是第 1–12 格,得自己滚下去找 —— 而那一格
    /// 明明有品牌色描边,却因为不在视野里等于没有。这是「返回」这条链上最实际的
    /// 一个缺口:高亮一直在,缺的是把它带到眼前。
    ///
    /// 用 `scrollPosition(id:)`(而不是 `ScrollViewReader.scrollTo`):前者是
    /// **声明式**的,不要求目标格已经实例化 —— 而 LazyVGrid 恰恰只实例化视野内的
    /// 格子,"滚到第 150 格"时那一格多半还不存在。同一个 API 在本仓库的
    /// `PageScrollView` 里已经跑着(`scrollPosition(id: $viewModel.scrollTarget)`)
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                ForEach(0..<viewModel.pageCount, id: \.self) { index in
                    cell(index)
                }
            }
            .padding(.vertical, DesignSystem.Spacing.xs)
        }
        .scrollPosition(id: $scrollTarget, anchor: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 滚动层与阅读层互斥渲染,画布的滚轮监视器此刻**根本没挂上**
        // (ReaderCanvas 已随分支卸载),所以这里不必再"让位"
        .onAppear { scrollTarget = viewModel.pageIndex }
    }

    private func cell(_ index: Int) -> some View {
        let isCurrent = index == viewModel.pageIndex
        return Button {
            // 点格 = 「去这一页,并且开始读」—— 两层结构里的一条完整动作,
            // 所以两句的顺序不能反:先 `goTo`(它会夹紧页号、双页时归一到摊首面),
            // 再切阅读层。反过来切层那一帧画布读到的还是旧页号
            viewModel.goTo(index)
            viewModel.showReader()
        } label: {
            VStack(spacing: DesignSystem.Spacing.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.control)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))

                    if let image = viewModel.gridThumbnail(at: index) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(2)
                    } else {
                        // 没有图 = 还没生成到 / 读不出来。**显示页码而不是空白**:
                        // 空白会被读成「这一页是空的」,而它仍然可以点进去
                        Text("\(index + 1)")
                            .font(.system(size: DesignSystem.Typography.body)
                                .monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.control)
                        .strokeBorder(isCurrent ? DesignSystem.Palette.brand
                                                : Color.clear,
                                      lineWidth: 2)
                }

                Text("\(index + 1)")
                    .font(.system(size: DesignSystem.Typography.footnote).monospacedDigit())
                    .foregroundStyle(isCurrent ? DesignSystem.Palette.brand : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(L10n.tr("reader.grid.cellHint", index + 1))
        .accessibilityLabel(L10n.tr("reader.grid.cellHint", index + 1))
    }

    // MARK: - 底部按钮

    private var actions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // 出口提示(2026-09-23):本层**没有**「完成 / 关闭」按钮了 ——
            // 它不再是面板。而"怎么离开"第一次进来的人必须有处可查,
            // 一句话比一个按钮省地方,也不会被误读成"网格是要关掉的东西"
            Text(L10n.tr("reader.grid.leaveHint"))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)

            Spacer()
            // 「停止」只在生成时有意义。停完**本层不关**,让用户看到
            // 「已经生成了多少张」—— 那正是「我还得再点一次吗」的答案
            if viewModel.isGridBuilding {
                Button(L10n.tr("reader.grid.stop")) { viewModel.cancelGridBuild() }
            }
            // 已有结果时不显示「重新生成」的**唯一**理由:没有任何东西可重做。
            // 生成中被 cancel 之后按钮会换成它,用户可以接着来
            if !viewModel.isGridBuilding, viewModel.grid != nil {
                Button(L10n.tr("reader.grid.regenerate")) { viewModel.rebuildGrid() }
            }
        }
    }
}
