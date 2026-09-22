// AI-Generated | 可修改
// PageExport —— 「当前页 / 当前摊另存为图片」(设计文档 §2.2)
// ----------------------------------------------------------------------------
// 全部是纯函数:合成摊图 + 编码 + 建议文件名。**不碰文件系统、不弹面板** ——
// 保存面板与写盘在 App 层(PageSavePanel),于是这里可以逐像素单测。
//
// ⚠️ 2026-09-21 更正:§2.2 原文写的是「只做当前页另存,不做整包导出」。
// 「不做整包导出」这半句的**依据本身是错的** —— 它假定了「整包解压可以交给系统
// 归档工具」,而实测(macOS 15.7.4)Archive Utility 声明的输入类型只有
// `public.zip-archive`,没有 rar 没有 7z;系统 `tar` 对实体 RAR 直接拒。
// 更要紧的是:**就算能解,解出来的也不是我们要的东西** —— 朴素解压给的是归档顺序
// (实测 page10 / page2 / page1)并夹带 `__MACOSX` / `note.txt`。
// 于是另起了 `⇧⌘E 导出本卷页文件`(顺序遍历在 ArchiveKit.PageSequenceExtractor,
// 命名复用本文件)。两件事的分工:⌘S = 屏幕上那一摊(合成、可重编码);
// ⇧⌘E = 归档里的每一页(原始字节直通)。详见 `PageSequenceExport` 文件头。
//
// 两个口径(与画布渲染保持一致,否则「导出的和看到的不一样」):
//   · 双页模式下导出的是**用户看到的那一摊**,不是单页 —— 屏幕上就是两页并排,
//     导出一页会与所见不符;
//   · 并排顺序跟随阅读方向(右开 = 第二面在左)。合成口径与 `ReaderCanvas.spreadView`
//     的 `images.reversed()` 是同一条规则。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PageExport {

    /// 导出格式。PNG 无损(线稿 / 截图),JPEG 小体积(彩页分享)
    enum Format: String, CaseIterable {
        case png
        case jpeg

        var utType: UTType {
            switch self {
            case .png:  return .png
            case .jpeg: return .jpeg
            }
        }

        /// 存盘扩展名(JPEG 用 jpg,与系统惯例一致 —— 不被 `deletingPathExtension` 的
        /// 习惯用法绊住,也方便按扩展名回推格式)
        var fileExtension: String {
            switch self {
            case .png:  return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    /// 摊图合成:单页原样返回;双页按阅读方向并排。
    /// 白底 —— 漫画页本身白底,接缝处一道黑边比白边刺眼得多;
    /// 两页高度不同时取较高者,较矮的一页垂直居中(不裁切、不拉伸)
    static func compose(primary: CGImage,
                        secondary: CGImage?,
                        rightToLeft: Bool) -> CGImage {
        guard let secondary else { return primary }

        let left = rightToLeft ? secondary : primary
        let right = rightToLeft ? primary : secondary
        let height = max(left.height, right.height)
        let width = left.width + right.width
        guard width > 0, height > 0 else { return primary }

        // 画布沿用第一页的色彩空间 —— 用 DeviceRGB 会**白白过一次色彩解释**
        // (2026-09-16 实测:通用 RGB 的纯红填进设备 RGB 后被写成 255,38,0)。
        // 只在源是 RGB 时沿用:灰度/索引色的上下文会把彩页画成灰的,那更糟
        let model = left.colorSpace?.model
        let space = (model == .rgb ? left.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()

        // noneSkipLast:导出不需要 alpha(PNG 有白底已足够),省一档内存
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return primary }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(left, in: CGRect(x: 0, y: (height - left.height) / 2,
                                      width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width, y: (height - right.height) / 2,
                                       width: right.width, height: right.height))
        return context.makeImage() ?? primary
    }

    /// 编码。失败返回 nil —— 调用方**不得静默**(要告诉用户没存成,§5.9.4 约束 4 的精神)
    static func encode(_ image: CGImage, as format: Format) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil) else { return nil }

        // 彩页分享场景:0.92 肉眼无损、体积约为 PNG 的 1/4
        let properties: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92]
            : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 建议文件名:`<归档名>-p003.png`(页码 1-based,按总页数位宽补零,至少 3 位)。
    /// 只用文件名、不带目录 —— 与「绝不落路径」的隐私基线一致(§5.7 / §5.10.4)
    static func suggestedFileName(documentName: String?,
                                  page: Int,
                                  pageCount: Int,
                                  format: Format) -> String {
        suggestedFileName(documentName: documentName, page: page, pageCount: pageCount,
                          fileExtension: format.fileExtension)
    }

    /// 同上,但扩展名由调用方给定。
    /// 拆出这一层是因为**批量导出要沿用条目原名里的扩展名**(见 `exportFileExtension`),
    /// 而不是统一 png/jpg。命名规则(含补零位宽)只留一份实现 ——
    /// 两条链各写一遍的话,「总页数从 999 变 1000 时补零位数跳档」这种事迟早只在一边修
    static func suggestedFileName(documentName: String?,
                                  page: Int,
                                  pageCount: Int,
                                  fileExtension: String) -> String {
        let base: String
        if let documentName, !documentName.isEmpty {
            base = (documentName as NSString).deletingPathExtension
        } else {
            base = "page"
        }
        let digits = max(3, String(max(pageCount, 1)).count)
        let number = String(max(page, 0) + 1)
        let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
        return "\(base)-p\(padded).\(fileExtension)"
    }

    // MARK: - 批量导出的扩展名(2026-09-21)

    /// 批量导出时这一页该落成什么扩展名。两条判据,**顺序不能换**:
    ///
    ///   1. **条目原名里的扩展名**优先。它带着打包者的原始信息(「这张到底是 png 还是 jpg」),
    ///      而批量导出要的是「提取原素材」,不是「重新表述一遍我们认出了什么」;
    ///   2. 原名给不出可用扩展名时按**魔数**嗅探。这不是多余的谨慎:
    ///      `ArchiveDocument.isListedImage` 刻意**收下**无扩展名的条目(老式扫描包
    ///      用 `vol01/001` 这类命名),它们在**阅读**时靠「ImageIO 按内容识别、
    ///      根本不看扩展名」照常能显示 —— 导出时若少这一步,这些页会全部落成 `.bin`,
    ///      在访达里双击打不开(系统图片查看器靠的就是扩展名)。
    ///
    /// 兜底是 `.bin` 而**不是猜一个 `.jpg`**:包里混进被当成页的非图片(`README` 这类)
    /// 时,如实标成未知,好过谎报成 jpg —— 后者会让用户以为是"导出的图坏了"。
    ///
    /// 只读前 16 字节、**不解码**(与「解码层的事不混进归档层」同一条界,§5.9.4)
    static func exportFileExtension(forEntryPath path: String, data: Data) -> String {
        let original = (path as NSString).pathExtension.lowercased()
        if isUsableExtension(original) { return original }
        return sniffedExtension(data) ?? "bin"
    }

    /// 原名里的扩展名能不能直接拿去落盘:非空且纯 ASCII 字母。
    /// 与 `isListedImage` 的规则 3 同源 —— `ch01.p01` 的 `p01` 含数字,
    /// 那不是扩展名而是名字的一部分,当扩展名用会得到一堆打不开的文件
    private static func isUsableExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// 按魔数嗅探(只认系统必然能显示的那几种)。返回 nil = 认不出来,**不猜**
    static func sniffedExtension(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(16))
        guard head.count >= 4 else { return nil }

        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return "png" }
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        if head[0] == 0x47, head[1] == 0x49, head[2] == 0x46, head[3] == 0x38 { return "gif" }
        if head[0] == 0x42, head[1] == 0x4D { return "bmp" }
        if head[0] == 0x49, head[1] == 0x49, head[2] == 0x2A, head[3] == 0x00 { return "tiff" }
        if head[0] == 0x4D, head[1] == 0x4D, head[2] == 0x00, head[3] == 0x2A { return "tiff" }

        // WebP:"RIFF" + 4 字节长度 + "WEBP"
        if head.count >= 12,
           head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46,
           head[8] == 0x57, head[9] == 0x45, head[10] == 0x42, head[11] == 0x50 {
            return "webp"
        }
        // HEIC / AVIF / HEIF:都是 ISO-BMFF —— 第 4..8 字节为 "ftyp",兼容品牌在 8..12
        if head.count >= 12,
           head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70,
           let brand = String(bytes: head[8..<12], encoding: .ascii)?.lowercased() {
            switch brand {
            case "avif", "avis":                 return "avif"
            case "heic", "heix", "hevc", "hevx": return "heic"
            case "mif1", "msf1":                 return "heif"
            default:                             return nil
            }
        }
        return nil
    }
}
