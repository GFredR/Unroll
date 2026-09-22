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
import ArchiveKit
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
            case .needsPassword:
                // 画布恒为黑(`Palette.canvas`),所以这里锁定深色语义 ——
                // 否则浅色系统外观下 primary/secondary 会解析成深色文字,黑底上
                // 直接看不见(阅读器是暗色场景,这一处必须显式声明)
                PasswordPromptView(
                    context: .opening,
                    failure: viewModel.passwordFailure,
                    onSubmit: { viewModel.submitPassword($0) },
                    onCancel: { viewModel.cancelPasswordPrompt() })
                    .environment(\.colorScheme, .dark)
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
        // 页码跳转(⌥⌘G):菜单命令只置位 VM 的开关,面板自身归 View(命令不持 View 状态)
        .sheet(isPresented: $viewModel.isJumpSheetPresented) {
            PageJumpSheet(viewModel: viewModel)
        }
        // 阅读中解锁部分加密包(「文件 → 输入解压密码…」触发)。
        // 刻意不加 `.environment(\.colorScheme, .dark)`:面板有自己的系统背景,
        // 跟随系统外观才对(全屏那个是黑底,情形不同)
        .sheet(isPresented: $viewModel.isUnlockSheetPresented) {
            PasswordPromptView(
                context: .unlocking,
                failure: viewModel.passwordFailure,
                onSubmit: { viewModel.submitUnlockPassword($0) },
                onCancel: { viewModel.cancelPasswordPrompt() })
        }
        // 完整性检查(⌥⌘V,2026-09-17)。用自定义 Binding 而不是直接绑 @Published:
        // 用户按 Esc / 点外面关掉时,SwiftUI 只会把标志置 false —— 那样**检查任务
        // 会一直跑下去**,而界面已经看不见它了(白烧 CPU 还占着磁盘)。
        // 把「关闭」这件事统一交给 dismissIntegrity(),它顺带停任务、清结论
        .sheet(isPresented: Binding(get: { viewModel.isIntegritySheetPresented },
                                    set: { if !$0 { viewModel.dismissIntegrity() } })) {
            IntegritySheet(viewModel: viewModel)
        }
        // 缩略图网格(v1.1,⇧⌘G)。同样用自定义 Binding:用户按 Esc / 点外面关掉时,
        // SwiftUI 只会把标志置 false —— 那样**生成任务会一直跑下去**,
        // 而界面已经看不见它了(白烧 CPU 又占着磁盘)。统一交给 dismissGrid(),
        // 它顺带停任务
        .sheet(isPresented: Binding(get: { viewModel.isGridSheetPresented },
                                    set: { if !$0 { viewModel.dismissGrid() } })) {
            PageGridSheet(viewModel: viewModel)
        }
        // 导出本卷页文件(⇧⌘E,2026-09-21)。同样用自定义 Binding —— 用户按 Esc /
        // 点外面关掉时,SwiftUI 只把标志置 false,那样**导出会在后台接着跑到完**,
        // 而界面已经看不见它了(白烧 CPU、还在往磁盘里写)。统一交给 dismissExport()
        .sheet(isPresented: Binding(get: { viewModel.isExportSheetPresented },
                                    set: { if !$0 { viewModel.dismissExport() } })) {
            PageExportSheet(viewModel: viewModel)
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

    /// 连续滚动模式(2026-09-21)。画布在这一模式下整体换渲染路径,
    /// 并把缩放 / 平移 / 半屏点击那一整套手势让出去
    private var scrollMode: Bool { viewModel.layout == .scroll }

    /// 手势掩码:滚动模式下一律 `.none`(理由见 `body` 里那段注释)
    private var gestureMask: GestureMask { scrollMode ? .none : .all }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DesignSystem.Palette.canvas.ignoresSafeArea()

                if scrollMode {
                    // 连续滚动:一条独立的渲染路径(理由见 PageScrollView 文件头)
                    PageScrollView(viewModel: viewModel, onActivity: pokeHUD)
                } else if let failure = viewModel.presentation.failure {
                    pageFailureCard(failure)
                } else {
                    spread(in: proxy.size)
                }

                // 居中的加载指示**只属于分页模式**:滚动模式下每一行自己渲染,
                // 一个转圈图标会盖在正在读的那一页上
                if viewModel.presentation.isLoading, !scrollMode {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HUDView(viewModel: viewModel, visible: hudVisible, onActivity: pokeHUD)
            }
            .contentShape(Rectangle())   // 点击区覆盖整个画布(含黑边)
            // 鼠标/触控板移动 → HUD 立现(onContinuousHover 只在移动时触发)
            .onContinuousHover { _ in pokeHUD() }
            // 单击翻页(半屏分区);双击缩放的判定优先于单击。
            // 下面四条都带 `gestureMask`:**滚动模式下整体让位** ——
            // 平移手势与纵向滚动方向完全重叠,留着会把滚动视图的滚动整个吃掉。
            // 用 GestureMask.none 而不是条件构造手势:后者会改变视图树结构,
            // 切模式时整棵子树重建,滚动位置也就跟着丢了
            .gesture(spatialTap(in: proxy), including: gestureMask)
            .gesture(TapGesture(count: 2).onEnded(toggleZoom), including: gestureMask)
            .gesture(magnify, including: gestureMask)
            // 平移:放大后;或档位本身可能溢出窗口(适应宽/适应高/1:1)时也放行
            .gesture(zoom > 1 || viewModel.fitMode != .fitWindow ? drag : nil,
                     including: gestureMask)
        }
        .onChange(of: viewModel.pageIndex) { _, _ in
            // 翻页即回到适配视图:缩放状态不属于「这一页」,属于「这次阅读会话」
            zoom = 1
            offset = .zero
        }
        .onChange(of: viewModel.fitMode) { _, _ in
            // 换档位 = 换渲染基准:自由缩放系数与平移一并归零(档位本身保留)
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
    private func spread(in size: CGSize) -> some View {
        if let primary = viewModel.presentation.image {
            if viewModel.layout == .dual, let secondary = viewModel.secondary {
                spreadView([primary, secondary], in: size)
            } else if viewModel.layout == .dual {
                // 次页未就绪:主图先单页垫着(加载完自动变双页,不闪)
                spreadView([primary], in: size)
            } else {
                spreadView([primary], in: size)
            }
        }
    }

    /// 摊位渲染:按档位基准出尺寸 + 共用自由缩放平移。
    /// 右开 = 数组反序(第一页靠右,读向右→左)
    private func spreadView(_ images: [CGImage], in size: CGSize) -> some View {
        let ordered = viewModel.direction == .rightToLeft ? images.reversed() : images
        let effective = min(max(zoom * pinchScale, 1), maxZoom)
        return HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, image in
                let scale = pageScale(of: image, in: images, canvas: size)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(image.width) * scale,
                           height: CGFloat(image.height) * scale)
            }
        }
        .scaleEffect(effective)
        .offset(x: offset.width + dragDelta.width,
                y: offset.height + dragDelta.height)
        .animation(.easeOut(duration: 0.12), value: effective)
    }

    /// 单页在当前档位下的基准缩放(§2.1-4:适应窗口/适应宽/适应高/1:1)。
    /// 摊内统一适配高度:总宽高比 = Σ(宽/高),双页并排不横向溢出
    private func pageScale(of image: CGImage, in spread: [CGImage], canvas: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0, image.height > 0 else { return 1 }
        switch viewModel.fitMode {
        case .actualSize:
            return 1
        case .fitHeight:
            return canvas.height / CGFloat(image.height)
        case .fitWindow, .fitWidth:
            // 摊内可用宽 = 画布宽 − 页间距;H 使 Σ(w_i·H/h_i) = 可用宽
            let gaps = CGFloat(spread.count - 1) * DesignSystem.Spacing.xs
            let usableWidth = max(canvas.width - gaps, 1)
            let totalAspect = spread.reduce(CGFloat(0)) {
                $0 + CGFloat($1.width) / max(CGFloat($1.height), 1)
            }
            let fitHeight = usableWidth / max(totalAspect, 0.0001)
            switch viewModel.fitMode {
            case .fitWidth:
                return fitHeight / CGFloat(image.height)
            default:   // .fitWindow:还要保证整页高不超画布
                return min(fitHeight, canvas.height) / CGFloat(image.height)
            }
        }
    }

    /// 单页失败卡片(图 6 Failed 态;归档仍打开,可继续翻其他页)。
    /// 实体已抽到 `PageFailureCard`(2026-09-21):滚动模式的行要用同一张
    private func pageFailureCard(_ failure: ReaderViewModel.Failure) -> some View {
        PageFailureCard(failure: failure, viewModel: viewModel)
    }

    /// 页码指示已由 HUDView 替代(M3);保留此注释占位历史

    /// 鼠标/触控板活动 → HUD 立现,静止 2.5s 后淡出(每次活动都重置计时)。
    /// 淡出时**连光标一起藏掉**(2026-09-16):全屏沉浸阅读的惯例
    /// (QuickTime / VLC 同款)。用的是 `setHiddenUntilMouseMoves`,
    /// 鼠标一动光标立刻回来,不存在"找不着鼠标"的状态
    private func pokeHUD() {
        hudVisible = true
        hudHideTask?.cancel()
        hudHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            hudVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
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
            // 面板(页码跳转 / 缩略图网格)打开时让位:空格/方向键必须能正常进输入框,
            // 也必须能用来滚网格 —— 少了网格这一项,按空格会在**网格底下**翻页,
            // 用户看到的是"网格里空格键没反应,关掉发现在别处翻了好几页"
            guard !viewModel.isJumpSheetPresented,
                  !viewModel.isGridSheetPresented else { return event }
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
            // 面板打开时让位(滚轮不翻页)。**网格这一项尤其重要**:
            // 网格是靠滚轮浏览的,不拦截的话滚一下既滚了网格又翻了底下的页
            guard !viewModel.isJumpSheetPresented,
                  !viewModel.isGridSheetPresented else { return event }
            // **滚动模式必须整个让位**(2026-09-21)。不拦的话滚一下会同时
            // 「滚了列表」和「翻了一页」—— 这是"模式切了但滚轮还留在旧逻辑"
            // 最直观的坏法,而且看起来像滚动本身卡了
            guard !scrollMode else { return event }
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

// MARK: - 页码跳转面板(⌥⌘G,2026-09-15;目标页预览 v1.1 2026-09-18)

/// 输入 1-based 页码直接跳页。解析与夹紧全在 VM 的 `parsePageInput`(纯函数,可单测),
/// 本视图只负责输入与错误提示 —— 面板不持页码状态,关掉即无副作用。
///
/// **目标页预览(v1.1)**:输入停顿后显示那一页的小图,回答「我要去的是不是这一页」。
/// 此前这个面板只有一句「共 200 页」,用户凭记忆输数字,跳过去发现不对再翻回来 ——
/// 预览把这次往返省掉了。
///
/// 防抖(300ms)刻意放在**视图侧**:它是「打字节奏」这种界面感受,不是业务规则;
/// VM 的 `previewJumpTarget` 因此可以被单测直接调,不用等时间。
/// 每停顿一次就是一次真实读取(包里的一次定位 + 一次降采样解码),
/// 于是**必须防抖** —— 否则输「128」会连读三次。
private struct PageJumpSheet: View {

    @ObservedObject var viewModel: ReaderViewModel
    @State private var text = ""
    @FocusState private var isFocused: Bool
    /// 防抖任务(输入每变一次就取消重排)
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(L10n.tr("reader.jump.title"))
                .font(.system(size: DesignSystem.Typography.title, weight: .semibold))

            Text(L10n.tr("reader.jump.range", viewModel.pageCount))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("reader.jump.placeholder"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($isFocused)
                .onSubmit(submit)

            // 非法输入即时提示(不等到点「跳转」才报错)
            if !text.isEmpty, pageIndex == nil {
                Text(L10n.tr("reader.jump.invalid", viewModel.pageCount))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(DesignSystem.Palette.brand)
            }

            preview

            HStack(spacing: DesignSystem.Spacing.sm) {
                Spacer()
                Button(L10n.tr("reader.jump.cancel")) {
                    viewModel.isJumpSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)      // Esc
                Button(L10n.tr("reader.jump.go"), action: submit)
                    .keyboardShortcut(.defaultAction)  // Return
                    .disabled(pageIndex == nil)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 320)
        .onAppear {
            text = "\(viewModel.pageIndex + 1)"   // 预填当前页,改一位数字即可
            isFocused = true
            schedulePreview()                     // 预填的那一页也先给张图
        }
        .onDisappear {
            debounce?.cancel()
            // 预览是**瞬态**的(只有这一张,不进任何池子)—— 面板走时必须还回去,
            // 否则它成了唯一一处「关掉面板还占着内存」的地方
            viewModel.clearJumpPreview()
        }
        .onChange(of: text) { _, _ in schedulePreview() }
    }

    // MARK: 预览

    /// 预览区。**三态各有各的样子**:加载中(转圈)、可看(图)、取不出来(说明)。
    /// 取不出来时必须说原因 —— 转圈转到天荒地老会被当成"卡住了"
    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.28))

            if let failure = viewModel.jumpPreviewFailure {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .accessibilityHidden(true)
                    Text(L10n.tr(failure.titleKey))
                        .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
                    if let bodyKey = failure.bodyKey {
                        Text(failure.bodyArg.map { L10n.tr(bodyKey, $0) } ?? L10n.tr(bodyKey))
                            .font(.system(size: DesignSystem.Typography.footnote))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(DesignSystem.Spacing.sm)
            } else if let image = viewModel.jumpPreview,
                      viewModel.jumpPreviewPage == pageIndex {
                // 配对断言:`jumpPreviewPage == pageIndex` 才显示。快速改输入时
                // 旧图可能比新图晚到,少了这个判断会短暂显示**错误页**的预览 ——
                // 而这个面板的全部价值就在于「看一眼确认是哪一页」,
                // 显示出错页比什么都不显示更糟
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(DesignSystem.Spacing.xs)
            } else if viewModel.isJumpPreviewLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }

    /// 解析结果(0-based);非法 → nil
    private var pageIndex: Int? {
        ReaderViewModel.parsePageInput(text, pageCount: viewModel.pageCount)
    }

    /// 输入停顿 300ms 后再取预览。**非法输入直接清掉预览** ——
    /// 留着上一张会让「输了一半的页码」看起来像已经确认过了
    private func schedulePreview() {
        debounce?.cancel()
        guard let index = pageIndex else {
            viewModel.clearJumpPreview()
            return
        }
        debounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            viewModel.previewJumpTarget(index)
        }
    }

    private func submit() {
        guard let index = pageIndex else { return }
        viewModel.goTo(index)
        viewModel.isJumpSheetPresented = false
    }
}

