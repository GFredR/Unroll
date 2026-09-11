// AI-Generated | 可修改
// ReaderViewModel —— 页面状态机(设计文档 §4.1 / §4.3 图 3,M2 实现)
// ----------------------------------------------------------------------------
// 规范(AGENTS.md 三):@MainActor + ObservableObject,View 通过 @StateObject 监听;
// 状态驱动 UI 切换,View 不含业务逻辑。
//
// 状态设计(两层,职责不同):
//   · phase    —— 归档级:无文档 → 打开中 → 阅读 / 失败(终局,§5.9.3 图 10 分流);
//   · presentation —— 页级:上屏图 + 加载中 + 单页失败。
//     加载新页时**保留旧图**(isLoading 置位即可),避免每次翻页白屏闪烁;
//     单页失败只换当前页的失败卡片,归档保持打开(§5.9.4 约束 4:
//     「单页失败 ≠ 整档失败」—— 部分加密归档能工作的前提)。
//
// 错误文案:VM 只产出 key + 参数(§5.9.3.1 的分组),渲染归 View(L10n.tr)。
// archive_error_string() 原文永不进 UI(§5.9.4 约束 6,可能含完整路径)。
import ArchiveKit
import CoreGraphics
import Foundation

@MainActor
final class ReaderViewModel: ObservableObject {

    // MARK: - 归档级状态

    /// 归档阶段(终局失败对应 §5.9.3.1 各错误组)
    enum Phase: Equatable {
        case noDocument            // 空态:等待拖入 / 双击
        case opening
        case reading
        case failed(Failure)
    }

    /// 归档级失败。key + 本地化参数,渲染在 View 完成
    struct Failure: Equatable {
        let titleKey: String
        let bodyKey: String?
        let bodyArg: Int?
    }

    // MARK: - 页级状态

    /// 上屏页的次页(双页模式;nil = 单页 / 越界尾页)。独立于 PagePresentation:
    /// 主图的「保留旧图防闪烁」语义不适用于次页(翻摊时次页直接换新)
    @Published var secondary: CGImage?

    /// 当前页的上屏呈现:旧图垫底防闪烁 + 加载态 + 单页失败卡片
    struct PagePresentation: Equatable {
        var image: CGImage?        // 当前上屏图(新页就绪前是旧图或缩略图)
        var isLoading = false
        var failure: Failure?
    }

    // MARK: - 阅读模式(M3)

    /// 单页 / 双页(§0 决策 3:双页可关)
    enum PageLayout: String {
        case single
        case dual
    }

    /// 阅读方向:左开 / 日漫右开(右→左)
    enum ReadingDirection: String {
        case leftToRight
        case rightToLeft
    }

    // MARK: - Published

    @Published private(set) var phase: Phase = .noDocument
    @Published private(set) var presentation = PagePresentation()
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    /// HUD 显示用:仅文件名,绝不存完整路径(隐私红线同 §5.10.4)
    @Published private(set) var documentName: String?
    @Published var layout: PageLayout = .single {
        didSet { guard oldValue != layout else { return } ; refreshSecondary() }
    }
    @Published var direction: ReadingDirection = .leftToRight {
        didSet { guard oldValue != direction else { return } ; refreshSecondary() }
    }

    /// 双页模式下的次页下标(越界尾页 → nil,View 退化为单页)
    var secondaryIndex: Int? {
        guard layout == .dual else { return nil }
        let next = pageIndex + 1
        return next < pageCount ? next : nil
    }

    /// 翻页步长:双页一次跨两页
    private var pageStep: Int { layout == .dual ? 2 : 1 }

    // MARK: - 私有

    private var store: PageStore?
    private var openTask: Task<Void, Never>?
    /// 部分加密包的加密页数(单页失败卡片的「其余 %d 页可读」用)
    private var encryptedPageCount = 0

    // MARK: - 打开(图 3 主时序)

    /// 打开归档。重复调用 = 换书:旧 store 先 teardown,新任务不受旧任务干扰。
    /// 返回本次打开任务(UI 忽略返回值;测试可 await 等待状态机落定)
    @discardableResult
    func open(url: URL) -> Task<Void, Never> {
        openTask?.cancel()
        let oldStore = store
        store = nil
        if let oldStore {
            Task { await oldStore.teardown() }
        }

        pageCount = 0
        pageIndex = 0
        encryptedPageCount = 0
        presentation = PagePresentation()
        secondary = nil
        documentName = url.lastPathComponent
        let task = Task { await performOpen(url: url) }
        openTask = task
        return task
    }

    private func performOpen(url: URL) async {
        phase = .opening
        do {
            // 加密四态预检 + 建索引全在 open 里(§5.9 图 10);终局态在此抛错
            let document = try ArchiveDocument.open(url: url)
            try Task.checkCancellation()

            let store = PageStore(document: document)
            self.store = store
            pageCount = document.entries.count
            if case .partial(let count) = document.protection {
                encryptedPageCount = count
            }
            phase = .reading

            await loadPage(0)
            await store.anchorDidChange(to: 0)
        } catch is CancellationError {
            // 被更新的 open 抢占:不做任何状态写入,别覆盖新任务的结果
        } catch let error as ArchiveError {
            phase = .failed(openFailure(for: error, url: url))
        } catch {
            phase = .failed(openFailure(for: .corrupted, url: url))
        }
    }

