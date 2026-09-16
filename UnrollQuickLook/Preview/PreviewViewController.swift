// AI-Generated | 可修改
// PreviewViewController —— Finder 空格预览扩展(设计文档 §2.4 v2 候选池落地)
// ----------------------------------------------------------------------------
// 效果:Finder 里选中归档按空格,直接看到封面原图 + 总页数,不用先打开 App。
// 扩展点:com.apple.quicklook.preview(与缩略图是两个独立 appex,见 Thumbnail/)。
//
// 定位纪律(与缩略图一致,刻意不做成"迷你阅读器"):
//   · 设计文档 §2.4 的原话是「**预览归档首页**」—— 就只做首页。加翻页等于在
//     QuickLook 面板里重造一个 Reader,收益低而维护面翻倍(面板不吃键盘事件、
//     宿主超时会回收进程),真正的阅读仍然应该回到 App。
//   · 因此这里只做三件事:显示首页、说清总页数、给出"用开卷打开"的下一步。
//
// 三态呈现(§5.9 的"绝不闪退"在扩展里同样成立 —— 扩展崩了宿主只会显示
// 一句无信息量的系统错误,比"读不出来"更糟):
//   正常 → 首页 + 「共 N 页 · 用开卷打开可翻页阅读」
//   加密 → 锁图标 + 如实说明是加密(不吞成通用错误)
//   损坏/无图片 → 感叹号 + 无法预览
import AppKit
import ArchiveKit
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let imageView = NSImageView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    /// 预览面板初始尺寸:竖版漫画页为主,给一个偏高的默认值
    private static let defaultSize = NSSize(width: 860, height: 640)

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        for subview in [imageView, symbolView, titleLabel, hintLabel] {
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            // 图区:占满标题以上的全部空间
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -12),

            // 只有在读不出来时出现的居中图标(与图区同一块空间)
            symbolView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 64),
            symbolView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = Self.defaultSize
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        // 读归档是同步 IO:必须离开主线程,否则面板先转菊花再突然跳出内容。
        // 只捕获 URL(URL 是 Sendable),归档对象不跨隔离域传递
        let outcome = await Task.detached(priority: .userInitiated) {
            CoverProvider.firstPage(at: url, maxPixel: CoverProvider.previewPixel)
        }.value
        render(outcome)
    }

    // MARK: - 渲染

    @MainActor
    private func render(_ outcome: CoverOutcome) {
        switch outcome {
        case .page(let page, let total):
            symbolView.isHidden = true
            imageView.isHidden = false
            imageView.image = NSImage(cgImage: page.image, size: .zero)
            titleLabel.stringValue = L10n.tr("ql.pages", total)
            // 只有一页时不给"打开阅读"的废话提示
            hintLabel.stringValue = total > 1 ? L10n.tr("ql.openHint") : ""

        case .encrypted:
            showPlaceholder(symbol: "lock.fill",
                            title: L10n.tr("ql.encrypted"),
                            hint: "")

        case .unreadable:
            showPlaceholder(symbol: "exclamationmark.triangle.fill",
                            title: L10n.tr("ql.unreadable"),
                            hint: "")
        }
    }

    @MainActor
    private func showPlaceholder(symbol: String, title: String, hint: String) {
        imageView.isHidden = true
        symbolView.isHidden = false
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolView.contentTintColor = .tertiaryLabelColor
        titleLabel.stringValue = title
        hintLabel.stringValue = hint
    }
}
