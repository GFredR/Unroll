// AI-Generated | 可修改
// PageGrid —— 缩略图网格的顺序生成器 + 有界缩略图池(设计文档 §5.14,v1.1 2026-09-18)
// ----------------------------------------------------------------------------
// ## 为什么必须**顺序**生成,而不是「滚到哪生成哪」
// libarchive 的流只能前进:取第 k 页 = 关实例重开 + 从头走 k 个 header
// (§5.1 实测,solid 7z 上「每页一实例」是 O(n²),150 页慢 71×)。
// 而网格天生是**随机访问**的用法 —— 用户滚到 300 再滚回 5。照那个写法,
// 一遍滚动就是一次 O(n²)。
//
// 所以反过来:**一趟顺序扫完,谁就绪谁先显示**;滚回已就绪的页是纯内存命中,
// 滚到还没扫到的页先显示页码占位。代价是「某页缩略图何时可见」不再由滚动决定,
// 而由扫描进度决定;收益是总代价被钉死在 **O(n)**,与页数线性。
//
// ## 预算语义与 `PageCache` **不同**,别照抄
// `PageCache` 是「超出即 LRU 淘汰」,因为那些页随时可能被重新解码(翻回去就取)。
// 这里是「**超出即停止生成**」—— 顺序扫已经保证了 O(n),若再引入淘汰,
// 被淘汰的页滚回来时只能随机访问重取,就把 O(n²) 请回来了。
// 到顶就停是一条**没有坏分支**的规则;诚实告知用户比偷偷劣化好。
//
// ## 与 `ArchiveIntegrityChecker` 的关系:同一套骨架,别各写一份
// 独立的 `SequentialPageReader`、每页问一次取消、加密与损坏分流、
// 坏页后受控重开、**不抛错**(失败本身是结果的一部分)。
// 只有两点不同:本文件在**解码后降采样**(所以它放 App 层 —— ImageIO 是 App 的活,
// ArchiveKit 刻意只管到「字节读得通」为止),以及多一条「预算到顶」的出口。
import ArchiveKit
import CoreGraphics
import Foundation

// MARK: - 停止原因

/// 停下来的原因。**四态而不是一个 Bool** —— 四个原因对用户的意义完全不同:
///   · `finished`       —— 整卷缩略图都在,滚动即见;
///   · `budgetReached`  —— 只有前一段有图,**后面的页永远不会有图**(内存上限),
///                         界面必须说出来,否则用户会以为是「还没扫到」而一直等;
///   · `cancelled`      —— 用户自己叫停的,不是失败,文案不能写成「出错」;
///   · `scannerStalled` —— 包坏得连遍历都走不下去(重开次数用尽),此时
///                         「还有多少页没图」是**未知**的,不能说成「就这些」
enum PageGridStop: Equatable {
    case finished
    case budgetReached
    case cancelled
    case scannerStalled

    /// 面包屑标签(过 sanitize 白名单)
    var token: String {
        switch self {
        case .finished:       return "full"
        case .budgetReached:  return "budget"
        case .cancelled:      return "cancelled"
        case .scannerStalled: return "stalled"
        }
    }
}

// MARK: - 报告

/// 生成报告。全是值语义,可跨隔离域传递、可直接断言
struct PageGridReport: Equatable {

    /// 归档总页数
    let pages: Int
    /// 成功生成缩略图的页数
    let generated: Int
    /// 因加密而**跳过**的页数。**不是损坏** —— 没给密码时读不出是预期行为,
    /// 与 `ArchiveIntegrityReport.skippedEncrypted` 同一判据(不要各写一份)
    let skippedEncrypted: Int
    /// 解不出来 / 读不出来的页(0 起,升序)。为控制报告体积最多保留
    /// `failedPageLimit` 项,真实总数看 `failedCount`
    let failedPages: [Int]
    /// 坏页真实总数(可能大于 `failedPages.count`)
    let failedCount: Int
    let stop: PageGridStop
    /// 停止时处理到的页(0 起)。供「已处理到第 N 页」这类文案
    let lastScannedPage: Int

    /// 报告里最多列出几个坏页
    static let failedPageLimit = 20

    /// 生成数 + 跳过数 + 失败数是否已经覆盖全档 —— `budgetReached` / `scannerStalled`
    /// 时为 false。**它是「有没有漏页」的机器判据**,文案不该自己算
    var coversAllPages: Bool {
        generated + skippedEncrypted + failedCount >= pages
    }
}

// MARK: - 预算