// MARK: - 完整性检查面板(⌥⌘V,2026-09-17)

/// 三态:进行中(带进度)/ 干净 / 有问题。
///
/// 判据与文案分工的要点:结论**不是**「有没有坏页」这一个布尔,而是三件事
/// 分开说 —— 坏页数、是否跑完、跳过了多少加密页。合成一句话必然要说谎:
///   · 有坏页但没跑完 → 真正的坏页只会更多,不能报「共 N 页坏了」;
///   · 没坏页但没跑完 → 更不能报「没有损坏」(那是把「没查到」当「查到没有」);
///   · 加密页跳过了 → 它们既不是坏页也不能算检查过。
/// 这三句话都说出来,用户才知道该不该去重新下载这个包。
private struct IntegritySheet: View {

    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(L10n.tr("integrity.title"))
                .font(.system(size: DesignSystem.Typography.title, weight: .semibold))

            if let state = viewModel.integrity {
                switch state {
                case .running(let checked, let total):
                    running(checked: checked, total: total)
                case .finished(let report):
                    result(report)
                }
            }

            actions
        }
        .padding(DesignSystem.Spacing.lg)
        // 与密码面板同一套口径:居中面板 + 明确上下限,不让内容横贯整窗
        .frame(minWidth: 420, maxWidth: 620, alignment: .leading)
    }

    // MARK: 进行中

    private func running(checked: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // ProgressView 的 total 不能是 0(空文档到不了这里,但纯函数式的
            // 防御:除零在 SwiftUI 里不报错,只是画出一条诡异的进度条)
            ProgressView(value: Double(checked), total: Double(max(total, 1)))
                .frame(maxWidth: .infinity)
            Text(L10n.tr("integrity.running", checked, total))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)
            Text(L10n.tr("integrity.hint"))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 结论

    @ViewBuilder
    private func result(_ report: ArchiveIntegrityReport) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // 三个标题互斥且有序:没跑完的结论最弱,放最前 ——
            // 「有 3 页坏了」和「只查到一半」同时成立时,后者是更重要的信息
            if report.stoppedEarly {
                headline(icon: "pause.circle.fill", L10n.tr("integrity.stopped.title"))
                Text(L10n.tr("integrity.stopped.body",
                             min(report.lastCheckedPage + 1, report.pages), report.pages))
                    .font(.system(size: DesignSystem.Typography.body))
                    .fixedSize(horizontal: false, vertical: true)
            } else if report.damagedCount > 0 {
                headline(icon: "exclamationmark.triangle.fill",
                         L10n.tr("integrity.damaged.title", report.damagedCount))
            } else {
                headline(icon: "checkmark.seal.fill", L10n.tr("integrity.ok.title"))
                Text(L10n.tr("integrity.ok.body", report.pages))
                    .font(.system(size: DesignSystem.Typography.body))
                    .foregroundStyle(.secondary)
            }

            if report.damagedCount > 0 {
                Text(L10n.tr("integrity.damaged.body", damagedList(report)))
                    .font(.system(size: DesignSystem.Typography.body))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("integrity.damaged.summary",
                             max(report.pages - report.damagedCount, 0)))
                    .font(.system(size: DesignSystem.Typography.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if report.skippedEncrypted > 0 {
                Text(L10n.tr("integrity.skipped", report.skippedEncrypted))
                    .font(.system(size: DesignSystem.Typography.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headline(icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .accessibilityHidden(true)   // 装饰性图标不进 VoiceOver(AGENTS.md 十一.3)
            Text(text)
                .font(.system(size: DesignSystem.Typography.body, weight: .semibold))
        }
        .foregroundStyle(DesignSystem.Palette.brand)
    }

    /// 坏页清单 → 一句「第 12 页、第 57 页」。
    /// 超过报告上限时补一句「只列出前 N 个」—— 悄悄截断会让人以为只有这些
    private func damagedList(_ report: ArchiveIntegrityReport) -> String {
        let items = report.damagedPages.map { L10n.tr("integrity.pageItem", "\($0 + 1)") }
        var text = items.joined(separator: L10n.tr("integrity.pageSeparator"))
        if report.damagedCount > report.damagedPages.count {
            text += L10n.tr("integrity.damaged.truncated", ArchiveIntegrityReport.damagedPageLimit)
        }
        return text
    }

    // MARK: 按钮

    private var actions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            // 「停止」只在跑的时候有意义:停止后**面板不关**,让用户看到
            // 「查到第几页」—— 那正是「我到底查了多少」的答案
            if case .running = viewModel.integrity {
                Button(L10n.tr("integrity.stop")) { viewModel.cancelIntegrityCheck() }
            }
            Button(L10n.tr("integrity.done")) { viewModel.dismissIntegrity() }
                .keyboardShortcut(.cancelAction)      // Esc
        }
    }
}
