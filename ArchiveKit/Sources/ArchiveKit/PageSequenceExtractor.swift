// AI-Generated | 可修改
// PageSequenceExtractor —— 按阅读顺序把每一页的**原始字节**依次交出来(2026-09-21)
// ----------------------------------------------------------------------------
// 定位:与 `ArchiveIntegrityChecker` 同一层、同一形状 —— 入参文档,出参报告,
// **自己不写任何文件**。「交出来的字节拿去干什么」由调用方的 `onPage` 决定:
//   · App 层拿它写盘(批量导出);
//   · 单测拿它收集成数组做逐字节断言(于是本模块可以在无沙盒的 `swift test` 下
//     用真实 fixture 测出完整行为,不需要碰文件系统)。
//
// 为什么这件事只有阅读器做得了(设计文档 §2.2 原话已按实测改写):
// 实测(macOS 15.7.4)Archive Utility 声明的输入类型只有 `public.zip-archive` 一族,
// **没有 rar、没有 7z**;系统 `tar`(bsdtar/libarchive)对实体 RAR 直接拒
// (`RAR solid archive support unavailable`),本机也不存在 `unrar` —— 也就是说
// 本 App 支持的三种格式里,系统能兜底的只有 zip 一种。而这一种也不顶用:
// 朴素解压给出的是**归档顺序**(实测 `page10 / page2 / page1`)并夹带
// `__MACOSX` / `note.txt` / `.DS_Store`。「哪些条目算页」与「页与页的先后」
// 只有我们知道 —— 自然排序(P0-8)+ 过滤规则(§6.2)本来就是既有能力。
//
// 骨架照抄 `ArchiveIntegrityChecker`,三处不能省:
//   · 独立的 `SequentialPageReader`(**必须** —— 每页 open 一次对 solid 7z 是 O(n²),
//     §5.1 实测 71×);
//   · 每页问一次取消;
//   · 坏页后**受控重开** —— 数据读失败后流的位置不可信,继续前向走只会一路失败,
//     报告会变成「除前几页外全坏」这种假结论;重开是 O(已读页数),故设上限。
// 并且与它一样**不抛错**:「有几页没交出来」与「整件事没跑起来」是两回事,
// 混成一个 throw 会让界面只剩一句什么也没说清的「失败了」。
import CArchiveShim
import Foundation

// MARK: - 停止原因

/// 停下来的原因。**四态而不是一个 Bool** —— 四个原因对用户的意义完全不同,
/// 合成一句话必然要说谎:
///   · `finished`     —— 全卷都交出来了,结论完整;
///   · `cancelled`    —— 调用方叫停(用户按了停止 / 关了面板),**不是失败**;
///   · `sinkStopped`  —— `onPage` 返回 false 说"别再给我了"。App 层用它表达
///                       写盘失败(磁盘满 / 没权限)。**此时必须立即收工**:
///                       接着读只会一路失败,最后报出「200 页全失败」的假结论,
///                       把真实原因(没空间了)埋在页码列表里;
///   · `stalled`      —— 包坏得连遍历都走不下去(重开次数用尽)。此时
///                       「还有多少页没处理」是**未知**的,不能说成「就这些」
public enum PageSequenceStop: Equatable, Sendable {
    case finished
    case cancelled
    case sinkStopped
    case stalled

    /// 面包屑标签(过 sanitize 白名单,与 `PageGridStop.token` 同一性质)
    public var token: String {
        switch self {
        case .finished:    return "full"
        case .cancelled:   return "cancelled"
        case .sinkStopped: return "sinkStopped"
        case .stalled:     return "stalled"
        }
    }
}

// MARK: - 报告

/// 处理报告。全是值语义,可跨隔离域传递、可直接断言
public struct PageSequenceReport: Sendable, Equatable {

    /// 归档总页数
    public let pages: Int
    /// 成功交出的页数(调用方 `onPage` 返回 true 的次数)
    public let delivered: Int
    /// 因加密而**跳过**的页数。**不是损坏** —— 没给密码时读不出是预期行为,
    /// 与 `ArchiveIntegrityReport.skippedEncrypted` 同一判据(不要各写一份)
    public let skippedEncrypted: Int
    /// 读不出来的页(0 起,升序)。为控制报告体积最多保留 `failedPageLimit` 项,
    /// 真实总数看 `failedCount`
    public let failedPages: [Int]
    /// 坏页真实总数(可能大于 `failedPages.count`)
    public let failedCount: Int
    public let stop: PageSequenceStop
    /// 停止时处理到的页(0 起)
    public let lastScannedPage: Int

    /// 报告里最多列出几个坏页
    public static let failedPageLimit = 20

    /// 交出数 + 跳过数 + 失败数是否已覆盖全档 —— 后三种停止原因下为 false。
    /// **它是「有没有漏页」的机器判据**,文案不该自己算
    /// (算错的方向恰好是「把没弄完的说成弄完了」)
    public var coversWholeArchive: Bool {
        delivered + skippedEncrypted + failedCount == pages
    }

    /// 还没处理的页数(`coversWholeArchive` 为 false 时才是真实信息)
    public var remaining: Int {
        max(0, pages - delivered - skippedEncrypted - failedCount)
    }
}

// MARK: - 提取器

public enum PageSequenceExtractor {

