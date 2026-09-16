// AI-Generated | 可修改
// ThumbnailProvider —— Finder 缩略图扩展(设计文档 §2.4 v2 候选池落地)
// ----------------------------------------------------------------------------
// 效果:Finder 里每个 .cbz/.cbr/.cb7/.cbt 的图标直接是它的封面。
// 扩展点:com.apple.quicklook.thumbnail(appex 只能声明一个扩展点,所以预览
// 另起一个 target,见 UnrollQuickLook/Preview/)。
//
// 三条实现纪律:
//   ① **异步**:`provideThumbnail` 的回调是主线程来的,而读归档是同步 IO ——
//      必须挪到后台队列,否则一屏几十个文件会把 Finder 卡住(QuickLook 还会
//      因为超时判扩展无响应,直接退回默认图标,表现为"时灵时不灵")。
//   ② **失败一律回 (nil, nil)**:这是 QuickLook 的合法语义 =「本扩展不产出
//      缩略图」→ Finder 退回系统通用图标。**刻意不画占位图**:在每个加密归档上
//      挂一张锁图标,比默认图标更没有信息量,还会让人以为归档有问题。
//   ③ **只认首页**:不建索引、不扫全包(见 CoverProvider 注释)。
import AppKit
import ArchiveKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    /// 把框架给的回调跨线程搬运的显式盒子。
    /// `(QLThumbnailReply?, Error?) -> Void` 是函数类型,Swift 6 下不满足 Sendable,
    /// 直接在 @Sendable 闭包里捕获会报 warning(2026-09-16 实测)。
    /// 这里声明的是**我们确实安全**:只做值搬运 —— 不改任何捕获的可变状态、
    /// 每条路径恰好调用一次、QuickLook 的回调契约本就允许任意队列调用它。
    /// (与 CoverProvider.PageImage 同一手法:理由写在类型上,避免下一个人以为是无脑消警告)
    private struct CompletionBox: @unchecked Sendable {
        let call: (QLThumbnailReply?, Error?) -> Void
    }

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        // 系统给的尺寸已经含了屏幕倍率(Finder 图标 512pt @2x → 1024px);
        // 直接用,不要自己乘 scale
        let size = request.maximumSize
        let completion = CompletionBox(call: handler)

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = CoverProvider.firstPage(at: url, maxPixel: CoverProvider.thumbnailPixel)
            DispatchQueue.main.async {
                switch outcome {
                case .page(let page, _):
                    let reply = QLThumbnailReply(contextSize: size) { _ -> Bool in
                        Self.draw(page.image, fittedIn: size)
                        return true
                    }
                    completion.call(reply, nil)
                case .encrypted, .unreadable:
                    completion.call(nil, nil)
                }
            }
        }
    }

    /// 等比缩放居中绘制(不裁切、不变形)。
    /// 用 `NSImage.draw(in:)` 而不是直接 `CGContext.draw` —— QuickLook 给的
    /// 上下文坐标系由它决定,`NSImage` 会跟着当前图形上下文正确处理翻转;
    /// 手写 flip 容易在不同系统版本上反过来(颠倒的封面很难一眼发现)
    private static func draw(_ image: CGImage, fittedIn size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let target = NSImage(cgImage: image, size: .zero)
        let scale = min(size.width / CGFloat(image.width),
                        size.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale,
                           height: CGFloat(image.height) * scale)
        let rect = CGRect(x: (size.width - drawn.width) / 2,
                          y: (size.height - drawn.height) / 2,
                          width: drawn.width,
                          height: drawn.height)
        target.draw(in: rect)
    }
}
