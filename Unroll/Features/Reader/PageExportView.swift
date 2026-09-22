// AI-Generated | 可修改
// PageExportView —— 「导出本卷页文件」的进度与结论面板(2026-09-21)
// ----------------------------------------------------------------------------
// 视图只做两件事:把进度说出来、把结论说清。导出本身全在
// `PageSequenceExporter`(纯逻辑)/ `ReaderViewModel`(编排),本文件不碰 I/O。
//
// 呈现上的两条硬要求,都是从既有面板(网格 / 完整性检查)继承下来的:
//   · **进度与「停止」常驻** —— 200 页的包要读要写,没有进度就是"卡住了",
//     没有停止就变成了"关不掉的重活";
//   · **四种停止原因分开说,一句话糊过去必然说谎**:
//       「已停止」可能是用户自己按的(不是错),
//       也可能是磁盘满了(要说,否则用户以为导完了),
//       还可能是包坏得读不下去(此时**剩几页是未知的**,不能说成"就这些")。
//     同理:加密跳过的页不是坏页,坏页要**点名**。
import ArchiveKit
import SwiftUI

struct PageExportSheet: View {

    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            actions
        }
        .padding(DesignSystem.Spacing.lg)
        // 这个面板只需要读一句话 + 决定要不要停,比网格小得多
        .frame(minWidth: 380, idealWidth: 440, minHeight: 170, idealHeight: 200)
    }

    // MARK: - 顶部:标题 + 进度 / 结论

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(L10n.tr("reader.export.title", viewModel.pageCount))
                .font(.system(size: DesignSystem.Typography.title, weight: .semibold))

            if let state = viewModel.exportState {
                switch state {
                case .running(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(maxWidth: .infinity)
                    Text(L10n.tr("reader.export.running", done, total))
                        .font(.system(size: DesignSystem.Typography.footnote))
                        .foregroundStyle(.secondary)
                case .ready(let report):
                    status(report)
                }
            }
        }
    }

    private func status(_ report: PageSequenceReport) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(L10n.tr("reader.export.written", report.delivered))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)

            if let notice = stopNotice(report.stop) {
                // 图标是装饰性的,不进 VoiceOver(AGENTS.md 十一.3)
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: notice.symbol)
                        .accessibilityHidden(true)
                    Text(L10n.tr(notice.key))
                        .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
                }
                .foregroundStyle(DesignSystem.Palette.brand)
            } else if report.coversWholeArchive {
                Text(L10n.tr("reader.export.hint"))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }

            if report.skippedEncrypted > 0 {
                Text(L10n.tr("reader.export.skippedEncrypted", report.skippedEncrypted))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }
            if report.failedCount > 0 {
                Text(L10n.tr("reader.export.failed", report.failedCount,
                             pageList(report.failedPages)))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }
            // 「没导完」必须单独说一句:上面三行都在讲已经发生的事,
            // 而用户真正要判断的是「我还缺多少」—— 这一行不能省
            if !report.coversWholeArchive {
                Text(L10n.tr("reader.export.remaining", report.remaining))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 停止原因 → (图标, 文案键)。`.finished` 不是「异常」,不进这一组。
    /// `.sinkStopped` 在 App 侧的语义就是**写盘失败**(见 `PageSequenceExporter`)——
    /// Kit 只说「消费方叫停」,由这一层负责翻译成用户能懂的话
    private func stopNotice(_ stop: PageSequenceStop) -> (symbol: String, key: String)? {
        switch stop {
        case .finished:    return nil
        case .cancelled:   return ("pause.circle.fill", "reader.export.cancelled")
        case .sinkStopped: return ("exclamationmark.triangle.fill", "reader.export.writeFailed")
        case .stalled:     return ("exclamationmark.triangle.fill", "reader.export.stalled")
        }
    }

    /// 坏页列表。用系统的 `ListFormatter` —— 中英的连接符与顿号不一样
    /// ("12, 57 and 88" / "12、57 和 88"),自己拼字符串会把英文写成中文格式。
    /// 报告里存的是 0 起下标,给用户看要 +1
    private func pageList(_ pages: [Int]) -> String {
        ListFormatter.localizedString(byJoining: pages.map { String($0 + 1) })
    }

    // MARK: - 底部

    private var actions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if viewModel.isExportRunning {
                Button(L10n.tr("reader.export.stop")) { viewModel.cancelExport() }
            }
            Spacer()
            Button(L10n.tr("reader.export.done")) { viewModel.dismissExport() }
        }
    }
}
