// AI-Generated | 可修改
// PageGridView —— 缩略图网格面板(设计文档 §5.14,v1.1 2026-09-18)
// ----------------------------------------------------------------------------
// 这是 v1 里**第一个「让你看看有什么」的入口**。此前所有快速移动手段
// (⌥⌘G 页码跳转 / ⌘D 书签 / ⇧⌘↑↓ 首末页)都属于「你已经知道要去哪」型 ——
// 想找某一页只能一张张翻着认。
//
// 视图只做三件事:把池子里的图铺出来、把没有图的格子说清楚、点一下跳过去。
// 生成、预算、取消语义全在 `PageGridBuilder` / `ReaderViewModel`,
// 本文件不碰任何 I/O。
//
// 两个刻意的呈现选择:
//   · **没图的格子不是空白** —— 显示页码。空白格子会被读成「这一页是空的」,
//     而真相是「这一页还没生成到」或「这一页读不出来」,两者都必须能分辨;
//   · **进度条与「停止」常驻顶部** —— 生成可能要几秒(顺序扫 + 逐页解码),
//     没有进度就是"卡住了";没有停止就变成了"关不掉的重活"
import SwiftUI

struct PageGridSheet: View {

    @ObservedObject var viewModel: ReaderViewModel

    /// 格子最小宽度。140pt 是「一眼能认出画的是哪一页」的下限,
    /// 再小就退化成色块了
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignSystem.Spacing.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            grid
            actions
        }
        .padding(DesignSystem.Spacing.lg)
        // 与密码 / 完整性面板同一套口径:居中面板 + 明确上下限,不让内容横贯整窗。
        // 网格需要的是**面积**,所以下限比那两个大得多
        .frame(minWidth: 720, idealWidth: 860, maxWidth: 1100,
               minHeight: 520, idealHeight: 640, maxHeight: 900)
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
                if report.skippedEncrypted == 0, report.failedCount == 0 {
                    Text(L10n.tr("reader.grid.hint"))
                        .font(.system(size: DesignSystem.Typography.footnote))
                        .foregroundStyle(.secondary)
                }
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
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                ForEach(0..<viewModel.pageCount, id: \.self) { index in
                    cell(index)
                }
            }
            .padding(.vertical, DesignSystem.Spacing.xs)
        }
        // 网格里的滚动绝不能落到画布的滚轮监视器上(那会翻底下的页)——
        // ReaderCanvas 里已按 `isGridSheetPresented` 让位,这里再兜一层
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ index: Int) -> some View {
        let isCurrent = index == viewModel.pageIndex
        return Button {
            viewModel.goTo(index)
            viewModel.dismissGrid()
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
            Spacer()
            // 「停止」只在生成时有意义。停完**面板不关**,让用户看到
            // 「已经生成了多少张」—— 那正是「我还得再点一次吗」的答案
            if viewModel.isGridBuilding {
                Button(L10n.tr("reader.grid.stop")) { viewModel.cancelGridBuild() }
            }
            // 已有结果时不显示「重新生成」的**唯一**理由:没有任何东西可重做。
            // 生成中被 cancel 之后按钮会换成它,用户可以接着来
            if !viewModel.isGridBuilding, viewModel.grid != nil {
                Button(L10n.tr("reader.grid.regenerate")) { viewModel.rebuildGrid() }
            }
            Button(L10n.tr("reader.grid.done")) { viewModel.dismissGrid() }
                .keyboardShortcut(.cancelAction)      // Esc
        }
    }
}
