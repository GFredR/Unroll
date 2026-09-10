// AI-Generated | 可修改
// ReaderView —— 阅读画布(设计文档 §4.1 / §5.2-5.6,M2 实现)
// ----------------------------------------------------------------------------
// 结构:根视图按 VM 的归档阶段切换四个子视图(空态 / 打开中 / 错误态 / 画布)。
// 画布为纯 SwiftUI(§5.6 Plan A):M2 末实测 200 页连翻,掉帧才切 AppKit(NSScrollView)。
//
// M2 的交互边界(刻意收窄,其余归 M3):
//   · 翻页:←/→/↑/↓/空格/PgUp/PgDn/Home/End 键 + 左右半屏单击;
//   · 缩放:双击 1×↔2×,捏合(MagnifyGesture)1×–8×;
//   · 平移:仅放大后可拖拽,回到 1× 自动归位;
//   · 滚轮翻页 / 触控板滑动翻页:M2 不做(与缩放/滚动语义冲突,留 M3 定夺)。
//
// 键盘用 NSEvent 本地监视器而非 .onKeyPress:文档型 App 的按键必须无视焦点
// (画布可能没成为 firstResponder),本地监视器与焦点解耦,行为可预期。
// 拖拽打开挂在根视图:任何阶段(包括错误态)都可以直接拖入新文件。
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderView: View {

    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        Group {
            switch viewModel.phase {
            case .noDocument:
                EmptyStateView()
            case .opening:
                OpeningView()
            case .failed(let failure):
                FailureView(failure: failure, onOpen: { viewModel.open(url: $0) })
            case .reading:
                ReaderCanvas(viewModel: viewModel)
            }
        }
        .background(DesignSystem.Palette.canvas.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 拖拽打开:全阶段可用(空态的主入口、阅读中的换书入口)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            viewModel.open(url: url)
            return true
        }
    }
}

// MARK: - 空态(拖入提示)

private struct EmptyStateView: View {

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "book")
                .font(.system(size: 64))
                .foregroundStyle(DesignSystem.Palette.brand)   // 产品特色位用品牌色(§7 视觉定锚)
                .accessibilityHidden(true)                     // 装饰性图标不进 VoiceOver(AGENTS.md 十一.3)

            Text(L10n.tr("reader.empty.title"))
                .font(.system(size: DesignSystem.Typography.title, weight: .bold))

            Text(L10n.tr("reader.empty.hint"))
                .font(.system(size: DesignSystem.Typography.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.lg)
        }
    }
}

// MARK: - 打开中

private struct OpeningView: View {

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.tr("reader.opening"))
                .font(.system(size: DesignSystem.Typography.body))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 错误态(§5.9.3.1:说清发生了什么 + 给出下一步)

private struct FailureView: View {

    let failure: ReaderViewModel.Failure
    /// 选中文件后回调(ReaderView 注入 viewModel.open,url 归 VM 管)
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(DesignSystem.Palette.brand)
                .accessibilityHidden(true)

            Text(L10n.tr(failure.titleKey))
                .font(.system(size: DesignSystem.Typography.title, weight: .bold))

            if let bodyKey = failure.bodyKey {
                Text(bodyText(bodyKey))
                    .font(.system(size: DesignSystem.Typography.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
            }

            Button(L10n.tr("archive.error.chooseAnother"), action: chooseAnother)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, DesignSystem.Spacing.sm)
        }
    }

    /// 带 %d 参数的文案在此填充;纯文案直接返回
    private func bodyText(_ key: String) -> String {
        if let arg = failure.bodyArg {
            return L10n.tr(key, arg)
        }
        return L10n.tr(key)
    }

    /// 「打开其他文件…」:NSOpenPanel 限四种漫画归档 + zip(与 Info.plist 关联一致)
    private func chooseAnother() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.allowedTypes.compactMap { UTType($0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onOpen(url)
    }

    private static let allowedTypes = [
        "com.gfredr.unroll.cbz",
        "com.gfredr.unroll.cbr",
        "com.gfredr.unroll.cb7",
        "com.gfredr.unroll.cbt",
        "public.zip-archive",
    ]
}

// MARK: - 阅读画布(§5.6 Plan A:纯 SwiftUI)

private struct ReaderCanvas: View {

    @ObservedObject var viewModel: ReaderViewModel

    /// 缩放(1 = 适配窗口;放大后 offset 才生效)
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragDelta: CGSize = .zero

    /// NSEvent 本地监视器(键盘翻页;onAppear 挂、onDisappear 摘)
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DesignSystem.Palette.canvas.ignoresSafeArea()

                if let failure = viewModel.presentation.failure {
                    pageFailureCard(failure)
                } else if let image = viewModel.presentation.image {
                    pageImage(image)
                }

                if viewModel.presentation.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                pageIndicator
            }
            .contentShape(Rectangle())   // 点击区覆盖整个画布(含黑边)
            // 单击翻页(半屏分区);双击缩放的判定优先于单击
            .gesture(spatialTap(in: proxy))
            .gesture(TapGesture(count: 2).onEnded(toggleZoom))
            .gesture(magnify)
            .gesture(zoom > 1 ? drag : nil)
        }
        .onChange(of: viewModel.pageIndex) { _, _ in
            // 翻页即回到适配视图:缩放状态不属于「这一页」,属于「这次阅读会话」
            zoom = 1
            offset = .zero
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    // MARK: 页面内容

    private func pageImage(_ image: CGImage) -> some View {
        let effective = min(max(zoom * pinchScale, 1), maxZoom)
        return Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
            .scaleEffect(effective)
            .offset(x: offset.width + dragDelta.width,
                    y: offset.height + dragDelta.height)
            .animation(.easeOut(duration: 0.12), value: effective)
    }

    /// 单页失败卡片(图 6 Failed 态;归档仍打开,可继续翻其他页)
    private func pageFailureCard(_ failure: ReaderViewModel.Failure) -> some View {
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
        }
        .padding(DesignSystem.Spacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
    }

    /// 页码指示(M3 的 HUD 会替代它;M2 先给最小可确认的翻页反馈)
    private var pageIndicator: some View {
        Text(L10n.tr("reader.page.progress", viewModel.pageIndex + 1, viewModel.pageCount))
            .font(.system(size: DesignSystem.Typography.hud).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, DesignSystem.Spacing.sm + 2)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
    }

    // MARK: 手势

    /// 缩放上限(实例常量:Swift 不允许实例上下文裸引用 static 成员)
    private let maxZoom: CGFloat = 8

    /// 半屏单击翻页(仅适配视图下;放大后单击让位给平移体验)
    private func spatialTap(in proxy: GeometryProxy) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard zoom * pinchScale <= 1 else { return }
            if value.location.x < proxy.size.width / 2 {
                viewModel.previousPage()
            } else {
                viewModel.nextPage()
            }
        }
    }

    private func toggleZoom() {
        if zoom > 1 {
            zoom = 1
            offset = .zero
        } else {
            zoom = 2
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1), maxZoom)
                if zoom <= 1 { offset = .zero }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset = CGSize(width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height)
            }
    }

    // MARK: 键盘(本地监视器,与焦点解耦)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 带修饰键的按键(⌘O / ⌘W / 快捷键系统)一律放行,绝不拦截
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            switch event.specialKey {
            case .leftArrow, .pageUp, .home:
                viewModel.previousPage(); return nil
            case .rightArrow, .pageDown, .end:
                viewModel.nextPage(); return nil
            case .downArrow:
                viewModel.nextPage(); return nil
            default:
                break
            }
            if event.characters == " " {          // 空格 = 下一页(阅读器惯例)
                viewModel.nextPage(); return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
