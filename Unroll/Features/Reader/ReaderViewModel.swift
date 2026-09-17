// AI-Generated | 可修改
// ReaderViewModel —— 页面状态机(设计文档 §4.1 / §4.3 图 3,M2 实现;M4 加面包屑打点)
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
//
// M4 面包屑打点(§5.10.3-①):本文件是「用户动作」的观测点 ——
//   打开 / 索引 / 翻页 / 布局切换。**只记动作与页索引,绝不记文件名**(§5.10.4);
//   失败也只记错误码,不记 archive_error_string() 原文(可能含路径)。
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
        /// 归档加密,等用户输入密码(v2,2026-09-17)。
        /// **刻意不叫 failed**:它不是终局错误,而是流程的一个中间态 ——
        /// 输对了就进阅读,取消就回空态。当成失败会让文案写成「打不开」,
        /// 而事实是「还没打开」(两者对用户的意义完全不同)
        case needsPassword
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

    /// 缩放档位(§2.1-4:适应窗口/适应宽/适应高/1:1)。
    /// 自由缩放(捏合/双击)是叠加在档位基准上的临时系数,归 Canvas 管;
    /// 档位属于阅读会话 —— 翻页不重置,只换书才回到默认。
    enum FitMode: String {
        case fitWindow      // 适应窗口(默认,整页完整可见)
        case fitWidth       // 适应宽(宽屏看漫画的高频档)
        case fitHeight      // 适应高
        case actualSize     // 1:1 实际大小

        /// 面包屑标签(过 sanitize 白名单)
        var token: String {
            switch self {
            case .fitWindow:  return "fit"
            case .fitWidth:   return "width"
            case .fitHeight:  return "height"
            case .actualSize: return "1to1"
            }
        }
    }

    // MARK: - Published

    @Published private(set) var phase: Phase = .noDocument
    @Published private(set) var presentation = PagePresentation()
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    /// HUD 显示用:仅文件名,绝不存完整路径(隐私红线同 §5.10.4)
    @Published private(set) var documentName: String?
    /// 当前文档 URL —— **只留在内存**,绝不持久化(续读/最近打开一律只落文件名,§5.7)。
    /// 用途只有两个:另存当前页的默认文件名、以及「在访达中显示」
    @Published private(set) var documentURL: URL?
    @Published var layout: PageLayout = .single {
        didSet {
            guard oldValue != layout, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.layoutChanged(layout.rawValue))
            realignSpread()
        }
    }
    /// 封面单独一页(2026-09-16)。双页配对口径见 `SpreadPaging`:
    /// 日式单行本的封面是独立一页,关掉它每翻一摊就错位一面。
    /// 默认关 = 与旧版本行为逐位一致(不改变既有用户的手感)
    @Published var coverAlone = false {
        didSet {
            guard oldValue != coverAlone, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.coverAloneChanged(coverAlone))
            realignSpread()
        }
    }
    @Published var direction: ReadingDirection = .leftToRight {
        didSet {
            guard oldValue != direction, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.directionChanged(direction == .leftToRight ? "ltr" : "rtl"))
            saveProgressNow()
            refreshSecondary()
        }
    }
    /// 缩放档位(§2.1-4):切换只影响渲染基准,与页面数据无关,不触发加载
    @Published var fitMode: FitMode = .fitWindow {
        didSet {
            guard oldValue != fitMode, !isRestoringProgress else { return }
            Breadcrumbs.shared.record(.fitModeChanged(fitMode.token))
            saveProgressNow()
        }
    }

    /// 双页模式下的次页下标(越界尾页 / 封面单独那一摊 → nil,View 退化为单页)。
    /// 配对口径全在 `SpreadPaging`(纯函数,独立单测)—— 本处只做转发
    var secondaryIndex: Int? {
        SpreadPaging.secondaryIndex(for: pageIndex, pageCount: pageCount,
                                   dual: layout == .dual, coverAlone: coverAlone)
    }

    // MARK: - 私有

    private var store: PageStore?
    private var openTask: Task<Void, Never>?
    /// 部分加密包的加密页数(单页失败卡片的「其余 %d 页可读」用)
    private var encryptedPageCount = 0

    // MARK: - 解压密码(v2,2026-09-17)

    /// 上一次密码尝试的失败提示(nil = 没失败过 / 已成功)。
    /// 全屏密码视图与阅读中的解锁面板共用 —— 它们本就是同一件事的两个入口
    @Published private(set) var passwordFailure: Failure?

    /// 阅读中解锁面板的显隐(部分加密包用;菜单命令置位,View 渲染 sheet)
    @Published var isUnlockSheetPresented = false

    /// 当前阅读的包里还有未解锁的加密页 → 「输入解压密码…」菜单可用。
    /// 全加密包在 open 阶段就进了 needsPassword,走不到这里
    var hasLockedPages: Bool {
        phase == .reading && encryptedPageCount > 0
    }

    /// 等待密码的归档 URL。**只在内存里** —— 与密码本身同一条规则:不落盘、
    /// 不进面包屑、不进崩溃报告。输入成功后立刻用它带密码重开
    private var pendingPasswordURL: URL?

    // MARK: - 续读记忆 / 书签(2026-09-15)

    private let progressStore: ReadingProgress
    private let bookmarkStore: Bookmarks
    /// 当前文档的身份键(打开成功后才有;nil = 未在阅读,不落进度/书签)
    private var documentKey: String?
    /// 恢复期间不回写进度(否则切档位的 didSet 会用页 0 覆盖掉已存的进度)
    private var isRestoringProgress = false

    /// 本书已标记的页(升序);换书时随文档刷新
    @Published private(set) var bookmarkedPages: [Int] = []
    /// 页码跳转面板显隐(菜单命令置位,View 渲染 sheet —— 命令不持有 View 状态)
    @Published var isJumpSheetPresented = false

    /// 存储可注入(单测用隔离 suite)
    init(progressStore: ReadingProgress = ReadingProgress(),
         bookmarkStore: Bookmarks = Bookmarks()) {
        self.progressStore = progressStore
        self.bookmarkStore = bookmarkStore
    }

    /// 清空全部续读进度与书签(「清空最近打开」连带调用,不留无主数据)
    func clearProgress() {
        progressStore.clear()
        bookmarkStore.clear()
        bookmarkedPages = []
    }

    // MARK: - 打开(图 3 主时序)

    /// 打开归档。重复调用 = 换书:旧 store 先 teardown,新任务不受旧任务干扰。
    ///
    /// passphrase(v2,2026-09-17):解压密码。nil = 未提供 —— 加密包不会被当成
    /// 失败,而是落到 `.needsPassword`,由 UI 提示输入后再带密码调一次本方法。
    /// 密码只以参数形式经过这里,不落任何存储。
    ///
    /// 返回本次打开任务(UI 忽略返回值;测试可 await 等待状态机落定)
    @discardableResult
    func open(url: URL, passphrase: String? = nil) -> Task<Void, Never> {
        openTask?.cancel()
        let oldStore = store
        store = nil
        if let oldStore {
            Task { await oldStore.teardown() }
        }

        pageCount = 0
        pageIndex = 0
        encryptedPageCount = 0
        documentKey = nil          // 旧文档的进度键立即失效,换书后不得误写
        bookmarkedPages = []
        presentation = PagePresentation()
        secondary = nil
        documentName = url.lastPathComponent
        // 失败也保留:打开失败时「在访达里显示」恰恰最有用(去看一眼这文件到底是什么)
        documentURL = url
        // 上一轮的密码提示不跨书:换一个包就该干干净净地重新问
        passwordFailure = nil
        let task = Task { await performOpen(url: url, passphrase: passphrase) }
        openTask = task
        return task
    }

    private func performOpen(url: URL, passphrase: String?) async {
        phase = .opening
        do {
            // 加密四态预检 + 建索引全在 open 里(§5.9 图 10);终局态在此抛错。
            // 带密码打开时 ArchiveKit 已就地验证过密码(读得动才算对,见
            // ArchiveDocument.verifyPassphrase),所以走到这里就说明密码可用 ——
            // VM 不必也不该自己再验一次(那会多读一遍加密数据)
            let document = try ArchiveDocument.open(url: url, passphrase: passphrase)
            try Task.checkCancellation()

            let store = PageStore(document: document)
            self.store = store
            pageCount = document.entries.count
            if case .partial(let count) = document.protection {
                encryptedPageCount = count
            }
            // 打开成功 → 清掉密码流程的临时状态。密码本身住在 document 里
            // (读每一页都要用),VM 不留副本
            if passphrase != nil {
                // 只有真带密码打开过才记 —— 明文包不该产生这条事件
                Breadcrumbs.shared.record(.passphraseAttempt(success: true))
            }
            pendingPasswordURL = nil
            passwordFailure = nil
            isUnlockSheetPresented = false
            phase = .reading

            // 续读键:文件名 + 文件大小(stat 放后台,不占主线程,AGENTS.md 十二.1)
            let bytes = await fileSize(of: url)
            documentKey = ReadingProgress.key(name: url.lastPathComponent, size: bytes)

            // 面包屑:格式 + 大小桶(不含文件名)/ 页数 / 加密页数(§5.10.4 允许字段)
            Breadcrumbs.shared.record(.openArchive(format: Self.formatToken(document.format),
                                                   sizeBucket: Breadcrumbs.sizeBucket(bytes: bytes)))
            Breadcrumbs.shared.record(.indexBuilt(pages: document.entries.count))
            if encryptedPageCount > 0 {
                Breadcrumbs.shared.record(.encryptedPages(count: encryptedPageCount))
            }

            // 续读恢复:有记录 → 套用阅读模式 + 跳到上次页码;无记录 → 从封面开始
            var startPage = 0
            if let key = documentKey {
                bookmarkedPages = bookmarkStore.pages(forKey: key)
            }
            if let key = documentKey, let saved = progressStore.entry(forKey: key),
               document.entries.indices.contains(saved.page), saved.page > 0 {
                isRestoringProgress = true
                if let l = PageLayout(rawValue: saved.layout) { layout = l }
                if let d = ReadingDirection(rawValue: saved.direction) { direction = d }
                if let f = FitMode(rawValue: saved.fitMode) { fitMode = f }
                coverAlone = saved.coverAlone ?? false   // 老记录无此字段 → 关(旧行为)
                isRestoringProgress = false
                // 归一:存的是「当时在上屏的那一页」,双页下要落回所属摊的首面,
                // 否则会恢复出「主图是摊第二面」的错位摊(配对口径变过时尤其明显)
                startPage = layout == .dual
                    ? SpreadPaging.spreadStart(for: saved.page, coverAlone: coverAlone)
                    : saved.page
                pageIndex = startPage    // 状态机页码同步(翻页语义全走 goTo,这里是对齐)
                Breadcrumbs.shared.record(.progressRestored(page: startPage))
            }

            await loadPage(startPage)
            await store.anchorDidChange(to: startPage)
        } catch is CancellationError {
            // 被更新的 open 抢占:不做任何状态写入,别覆盖新任务的结果
        } catch let error as ArchiveError {
            switch error {
            case .encrypted, .wrongPassphrase:
                // 需要密码 / 密码不对 —— 两者都是**流程中间态,不是失败**。
                // 刻意不记 openFailed:把它记成「打开失败」会让崩溃报告里出现
                // 一堆并不存在的故障。面包屑只记「要密码了」/「试错了一次」,
                // **密码本身绝不记录**(白名单也只放行 on/off 这种布尔标签)
                pendingPasswordURL = url
                if error == .wrongPassphrase {
                    Breadcrumbs.shared.record(.passphraseAttempt(success: false))
                    passwordFailure = Self.passwordFailure(for: error)
                } else {
                    Breadcrumbs.shared.record(.passphraseRequired)
                }
                phase = .needsPassword
            default:
                pendingPasswordURL = nil
                Breadcrumbs.shared.record(.openFailed(code: Self.failureCode(error)))
                phase = .failed(openFailure(for: error, url: url))
            }
        } catch {
            pendingPasswordURL = nil
            Breadcrumbs.shared.record(.openFailed(code: "unknown"))
            phase = .failed(openFailure(for: .corrupted, url: url))
        }
    }

    // MARK: - 解压密码的输入与取消(v2,2026-09-17)

    /// 打开阶段的密码提交(全屏密码视图)。
    ///
    /// 刻意**不做 trim**:密码首尾的空格可能是有意义的字符,
    /// 替用户"顺手修正"输入是密码框最经典的 bug。空串直接忽略(UI 也会禁用按钮)
    func submitPassword(_ password: String) {
        guard !password.isEmpty, let url = pendingPasswordURL else { return }
        open(url: url, passphrase: password)
    }

    /// 阅读中解锁(部分加密包)的密码提交。与打开阶段**分开走两条路**,
    /// 原因见 `unlockWithPassword` 的说明
    func submitUnlockPassword(_ password: String) {
        guard !password.isEmpty else { return }
        Task { await unlockWithPassword(password) }
    }

    /// 放弃输入密码。两个入口的"放弃"含义不同:
    /// 打开阶段 → 回空态(就当没开过);阅读中 → 只关面板,阅读不动
    func cancelPasswordPrompt() {
        passwordFailure = nil
        if isUnlockSheetPresented {
            isUnlockSheetPresented = false
            return
        }
        pendingPasswordURL = nil
        // 不留「半打开」状态:清掉 documentURL,免得「在访达中显示」
        // 指向一个从未真正打开的归档(菜单可用但点了没意义,是很隐蔽的假状态)
        documentURL = nil
        documentName = nil
        phase = .noDocument
    }

    /// 阅读中触发解锁(部分加密包):菜单命令只置位,面板归 View 渲染
    func beginUnlock() {
        guard hasLockedPages else { return }
        passwordFailure = nil
        isUnlockSheetPresented = true
    }

    /// 阅读中解锁部分加密包。
    ///
    /// **刻意不走 `open()`** —— 那条路是"换书"语义:一上来就 teardown 旧 store、
    /// 清空页码与布局,于是密码打错一次就白屏一次,阅读上下文全丢。
    /// 这里反过来:**先带密码试开,成功了才替换 store**;失败则原地不动,
    /// 只在面板里说一句。页码 / 单双页 / 方向 / 缩放档位都没经过本次操作,自然保留。
    ///
    /// 解开之后 `encryptedPageCount` 归 0:不再有"读不出的页",
    /// 占位卡片与「其余 N 页可读」的文案随之消失
    private func unlockWithPassword(_ password: String) async {
        guard let url = documentURL else { return }
        do {
            let document = try ArchiveDocument.open(url: url, passphrase: password)

            // 走到这里说明密码已确认可用(ArchiveKit 在 open 里就地验证过),
            // 下面这段是本次操作**唯一**会改动现状的地方
            let newStore = PageStore(document: document)
            let oldStore = store
            store = newStore
            pageCount = document.entries.count
            encryptedPageCount = 0
            Breadcrumbs.shared.record(.passphraseAttempt(success: true))
            await oldStore?.teardown()

            // 当前页用新 store 重取:之前那张是加密失败卡,现在该换成真图
            presentation.failure = nil
            presentation.isLoading = true
            secondary = nil
            isUnlockSheetPresented = false
            passwordFailure = nil
            await loadPage(pageIndex)
            await newStore.anchorDidChange(to: pageIndex)
        } catch let error as ArchiveError {
            Breadcrumbs.shared.record(.passphraseAttempt(success: false))
            passwordFailure = Self.passwordFailure(for: error)
        } catch {
            Breadcrumbs.shared.record(.passphraseAttempt(success: false))
            passwordFailure = Self.passwordFailure(for: .wrongPassphrase)
        }
    }

    /// 密码不通过时给用户看的那一句(全屏视图与解锁面板共用)。
    /// 文案 key 归 VM 产出、渲染归 View —— 与其余 Failure 同一套约定
    private static func passwordFailure(for error: ArchiveError) -> Failure {
        switch error {
        case .encryptedUnsupportedFormat, .headerEncrypted:
            // 库层面解不开:如实说明,别让用户继续对着密码框试
            return Failure(titleKey: "archive.password.unsupported.title",
                           bodyKey: "archive.password.unsupported.body", bodyArg: nil)
        default:
            return Failure(titleKey: "archive.password.wrong.title",
                           bodyKey: "archive.password.wrong.body", bodyArg: nil)
        }
    }

    // MARK: - 翻页(图 5 主链入口)

    /// 跳到指定页(越界自动夹紧;失败页重试:同页 + 已有失败卡也放行)。
    /// 双页模式下目标页会**归一到它所属那一摊的首面** —— 见 `SpreadPaging.spreadStart`
    func goTo(_ index: Int) {
        guard phase == .reading, store != nil, pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        let target = layout == .dual
            ? SpreadPaging.spreadStart(for: clamped, coverAlone: coverAlone)
            : clamped
        guard target != pageIndex || presentation.failure != nil else { return }

        pageIndex = target
        saveProgressNow()
        presentation.failure = nil
        presentation.isLoading = true
        secondary = nil   // 旧次页已失效,留白待新次页(不垫旧图,视觉上是「下一摊」)
        Task { await loadPage(target) }
    }

    func nextPage() {
        goTo(SpreadPaging.next(from: pageIndex, pageCount: pageCount,
                               dual: layout == .dual, coverAlone: coverAlone))
    }

    func previousPage() {
        goTo(SpreadPaging.previous(from: pageIndex, pageCount: pageCount,
                                   dual: layout == .dual, coverAlone: coverAlone))
    }

    /// 配对口径变化(布局 / 封面单独)后,把当前页归一到所属摊并刷新两面。
    /// 不是摊首面时主图本身要换(否则会出现「主图是摊的第二面」的错位),
    /// 是摊首面时只补次页(主图不动、无闪烁)
    private func realignSpread() {
        guard phase == .reading, pageCount > 0 else { return }
        let target = layout == .dual
            ? SpreadPaging.spreadStart(for: pageIndex, coverAlone: coverAlone)
            : pageIndex
        if target != pageIndex {
            pageIndex = target
            presentation.failure = nil
            presentation.isLoading = true
            secondary = nil
            Task { await loadPage(target) }
        } else {
            refreshSecondary()
        }
        saveProgressNow()
    }

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
            Breadcrumbs.shared.record(.pageDecode(index: index))
            await store.anchorDidChange(to: index)
            if let sec = secondaryIndex {
                await loadSecondary(sec)
            }
        } catch let error as ArchiveError {
            guard index == pageIndex, phase == .reading else { return }
            presentation.isLoading = false
            presentation.failure = pageFailure(for: error)
            Breadcrumbs.shared.record(.pageFailed(index: index))
        } catch {
            // 解码层只抛 ArchiveError,这里是防御性兜底(例如取消)
            guard index == pageIndex, phase == .reading else { return }
            presentation.isLoading = false
            presentation.failure = pageFailure(for: .corrupted)
            Breadcrumbs.shared.record(.pageFailed(index: index))
        }
    }

    // MARK: - 面包屑辅助(§5.10.4:只产「短标签」,绝不产路径 / 文件名)

    /// libarchive 判定的格式 → 短标签(sanitize 白名单内)
    private static func formatToken(_ format: ArchiveFormat) -> String {
        switch format {
        case .zip:      return "zip"
        case .sevenZip: return "7z"
        case .rar:      return "rar"
        case .tar:      return "tar"
        case .other:    return "other"
        }
    }

    /// 归档错误 → 短码。**刻意不记 `archive_error_string()` 原文**
    /// (§5.9.4 约束 6:那串英文可能含完整路径 —— 比设计文档 §5.9 的措辞更严一档)
    private static func failureCode(_ error: ArchiveError) -> String {
        switch error {
        case .corrupted:                return "corrupted"
        case .empty:                    return "empty"
        case .noImages:                 return "noImages"
        case .headerEncrypted:          return "headerEncrypted"
        case .encrypted:                return "encrypted"
        case .wrongPassphrase:          return "wrongPassphrase"
        case .encryptedUnsupportedFormat: return "encryptedUnsupported"
        case .unknown:                  return "unknown"
        }
    }

    /// 文件大小(字节)。stat 放后台,不占主线程(AGENTS.md 十二.1);
    /// 续读键与面包屑大小桶共用这一次 stat
    private func fileSize(of url: URL) async -> Int {
        await Task.detached(priority: .utility) {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        }.value
    }

    /// 回写续读进度(仅在阅读态且有进度键时;失败静默 —— 续读绝不致命)
    private func saveProgressNow() {
        guard phase == .reading, let key = documentKey, !isRestoringProgress else { return }
        progressStore.save(key: key,
                           page: pageIndex,
                           total: pageCount,
                           layout: layout.rawValue,
                           direction: direction.rawValue,
                           fitMode: fitMode.rawValue,
                           coverAlone: coverAlone)
    }

    // MARK: - 书签(2026-09-15)

    /// 当前页是否已标记
    var isCurrentPageBookmarked: Bool {
        bookmarkedPages.contains(pageIndex)
    }

    /// 标记 / 取消标记当前页
    func toggleBookmark() {
        guard phase == .reading, let key = documentKey else { return }
        let marked = bookmarkStore.toggle(page: pageIndex, key: key)
        bookmarkedPages = bookmarkStore.pages(forKey: key)
        Breadcrumbs.shared.record(.bookmarkToggled(page: pageIndex, marked: marked))
    }

    /// 跳到下一个书签(无更后面的书签 → 回到第一个;没有书签 → 不动)
    func goToNextBookmark() {
        guard phase == .reading, !bookmarkedPages.isEmpty else { return }
        let next = bookmarkedPages.first { $0 > pageIndex } ?? bookmarkedPages[0]
        goTo(next)
    }

    /// 跳到上一个书签(无更前面的书签 → 绕到最后一个)
    func goToPreviousBookmark() {
        guard phase == .reading, !bookmarkedPages.isEmpty else { return }
        let previous = bookmarkedPages.last { $0 < pageIndex } ?? bookmarkedPages[bookmarkedPages.count - 1]
        goTo(previous)
    }

    /// 清空本书全部书签
    func clearBookmarks() {
        guard let key = documentKey else { return }
        bookmarkStore.clearDocument(key: key)
        bookmarkedPages = []
    }

    // MARK: - 导出 / 窗口标题(v2,2026-09-16)

    /// 窗口标题:`文件名 · P.3/200`。多窗口与 Dock 悬停时能分辨「哪本、读到哪」
    /// (窗口标题由 App 层写进 NSWindow,VM 只产出文本)
    var windowTitle: String {
        guard phase == .reading, let documentName else { return L10n.tr("app.name") }
        return L10n.tr("reader.window.title", documentName, pageIndex + 1, pageCount)
    }

    /// 当前摊的上屏图用于导出(双页合成一张,并排顺序跟随阅读方向,见 `PageExport`)。
    /// 非阅读态 / 上屏图还没就绪 → nil(调用方据此禁用菜单项,不留"点了没反应")
    func exportImage() -> CGImage? {
        guard phase == .reading, let primary = presentation.image else { return nil }
        return PageExport.compose(primary: primary,
                                  secondary: layout == .dual ? secondary : nil,
                                  rightToLeft: direction == .rightToLeft)
    }

    /// 导出建议文件名(与当前显示一致;只含文件名,不含路径)
    func exportFileName(format: PageExport.Format) -> String {
        PageExport.suggestedFileName(documentName: documentName, page: pageIndex,
                                     pageCount: pageCount, format: format)
    }

    // MARK: - 页码跳转(⌥⌘G)

    /// 解析用户输入 → 页码下标(1-based 输入,返回 0-based)。
    /// 容忍空格与全角数字;非法/越界 → nil(调用方不跳转,不留副作用)
    static func parsePageInput(_ text: String, pageCount: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pageCount > 0 else { return nil }
        // 全角数字 → 半角(中文输入法下很常见)
        let normalized = trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed
        guard let number = Int(normalized), number >= 1, number <= pageCount else { return nil }
        return number - 1
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
        case .wrongPassphrase:
            // 正常流程到不了这里:`.encrypted` / `.wrongPassphrase` 在 performOpen
            // 里已被分流到 .needsPassword(它们不是失败)。留这条只为 switch 穷尽,
            // 万一将来有人改了分流,也不会掉进"无文案可显示"的空洞
            return Self.passwordFailure(for: .wrongPassphrase)
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
        case .encrypted, .encryptedUnsupportedFormat, .wrongPassphrase:
            // wrongPassphrase 与 encrypted 同路:都是「这一页没解开」。
            // 密码不对在 open 阶段就被拦下了,走到这里只可能是
            // 「部分加密包没输密码」(占位卡片的常规场景)
            let readable = max(pageCount - encryptedPageCount, 0)
            return Failure(titleKey: "archive.page.encrypted.title",
                           bodyKey: "archive.page.encrypted.subtitle", bodyArg: readable)
        case .corrupted, .unknown, .headerEncrypted, .empty, .noImages:
            return Failure(titleKey: "archive.page.failed.title",
                           bodyKey: "archive.page.failed.body", bodyArg: nil)
        }
    }
}