/// 网格池的双判据预算。可注入是为了单测能用小阈值验证「到顶即停」——
/// 真实预算 2400 万像素造不出来(与 `PageCache.Budget` 同一口径)
struct PageGridBudget: Equatable {
    let maxCount: Int
    let maxPixels: Int

    static let `default` = PageGridBudget(
        maxCount: DesignSystem.PageBudget.maxGridThumbnails,
        maxPixels: DesignSystem.PageBudget.maxGridThumbnailPixels)
}

// MARK: - 生成器

/// 顺序生成整卷缩略图(纯函数式:入参文档,出参报告,不持任何状态)
enum PageGridBuilder {

    /// 顺序扫一遍全档,逐页降采样解码,把缩略图交给 `onThumbnail`。
    ///
    /// - Parameters:
    ///   - document: 已打开的文档。加密包请传**带密码**后的文档 ——
    ///     用未解锁的文档生成,加密页会被算成 `skippedEncrypted`(与完整性检查同口径)
    ///   - maxPixel: 缩略图长边上限
    ///   - budget: 池子双判据(个数 + 像素)。**任一超出即收工**,不是淘汰
    ///   - maxReopens: 坏页后允许重开扫描器的次数上限,超了即 `scannerStalled`。
    ///     默认 16 —— 比完整性检查的 32 小:检查的目的是「给出整包结论」,值得为它
    ///     多扛几次重开;而缩略图只是浏览辅助,遇到烂包早点收手更划算
    ///   - progressStride: 每处理这么多页回调一次进度。逐页回调在 500 页的包上
    ///     会往主线程灌 500 次更新,而进度条只需要几十次
    ///   - isCancelled: 每个页边界问一次。true → 立即收工
    ///   - onThumbnail: 每生成一张回调一次(页码, 图)。**在调用方线程同步回调**,
    ///     调用方自己负责切回隔离域
    ///   - onProgress: 每处理 `progressStride` 页回调一次(已处理页数)
    /// - Returns: 报告。**不抛错** —— 「有几页没有缩略图」和「网格压根没建起来」
    ///   是两件事,混成一个 throw 会让界面只剩下「失败了」一句什么也没说清的话
    static func build(document: ArchiveDocument,
                      maxPixel: CGFloat,
                      budget: PageGridBudget = .default,
                      maxReopens: Int = 16,
                      progressStride: Int = 8,
                      isCancelled: (@Sendable () -> Bool)? = nil,
                      onThumbnail: (@Sendable (Int, CGImage) -> Void)? = nil,
                      onProgress: (@Sendable (Int) -> Void)? = nil) -> PageGridReport {

        let pages = document.entries.count
        let reader = SequentialPageReader(document: document)
        let stride = max(progressStride, 1)

        var generated = 0
        var generatedPixels = 0
        var skippedEncrypted = 0
        var failedPages: [Int] = []
        var failedCount = 0
        var reopens = 0
        var stop: PageGridStop = .finished
        var lastScannedPage = 0

        /// 重开扫描器(受 `maxReopens` 约束)。返回 true = 上限用尽,应当收工。
        /// 抽成局部闭包是因为它有多个调用点,而「重开 + 判上限」必须同进同退
        func reopenScanner() -> Bool {
            reader.close()
            reopens += 1
            return reopens > maxReopens
        }

        /// 记进度。三处出口(message 分支、解码失败、成功)都要走它 ——
        /// 漏一处就会出现「进度条停在某处不动」这种没人会报的 bug
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

            // ---- 第一层:取字节。这是**唯一**会移动流位置的一步 ----
            let data: Data
            do {
                data = try reader.data(at: index)
            } catch let error as ArchiveError where error.isEncryptionRelated {
                // 与完整性检查同一条判据:页是好的,只是我们读不了 —— 不算损坏
                skippedEncrypted += 1
                // 要不要重开取决于错误**从哪来**(这条区分很容易写错):
                //   · `.encrypted` 只可能来自 `SequentialPageReader.data(at:)` 的
                //     **前置拦截** —— 它在触碰流之前就返回,扫描器位置没动;
                //   · 其余三个都来自**真读**,流的位置不可信。
                // 一律不重开会漏掉后一种;一律重开则让「部分加密包」在每个加密页
                // 白付一次 O(i) 的重扫
                if error != .encrypted, reopenScanner() {
                    stop = .scannerStalled
                    advance(index)
                    break
                }
                advance(index)
                continue
            } catch {
                // 字节读不出来 = 坏页。数据读失败后**流位置不可信**,必须重开 ——
                // 否则后面每页都会跟着失败,报告会变成「除第一页外全坏」这种假结论
                failedCount += 1
                if failedPages.count < PageGridReport.failedPageLimit {
                    failedPages.append(index)
                }
                if reopenScanner() {
                    stop = .scannerStalled
                    advance(index)
                    break
                }
                advance(index)
                continue
            }

            // ---- 第二层:降采样解码。失败**不重开** ----
            // 这条区分不是洁癖:解码失败时流位置**没动过**,重开纯属白付代价 ——
            // 一个「混进了几十个非图片条目」的包会因此每次都从头走一遍,
            // 退化成 O(n²)。而第一层的字节读失败必须重开,两者不能合并处理
            let image: CGImage
            do {
                image = try PageDecoder.decodeThumbnail(data, maxPixel: maxPixel)
            } catch {
                failedCount += 1
                if failedPages.count < PageGridReport.failedPageLimit {
                    failedPages.append(index)
                }
                advance(index)
                continue
            }

            // ---- 第三层:预算。判定放在**接收之前** ----
            // 宁可少收一张,也不让池子超出上限后靠「事后补救」——事后补救只能是
            // 淘汰,而淘汰正是本文件要避开的那条路(见文件头)
            let pixels = image.width * image.height
            if generated + 1 > budget.maxCount || generatedPixels + pixels > budget.maxPixels {
                stop = .budgetReached
                advance(index)
                break
            }

            onThumbnail?(index, image)
            generated += 1
            generatedPixels += pixels
            advance(index)
        }

