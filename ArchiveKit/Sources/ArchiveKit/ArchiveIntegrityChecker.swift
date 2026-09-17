// AI-Generated | 可修改
// ArchiveIntegrityChecker —— 归档完整性检查(2026-09-17 新增)
// ----------------------------------------------------------------------------
// 回答一个问题:「这个包里到底有几页是坏的?」——在用户翻到它们之前。
//
// 与「读页时报错」的区别(这是本模块存在的理由):
//   · 读页是**惰性**的:只有翻到坏页才知道,而且一次只知道一页;
//   · 检查是**主动**的:顺序走一遍,一次说清「第 12、57 页读不出来,其余 480 页正常」。
//   用户拿到这个结论才知道该不该换一个源文件 —— 翻一页报一次错是给不出这个判断的。
//
// ## 判据(刻意只管归档层,不管解码层)
// 校验方式是**把每页的原始字节读到 EOF**。zip 的 CRC 在读到条目末尾时由
// libarchive 校验,损坏会以负返回码暴露 —— 这正是我们要的信号。
//
// **不**验证「图片能否解码」:那要过一遍 ImageIO,单页百毫秒级,500 页的包
// 会跑到分钟级,而收益只是把「解不出来」的页也算进来。归档层的字节读得通、
// 解码层失败,那类问题在阅读时已有明确的单页失败卡片。边界写清楚,别偷偷扩。
//
// ## 遍历策略:单实例顺序扫描器 + 受控重开(§5.1 的同一套约束)
// 用 `SequentialPageReader` 前向读,摊销 O(1)/页 —— 这正是当初禁掉
// 「每页 open 一次」的理由(实测 solid 7z 慢 71×,见测试文档 §4)。
// 但**坏页会把流带坏**:读数据失败后,流的内部位置不再可信,继续前向走
// 只会一路失败。故坏一页就 `close()` 重开;重开是 O(已读页数),所以
// 设 `maxReopens` 上限 —— 一个坏得很彻底的包(几乎每页都坏)会退化成 O(n²),
// 我们不能让「检查」本身变成卡死源。
import Foundation

/// 检查结果。全是值语义,可跨隔离域传递、可直接断言
public struct ArchiveIntegrityReport: Sendable, Equatable {

    /// 归档总页数
    public let pages: Int
    /// 成功读通的页数
    public let checked: Int
    /// 读不出来的页(0 起,升序)。为控制报告体积**最多保留 `damagedPageLimit` 项**,
    /// 真实总数看 `damagedCount` —— 两者分开是为了「有 300 个坏页」时不撑爆 UI
    public let damagedPages: [Int]
    /// 坏页真实总数(可能大于 `damagedPages.count`)
    public let damagedCount: Int
    /// 因加密而**跳过**的页数。这不是损坏:没给密码时读不出是预期行为,
    /// 把它算成损坏会让「部分加密包」永远报红
    public let skippedEncrypted: Int
    /// 是否**过早收工**。两种情况都置位:
    ///   · 反复重开仍未恢复(`maxReopens` 用尽)—— 包坏得连遍历都走不下去;
    ///   · 调用方叫停(用户取消 / 换文件)。
    /// 置位时上面的数字只覆盖「检查到的那一段」,不是全档结论 ——
    /// UI 必须把这句话说出来,否则用户会把「前半段没坏」当成「整包没坏」
    public let stoppedEarly: Bool
    /// `stoppedEarly` 时已检查到的页数(供 UI 说「查到第 N 页」)
    public let lastCheckedPage: Int

    /// 完整检查且无一页损坏 → 可以放心说「没发现问题」
    public var isIntact: Bool { !stoppedEarly && damagedCount == 0 }

    /// 报告里最多列出几个坏页
    public static let damagedPageLimit = 20
}

/// 完整性检查(纯函数式:入参文档,出参报告,不持任何状态)
public enum ArchiveIntegrityChecker {

