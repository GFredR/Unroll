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
                EmptyStateView(onOpen: { viewModel.open(url: $0) })
            case .opening:
                OpeningView()
            case .failed(let failure):
                FailureView(failure: failure, onOpen: { viewModel.open(url: $0) })
            case .reading:
                ReaderCanvas(viewModel: viewModel)
            }
        }
        // 顺序铁律:先 .frame 撑满窗口再 .background —— 反过来背景只裹住内容
        // 自身大小,窗口中央会浮一块「内容大小的色块」(2026-09-14 实测踩坑)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Palette.canvas.ignoresSafeArea())
        // 拖拽打开:全阶段可用(空态的主入口、阅读中的换书入口)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            viewModel.open(url: url)
            return true
        }
    }
}

// MARK: - 空态(欢迎页:AppIcon + 打开按钮 + 虚线拖放区)

private struct EmptyStateView: View {

    /// 「打开文件…」回调(ReaderView 注入 viewModel.open,url 归 VM 管,与 FailureView 同款)
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            appIcon
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 6)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text(L10n.tr("reader.empty.title"))
                    .font(.system(size: DesignSystem.Typography.display, weight: .bold))

                Text(L10n.tr("reader.empty.hint"))
                    .font(.system(size: DesignSystem.Typography.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button(L10n.tr("reader.empty.open"), action: chooseFile)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(DesignSystem.Palette.brand)
                .keyboardShortcut("o", modifiers: .command)
        }
        // 虚线框:明示整块区域都能拖文件进来(拖放挂在 ReaderView 根部,全阶段可用)
        .padding(DesignSystem.Spacing.xl + DesignSystem.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.dropZone)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
                .foregroundStyle(Color.white.opacity(0.14))
                .padding(DesignSystem.Spacing.lg)
        )
    }

    private func chooseFile() {
        if let url = ArchivePicker.pick() {
            onOpen(url)
        }
    }

    /// 直接用 AppIcon(Dock / Finder 同一张脸,品牌一致);SF Symbol 仅作兜底
    private var appIcon: some View {
        Group {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "book")
                    .font(.system(size: 64))
                    .foregroundStyle(DesignSystem.Palette.brand)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)   // 装饰性图标不进 VoiceOver(AGENTS.md 十一.3)
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

    /// 「打开其他文件…」:面板逻辑与主菜单共用 ArchivePicker(单一真源)
    private func chooseAnother() {
        if let url = ArchivePicker.pick() {
            onOpen(url)
        }
    }
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
    /// 滚轮/触控板监视器(M3 定夺项:接入,节流 + 阈值防误触)
    @State private var scrollMonitor: Any?
    @State private var lastWheelPageAt = Date.distantPast
    /// HUD 显隐(活动即现,静止 2.5s 淡出;计时器在画布侧,HUDView 只渲染)
    @State private var hudVisible = false
    @State private var hudHideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DesignSystem.Palette.canvas.ignoresSafeArea()

                if let failure = viewModel.presentation.failure {
                    pageFailureCard(failure)
                } else {
                    spread
                }

                if viewModel.presentation.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HUDView(viewModel: viewModel, visible: hudVisible)
            }
            .contentShape(Rectangle())   // 点击区覆盖整个画布(含黑边)
            // 鼠标/触控板移动 → HUD 立现(onContinuousHover 只在移动时触发)
            .onContinuousHover { _ in pokeHUD() }
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
        .onAppear {
            installKeyMonitor()
            installScrollMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            removeScrollMonitor()
        }
    }

    // MARK: 页面内容

    /// 当前摊位:单页 = 主图;双页 = 主图+次页(右开时视觉上第一页在右)
    @ViewBuilder
    private var spread: some View {
        if let primary = viewModel.presentation.image {
            if viewModel.layout == .dual, let secondary = viewModel.secondary {
                spreadView([primary, secondary])
            } else if viewModel.layout == .dual {
                // 次页未就绪:主图先单页垫着(加载完自动变双页,不闪)
                spreadView([primary])
            } else {
                spreadView([primary])
            }
        }
    }

    /// 摊位渲染:等高并排 + 共用缩放平移。右开 = 数组反序(第一页靠右,读向右→左)
    private func spreadView(_ images: [CGImage]) -> some View {
        let ordered = viewModel.direction == .rightToLeft ? images.reversed() : images
        let effective = min(max(zoom * pinchScale, 1), maxZoom)
        return HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
        }
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

    /// 页码指示已由 HUDView 替代(M3);保留此注释占位历史

    /// 鼠标/触控板活动 → HUD 立现,静止 2.5s 后淡出(每次活动都重置计时)
    private func pokeHUD() {
        hudVisible = true
        hudHideTask?.cancel()
        hudHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            hudVisible = false
        }
    }

    // MARK: 手势

    /// 缩放上限(实例常量:Swift 不允许实例上下文裸引用 static 成员)
    private let maxZoom: CGFloat = 8

    /// 半屏单击翻页(仅适配视图下;放大后单击让位给平移体验)。
    /// 右开:前进方向是「向左」,左右语义随之反转(§0 决策 3)
    private func spatialTap(in proxy: GeometryProxy) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard zoom * pinchScale <= 1 else { return }
            let onLeftHalf = value.location.x < proxy.size.width / 2
            let goForward = viewModel.direction == .rightToLeft ? onLeftHalf : !onLeftHalf
            if goForward {
                viewModel.nextPage()
            } else {
                viewModel.previousPage()
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
            case .leftArrow:
                // 左右箭头跟随阅读方向(右开时「向左」= 前进);PgUp/PgDn/Home/End
                // 保持文档语义(封面定位不随方向变)
                if viewModel.direction == .rightToLeft {
                    viewModel.nextPage()
                } else {
                    viewModel.previousPage()
                }
                return nil
            case .rightArrow:
                if viewModel.direction == .rightToLeft {
                    viewModel.previousPage()
                } else {
                    viewModel.nextPage()
                }
                return nil
            case .pageUp, .home:
                viewModel.previousPage(); return nil
            case .pageDown, .end:
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

    // MARK: 滚轮/触控板翻页(缺口表「M2 刻意不做 → M3 定夺接入」)

    /// 约定:滚轮下滚 / 触控板上扫 = 下一页(delta < 0 → next),与主流阅读器一致;
    /// 横扫取 |deltaX| 更大的轴(触控板横扫漫画页)。0.3s 节流 + 幅度阈值防惯性误翻;
    /// 放大状态下滚轮让位给滚动/平移体验,不翻页。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard zoom * pinchScale <= 1 else { return event }
            let now = Date()
            guard now.timeIntervalSince(lastWheelPageAt) > 0.3 else { return event }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy
            guard abs(delta) > 4 else { return event }

            if delta < 0 {
                viewModel.nextPage()
            } else {
                viewModel.previousPage()
            }
            lastWheelPageAt = now
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