        return PageGridReport(pages: pages,
                              generated: generated,
                              skippedEncrypted: skippedEncrypted,
                              failedPages: failedPages,
                              failedCount: failedCount,
                              stop: stop,
                              lastScannedPage: lastScannedPage)
    }
}

// MARK: - 缩略图池

/// 网格缩略图的**有界**存储。
///
/// 与 `PageCache` 的三处刻意差别,别把它当成第二个 PageCache:
///   · **不淘汰** —— 收满即拒收(拒收的判定在 `PageGridBuilder`,不在这里)。
///     于是不存在「淘汰后又被滚回视野、却无法重新生成」的悬空状态;
///   · **不记 LRU 时钟** —— 没有淘汰就没有顺序可排,少一份状态少一处能写错的地方;
///   · **双账本(个数 + 像素)照旧保留** —— 这条教训是通用的:按**个数**限制一个
///     大小可变的资源等于没限制(见 `PageCache` 文件头与设计文档 §5.3)。
///     预算常量在 `DesignSystem.PageBudget`,本类只负责记账
///
/// ## 为什么是锁保护,而不是「写回主线程」
/// 写它的一方是后台顺序扫描(每页一次),读它的一方是 MainActor 上的网格渲染。
/// 第一版的做法是每张图都 `Task { @MainActor in pool.store(...) }` 回跳 ——
/// 两个都错:
///   · **慢**:500 页的包会凭空造 500 个任务,而且池子要等这些任务调度完才填满;
///   · **不确定**:`build()` 返回时池子**可能还是空的**(回跳任务还没轮到),
///     于是「生成完成」与「图画得出来」之间隔着一个没人能断言的时间窗 ——
///     测试只能靠 sleep 猜,而 UI 上表现为"进度条到头了图还没出全"。
/// 改成**同步写入 + 锁**:扫描线程直接落库,`build()` 返回即已填满。
/// 跨代次的隔离改由「**每一轮生成新建一个池子**」保证 ——
/// 换书后旧的扫描还在写?它写的是那个已经被丢弃的旧池子,污染不到新书。
///
/// `@unchecked Sendable` 是诚实声明:线程安全靠下面那把 NSLock,**不是**靠
/// 编译器能证明的隔离(与 `CancellationFlag` 同一句话,别把两者混为一谈)
final class ThumbnailStore: @unchecked Sendable {

    private let lock = NSLock()
    private var images: [Int: CGImage] = [:]
    private var pixelTotal = 0

    /// 已存张数(测试/诊断断言口)
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return images.count
    }

    /// 已存像素总额。与 `count` 配对断言 —— 只有个数没有像素,
    /// 正是 `PageCache` 缩略图池曾经失控的原因
    var pixels: Int {
        lock.lock(); defer { lock.unlock() }
        return pixelTotal
    }

    /// 存一张。**同页重存会先结清旧账**,避免双计
    func store(_ image: CGImage, at page: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = images[page] {
            pixelTotal -= Self.pixels(of: old)
        }
        images[page] = image
        pixelTotal += Self.pixels(of: image)
    }

    func image(at page: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return images[page]
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        images.removeAll()
        pixelTotal = 0
    }

    private static func pixels(of image: CGImage) -> Int {
        image.width * image.height
    }
}
