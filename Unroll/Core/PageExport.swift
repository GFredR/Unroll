// AI-Generated | 可修改
// PageExport —— 「当前页 / 当前摊另存为图片」(设计文档 §2.2:只做当前页另存,不做整包导出)
// ----------------------------------------------------------------------------
// 全部是纯函数:合成摊图 + 编码 + 建议文件名。**不碰文件系统、不弹面板** ——
// 保存面板与写盘在 App 层(PageSavePanel),于是这里可以逐像素单测。
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
        let base: String
        if let documentName, !documentName.isEmpty {
            base = (documentName as NSString).deletingPathExtension
        } else {
            base = "page"
        }
        let digits = max(3, String(max(pageCount, 1)).count)
        let number = String(max(page, 0) + 1)
        let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
        return "\(base)-p\(padded).\(format.fileExtension)"
    }
}