    /// 顺序校验每一页。
    ///
    /// - Parameters:
    ///   - document: 已打开的文档(加密包请带上密码后的文档 —— 用未解锁的文档检查,
    ///     加密页会被算成 `skippedEncrypted`)
    ///   - maxReopens: 坏页后允许重开扫描器的次数上限。超了即 `stoppedEarly`。
    ///     默认 32:足以扛住「散布几十个坏条目」的包,又不至于让极端坏的包跑成 O(n²)
    ///   - isCancelled: 每个页边界问一次。true → 立即收工并置 `stoppedEarly`
    ///   - onProgress: 每检查完一页回调一次(已检查页数)。用于进度显示
    /// - Returns: 报告。**不抛错** —— 检查失败本身就是结果的一部分,
    ///   让调用方去处理异常会把「有几个坏页」和「整个检查没跑起来」混成一件事
    public static func check(document: ArchiveDocument,
                            maxReopens: Int = 32,
                            isCancelled: (@Sendable () -> Bool)? = nil,
                            onProgress: (@Sendable (Int) -> Void)? = nil) -> ArchiveIntegrityReport {
        let pages = document.entries.count
        let reader = SequentialPageReader(document: document)

        var checked = 0
        var damagedPages: [Int] = []
        var damagedCount = 0
        var skippedEncrypted = 0
        var reopens = 0
        var stoppedEarly = false
        var lastCheckedPage = 0

        /// 重开扫描器(受 maxReopens 约束)。返回 true = 上限用尽,应当收工。
        /// 抽成局部闭包是因为它有四个调用点,而「重开 + 判上限」两件事必须同进同退
        func reopenScanner() -> Bool {
            reader.close()
            reopens += 1
            return reopens > maxReopens
        }

        for index in 0..<pages {
            if let isCancelled, isCancelled() {
                stoppedEarly = true
                break
            }

            do {
                _ = try reader.data(at: index)
                checked += 1
            } catch let error as ArchiveError where error.isEncryptionRelated {
                // 页是好的,只是我们读不了 —— **不算损坏**(把它算成损坏会让
                // 部分加密包永远报红,而用户其实只需要输个密码)
                skippedEncrypted += 1
                //
                // 要不要重开取决于错误**从哪来**(这条区分很容易写错):
                //   · `.encrypted` 只可能来自 `SequentialPageReader.data(at:)` 的
                //     **前置拦截** —— 它在触碰流之前就返回,扫描器位置没动,无需重开;
                //   · 其余三个都来自**真读**(密码不对 / 库解不了),流的位置不可信。
                // 一律不重开会漏掉后一种;一律重开则让「部分加密包」在每个加密页上
                // 白付一次 O(i) 的重扫
                if error != .encrypted, reopenScanner() {
                    stoppedEarly = true
                    lastCheckedPage = index
                    onProgress?(index + 1)
                    break
                }
            } catch {
                // 坏页(ArchiveError 的其余 case,或理论上的其他错误)
                damagedCount += 1
                if damagedPages.count < ArchiveIntegrityReport.damagedPageLimit {
                    damagedPages.append(index)
                }
                // 数据读失败后流位置不可信,必须重开 —— 否则后面每页都会跟着
                // 失败,报告会变成「除第一页外全坏」这种假结论
                if reopenScanner() {
                    stoppedEarly = true
                    lastCheckedPage = index
                    onProgress?(index + 1)
                    break
                }
            }

            lastCheckedPage = index
            onProgress?(index + 1)
        }

        return ArchiveIntegrityReport(pages: pages,
                                      checked: checked,
                                      damagedPages: damagedPages,
                                      damagedCount: damagedCount,
                                      skippedEncrypted: skippedEncrypted,
                                      stoppedEarly: stoppedEarly,
                                      lastCheckedPage: lastCheckedPage)
    }
}

// MARK: - 错误分类

extension ArchiveError {
    /// 是否属于「加密导致的读不出」(而非损坏)。
    /// 检查器与 UI 都要用它做同一个区分 —— 放这里是为了只有一份定义
    public var isEncryptionRelated: Bool {
        switch self {
        case .encrypted, .wrongPassphrase, .encryptedUnsupportedFormat, .headerEncrypted:
            return true
        case .corrupted, .empty, .noImages, .unknown:
            return false
        }
    }
}