    // MARK: - 翻页(图 5 主链入口)

    /// 跳到指定页(越界自动夹紧;失败页重试:同页 + 已有失败卡也放行)
    func goTo(_ index: Int) {
        guard phase == .reading, store != nil, pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        guard clamped != pageIndex || presentation.failure != nil else { return }

        pageIndex = clamped
        presentation.failure = nil
        presentation.isLoading = true
        secondary = nil   // 旧次页已失效,留白待新次页(不垫旧图,视觉上是「下一摊」)
        Task { await loadPage(clamped) }
    }

    func nextPage() { goTo(pageIndex + pageStep) }
    func previousPage() { goTo(pageIndex - pageStep) }

    /// 布局/方向切换后,次页图立刻跟上(主图不动,无闪烁)
    private func refreshSecondary() {
        guard phase == .reading else { return }
        if let idx = secondaryIndex {
            Task { await loadSecondary(idx) }
        } else {
            secondary = nil
        }
    }

    /// 次页加载(仅双页;失败静默 —— 次页失败不换主图,与「单页失败 ≠ 整档失败」一致)
    private func loadSecondary(_ index: Int) async {
        guard let store, index == secondaryIndex else { return }
        secondary = try? await store.image(at: index)
    }

    private func loadPage(_ index: Int) async {
        guard let store else { return }

        // 无旧图时先垫缩略图(图 5 PLACE 分支:Trimmed 态翻回来不白屏)
        if presentation.image == nil,
           let thumb = await store.cachedThumbnail(at: index) {
            presentation.image = thumb
        }

        do {
            let image = try await store.image(at: index)
            // 竞态守卫:快速连翻时,迟到的旧页结果不得覆盖新页
            guard index == pageIndex, phase == .reading else { return }
            presentation.image = image
            presentation.isLoading = false
            presentation.failure = nil
            await store.anchorDidChange(to: index)
            if let sec = secondaryIndex {
                await loadSecondary(sec)
            }
        } catch let error as ArchiveError {
            guard index == pageIndex, phase == .reading else { return }
            presentation.isLoading = false
            presentation.failure = pageFailure(for: error)
        } catch {
            // 解码层只抛 ArchiveError,这里是防御性兜底(例如取消)
            guard index == pageIndex, phase == .reading else { return }
            presentation.isLoading = false
            presentation.failure = pageFailure(for: .corrupted)
        }
    }

    // MARK: - 错误 → 文案 key(§5.9.3.1 分流)

    /// 归档级失败分流。7z 与 RAR 共用 encryptedUnsupportedFormat 但文案措辞
    /// 必须区分(§5.9.1:7z 实测不支持,RAR 是推断)—— open 失败拿不到 libarchive
    /// 的 format 判定,按扩展名分流(用户视角等价)
    private func openFailure(for error: ArchiveError, url: URL) -> Failure {
        switch error {
        case .corrupted, .unknown:
            return Failure(titleKey: "archive.corrupted.title",
                           bodyKey: "archive.corrupted.body", bodyArg: nil)
        case .empty:
            // §5.9.3.1 未定义「0 条目」组,M2 补最小文案,M3 一并润色
            return Failure(titleKey: "archive.empty.title",
                           bodyKey: "archive.empty.body", bodyArg: nil)
        case .noImages(let found):
            return Failure(titleKey: "archive.noImages.title",
                           bodyKey: "archive.noImages.body", bodyArg: found)
        case .headerEncrypted:
            return Failure(titleKey: "archive.encrypted.header.title",
                           bodyKey: "archive.encrypted.header.body", bodyArg: nil)
        case .encrypted:
            return Failure(titleKey: "archive.encrypted.title",
                           bodyKey: "archive.encrypted.zip.body", bodyArg: nil)
        case .encryptedUnsupportedFormat:
            let isRar = ["cbr", "rar"].contains(url.pathExtension.lowercased())
            return Failure(titleKey: isRar ? "archive.encrypted.rar.title" : "archive.encrypted.7z.title",
                           bodyKey: isRar ? "archive.encrypted.rar.body" : "archive.encrypted.7z.body",
                           bodyArg: nil)
        }
    }

    /// 页级失败分流(部分加密包里的加密页 → 占位卡片;其余 → 单页读取失败)
    private func pageFailure(for error: ArchiveError) -> Failure {
        switch error {
        case .encrypted, .encryptedUnsupportedFormat:
            let readable = max(pageCount - encryptedPageCount, 0)
            return Failure(titleKey: "archive.page.encrypted.title",
                           bodyKey: "archive.page.encrypted.subtitle", bodyArg: readable)
        case .corrupted, .unknown, .headerEncrypted, .empty, .noImages:
            return Failure(titleKey: "archive.page.failed.title",
                           bodyKey: "archive.page.failed.body", bodyArg: nil)
        }
    }
}