    /// 坏页后允许重开扫描器的次数上限。默认 32:足以扛住「散布几十个坏条目」的包,
    /// 又不至于让极端坏的包把单趟 O(n) 退化成 O(n²)(与 `ArchiveIntegrityChecker` 同值同理由)
    public static let defaultMaxReopens = 32

    /// 进度回调的节流步长。逐页回调在 500 页的包上等于凭空造 500 个任务
    public static let defaultProgressStride = 8

    /// 顺序交出全卷的每一页(前向 O(1)/页)。
    ///
    /// - Parameters:
    ///   - document: 已打开的文档。**加密包请用解锁后的文档** —— 用未解锁的,
    ///     加密页会计入 `skippedEncrypted`(那不是失败,是「没给密码」)
    ///   - maxReopens: 坏页后允许重开扫描器的次数上限,超了即 `stop == .stalled`
    ///   - progressStride: 每处理这么多页回调一次进度
    ///   - isCancelled: 每页问一次。true → 立即收工,报告带 `.cancelled`
    ///   - onProgress: 每处理完 `progressStride` 页回调一次(已处理页数)
    ///   - onPage: 每页交付回调 `(页下标, 原始字节)`。返回 **false = 别再给我了**
    ///     (立即收工,报告带 `.sinkStopped`)。注意字节是**归档里的原始内容**,
    ///     未解码、未重编码、未合成 —— 这正是与「另存当前页」的根本区别。
    ///     **必填**且排在最后一个参数:
    ///     ① 语义上它就是本函数的目的 —— 没有消费方的提取器没有任何意义;
    ///     ② 语法上 `onPage` 一旦写成 `(... )? = nil`,无类型尾随闭包
    ///        `extract(document: doc) { i, d in ... }` 会**绑到第一个闭包参数**
    ///        (`isCancelled`)而不是它 —— 2026-09-21 踩到,编译器报的是
    ///        「`@Sendable () -> Bool` 期望 0 个参数」这种指错地方的错
    /// - Returns: 报告。**不抛错** —— 失败本身是结果的一部分
    public static func extract(document: ArchiveDocument,
                               maxReopens: Int = defaultMaxReopens,
                               progressStride: Int = defaultProgressStride,
                               isCancelled: (@Sendable () -> Bool)? = nil,
                               onProgress: (@Sendable (Int) -> Void)? = nil,
                               onPage: @escaping @Sendable (Int, Data) -> Bool) -> PageSequenceReport {
        let pages = document.entries.count
        let reader = SequentialPageReader(document: document)
        let stride = max(progressStride, 1)

        var delivered = 0
        var skippedEncrypted = 0
        var failedPages: [Int] = []
        var failedCount = 0
        var reopens = 0
        var stop: PageSequenceStop = .finished
        var lastScannedPage = 0

        /// 重开扫描器(受 `maxReopens` 约束)。返回 true = 上限用尽,应当收工。
        /// 抽成局部闭包是因为它有多个调用点,而「重开 + 判上限」必须同进同退
        func reopenScanner() -> Bool {
            reader.close()
            reopens += 1
            return reopens > maxReopens
        }

        /// 记进度。**每一条出口都要走它** —— 漏一处就会留下
        /// 「进度条卡在某处不动」这种没人会报的 bug
        func advance(_ index: Int) {
            lastScannedPage = index
            if (index + 1) % stride == 0 {
                onProgress?(index + 1)
            }
        }

        for index in 0..<pages {
            if let isCancelled, isCancelled() {
                stop = .cancelled
                break
            }

            let data: Data
            do {
                data = try reader.data(at: index)
            } catch let error as ArchiveError where error.isEncryptionRelated {
                // 页是好的,只是我们读不了 —— **不算损坏**(把它算成损坏会让
                // 部分加密包永远报红,而用户其实只需要输个密码)。
                // 要不要重开取决于错误**从哪来**(与完整性检查同款区分):
                //   · `.encrypted` 只可能来自前置拦截 —— 它没碰流,不必重开;
                //   · 其余三个都来自真读,流的位置不可信
                skippedEncrypted += 1
                if error != .encrypted, reopenScanner() {
                    stop = .stalled
                    advance(index)
                    break
                }
                advance(index)
                continue
            } catch {
                // 坏页(其余 ArchiveError 与理论上的其他错误)。
                // 数据读失败后流位置不可信,必须重开 —— 否则后面每页都会跟着失败
                failedCount += 1
                if failedPages.count < PageSequenceReport.failedPageLimit {
                    failedPages.append(index)
                }
                if reopenScanner() {
                    stop = .stalled
                    advance(index)
                    break
                }
                advance(index)
                continue
            }

            if !onPage(index, data) {
                // 消费方说别再给了(最常见:磁盘满 / 没写权限)。
                // **不把它算进 failedPages** —— 页本身是好的,失败的是「写出去」这件事,
                // 混在一起会让用户以为是压缩包坏了
                stop = .sinkStopped
                advance(index)
                break
            }
            delivered += 1
            advance(index)
        }

        return PageSequenceReport(pages: pages,
                                  delivered: delivered,
                                  skippedEncrypted: skippedEncrypted,
                                  failedPages: failedPages,
                                  failedCount: failedCount,
                                  stop: stop,
                                  lastScannedPage: lastScannedPage)
    }
}
