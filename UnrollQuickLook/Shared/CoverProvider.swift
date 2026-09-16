// AI-Generated | 可修改
// CoverProvider —— QuickLook 扩展共用的「读首页」逻辑(设计文档 §2.4 v2 候选池落地)
// ----------------------------------------------------------------------------
// 预览扩展与缩略图扩展是两个独立 appex(QuickLook 的扩展点标识只能有一个),
// 但要做的事是同一件:**打开归档 → 取首页 → 解码成图**。故抽到 Shared/ 下,
// 两个 target 各自编译一份(几百字节的重复,好过一个三方 framework)。
//
// 四条设计约束:
//   ① **只读首页,不建索引**:Finder 缩略图是高频调用(一屏几十个文件),
//      绝不能走「扫全包」。`ArchiveDocument.open` 建索引 + 读第 0 页,代价固定。
//      也正因如此**不用** SequentialPageReader —— 那是给连续翻页准备的单实例扫描器。
//      (`ArchiveDocument.data(at:)` 的 O(n²) 风险只在"每页重开"的多页场景成立,
//      单页读取恰好是它的最佳用法)
//   ② **必须降采样**:首页可能是 4000×6000 扫描件,全解一次几十 MB 只为画一张
//      512pt 的 Finder 图标不划算 → 走 ImageIO 的缩略图路径。
//   ③ **绝不抛给宿主**:宿主拿不准扩展会怎么崩,一律用 CoverOutcome 表达三态,
//      由各扩展决定怎么呈现(§5.9.4「绝不闪退」在扩展里同样成立)。
//   ④ **加密归档如实返回 .encrypted**,不吞成 .unreadable —— 缩略图那侧要靠它
//      决定「宁可退默认图标,也不挂一张误导性的占位图」。
import ArchiveKit
import CoreGraphics
import Foundation
import ImageIO

/// 首页读取结果。CGImage 在 CF 层是不可变对象,跨线程只读传递是安全的,
/// 但 SDK 未把 CGImage 标注为 Sendable → 用 `PageImage` 显式声明这层语义
enum CoverOutcome: Sendable {
    case page(PageImage, total: Int)
    case encrypted
    case unreadable
}

/// 跨线程传递 CGImage 的显式包装(`@unchecked Sendable` 的理由写在类型注释里,
/// 避免下一个读到这行的人以为是无脑消警告)
struct PageImage: @unchecked Sendable {
    /// CGImage 是不可变 CF 对象:构造后无任何可变状态,只读跨线程安全
    let image: CGImage
}

enum CoverProvider {

    /// 缩略图长边上限。Finder 图标最大 512pt,Retina @2x → 1024 足够
    static let thumbnailPixel = 1024
    /// 预览长边上限。预览窗口可拉大甚至全屏,2048 兼顾清晰与首屏延迟
    static let previewPixel = 2048

    /// 同步读首页 —— **调用方负责放到后台线程**(首页解码是百毫秒级同步 IO,
    /// 占住主线程会让 Finder / 预览面板转菊花)
    static func firstPage(at url: URL, maxPixel: Int) -> CoverOutcome {
        let document: ArchiveDocument
        do {
            document = try ArchiveDocument.open(url: url)
        } catch let error as ArchiveError {
            return Self.outcome(forOpenFailure: error)
        } catch {
            return .unreadable
        }

        guard let first = document.entries.first else { return .unreadable }
        guard let data = try? document.data(at: first.index),
              let image = downsample(data, maxPixel: maxPixel) else {
            // 有索引但首页读不出来:损坏页 / 加密页 / 非图片内容
            return .unreadable
        }
        return .page(PageImage(image: image), total: document.entries.count)
    }

    /// Data → CGImage(长边不超过 maxPixel)。
    /// `kCGImageSourceCreateThumbnailWithTransform` 保证 EXIF 方向被应用 ——
    /// 手机拍的"漫画"(照片归档)不这么做会横竖颠倒
    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
    }

    /// 打开失败 → 三态。加密类错误单独识别:7z 头部加密 / ZIP 加密 / 不支持解密的格式
    /// (§5.9 的三态检测结论在扩展里同样适用,**措辞保持与 App 一致**)
    private static func outcome(forOpenFailure error: ArchiveError) -> CoverOutcome {
        switch error {
        case .encrypted, .headerEncrypted, .encryptedUnsupportedFormat:
            return .encrypted
        default:
            // 含 .corrupted / .empty / .noImages / .unknown:对预览来说都是「读不出来」
            return .unreadable
        }
    }
}
