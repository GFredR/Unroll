// AI-Generated | 可修改
// PageSequenceExport —— 「把这一卷的页按阅读顺序导成图片文件」的 App 侧写盘(2026-09-21)
// ----------------------------------------------------------------------------
// 与「另存当前页」(`⌘S` / PageExport) 的分工,一句话说清:
//   `⌘S`     导出**屏幕上那一摊** —— 双页会被合成一张、JPEG 会重新编码。
//            要的是「所见即所得」:导出的和看到的不一样才是 bug。
//   本文件   导出**归档里的每一页** —— 原始字节直通,不合成、不重编码。
//            要的是「原素材」:拿去做壁纸 / 翻译参考板 / 二次加工。
// 两者都得有:把跨页彩图导成**两张**,和导成**一张**,是两种真实需求。
//
// ## 分工:走路在 Kit,落盘在这里
// 顺序遍历、加密/损坏分流、取消、受控重开全在 `ArchiveKit.PageSequenceExtractor`
// (与 `ArchiveIntegrityChecker` 同层同形状,**自己不碰文件系统**)。
// 本文件只做两件 App 侧的事:
//   ① 命名(归档名 + 补零页号 + 扩展名,见 `PageExport`);
//   ② 把字节写进用户选的目录,写不动就回 false 叫停。
// 这样切的好处很实在:遍历逻辑能在**无沙盒的 `swift test`** 下用真实 fixture
// 逐字节断言,不用为了测它而在测试里建文件。
//
// ## 只写「平铺 + 补零页号」,不还原目录结构 —— 这一条同时是安全边界
// 输出路径**从不拼接条目原名**,只用「归档名 + 补零页号 + 扩展名」三样。
// 于是 zip-slip(`../../` 开头的条目名)在**结构上**不可能发生 —— 我们压根不拿
// 条目名当路径。同理也不还原时间戳 / 权限位 / 符号链接:那些是归档工具的语义,
// 不是阅读器的。这条边界是刻意的,别为了「更像解压」而放开它。
import ArchiveKit
import Foundation

enum PageSequenceExporter {

    /// 导出全卷。
    ///
    /// - Parameters:
    ///   - document: 已打开的文档(加密包请传解锁后的文档,否则加密页会被跳过)
    ///   - documentName: 归档显示名,用作文件名前缀(只是文件名,不含路径)
    ///   - directory: 目标目录(由面板授予写权限)
    ///   - isCancelled: 每页问一次
    ///   - onProgress: 每处理完 `PageSequenceExtractor.defaultProgressStride` 页回调一次
    /// - Returns: 报告。**不抛错** —— 失败本身是结果的一部分。
    ///   写盘失败映射成 `stop == .sinkStopped`(页本身没问题,是写不出去)
    static func run(document: ArchiveDocument,
                    documentName: String?,
                    directory: URL,
                    isCancelled: (@Sendable () -> Bool)? = nil,
                    onProgress: (@Sendable (Int) -> Void)? = nil) -> PageSequenceReport {
        let pageCount = document.entries.count
        return PageSequenceExtractor.extract(
            document: document,
            isCancelled: isCancelled,
            onProgress: onProgress,
            onPage: { index, data in
                // 扩展名优先取条目原名,其次按魔数嗅探 —— 字节已经在手里了,
                // 嗅探是零额外 I/O(理由见 `PageExport.exportFileExtension`)
                let ext = PageExport.exportFileExtension(
                    forEntryPath: document.entries[index].path, data: data)
                let name = PageExport.suggestedFileName(documentName: documentName,
                                                        page: index,
                                                        pageCount: pageCount,
                                                        fileExtension: ext)
                do {
                    try data.write(to: directory.appendingPathComponent(name),
                                   options: .atomic)
                    return true
                } catch {
                    // 不复述 error.localizedDescription:那串文字可能带完整路径
                    // (与 §5.10.4 同一条口径 —— 路径不进 UI)。
                    // 回 false 让 Kit 就地收工,报告带 `.sinkStopped`
                    return false
                }
            })
    }
}
