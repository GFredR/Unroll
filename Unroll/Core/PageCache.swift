// AI-Generated | 可修改
// PageCache —— LRU + 像素预算页缓存(设计文档 §4.1 / §5.3 图 6,M2 实现)
// ----------------------------------------------------------------------------
// 两条设计要点(§5.3,写死在验收里):
//   · Trimmed ≠ 释放:被淘汰的页先降为 1600px 缩略图,不直接丢弃,
//     保证用户翻回来不至于白屏;
//   · 双阈值任一超出即触发 LRU 淘汰:≤8 页全分辨率 且 ≤2 亿像素
//     (阈值常量在 DesignSystem.PageBudget,改预算只动那一个地方)。
//
// 线程约束(写死):本类**必须被 PageStore actor 独占** —— 无锁实现,
// lastTouch/tick 的读改写只在单一隔离域内串行发生;跨域共享是调用方 bug。
//
// 状态机对应(图 6):fullImage 有值 = Cached/Hot;仅 thumbnail = Trimmed;
// 两者皆无 = Evicted(条目移除)。
import CoreGraphics
import Foundation

final class PageCache {

    /// 淘汰类型(对应图 6 的两个终态)
    enum EvictionKind {
        case demoted   // Trimmed:全分辨率降为缩略图
        case evicted   // Evicted:条目彻底移除
    }

    /// 预算(默认值全部来自 DesignSystem.PageBudget 单一真源;
    /// 可注入是为了单测能用小阈值验证淘汰逻辑 —— 真实预算 2 亿像素造不出来)
    struct Budget {
        let maxFullPages: Int
        let maxPixels: Int
        let maxThumbnails: Int

        static let `default` = Budget(
            maxFullPages: DesignSystem.PageBudget.maxCachedPages,
            maxPixels: DesignSystem.PageBudget.maxPixels,
            maxThumbnails: DesignSystem.PageBudget.maxThumbnails)
    }

    private let budget: Budget

    /// 淘汰回调 —— 崩溃面包屑的观测点(§5.10.3-① 示例轨迹里的 cacheEvict)。
    /// **默认 nil**:单测里 PageCache 只关心预算与 LRU,不该顺手往诊断链路灌事件
    private let onEviction: ((Int, EvictionKind) -> Void)?

    init(budget: Budget = .default,
         onEviction: ((Int, EvictionKind) -> Void)? = nil) {
        self.budget = budget
        self.onEviction = onEviction
    }

    /// 单页条目。fullImage 为 nil 表示已降级(Trimmed),只剩缩略图
    private struct Entry {
        var fullImage: CGImage?
        var thumbnail: CGImage?
        /// fullImage 的像素数(降级后归零;缩略图不占全分辨率预算)
        var fullPixels: Int
        var lastTouch: UInt64
    }

    private var entries: [Int: Entry] = [:]
    /// LRU 时钟:每次触碰 +1,值大 = 最近使用
    private var tick: UInt64 = 0
    private var fullPixelTotal = 0

    // MARK: - 观测(单测断言用;PageStore 日志也读)

    var fullResPageCount: Int { entries.values.count { $0.fullImage != nil } }
    var fullResPixelTotal: Int { fullPixelTotal }
    var thumbnailCount: Int { entries.values.count { $0.thumbnail != nil } }

    // MARK: - 读

    /// 取全分辨率图(命中即触碰 LRU);Trimmed/未缓存 → nil
    func fullImage(at page: Int) -> CGImage? {
        guard var entry = entries[page] else { return nil }
        if let image = entry.fullImage {
            tick += 1
            entry.lastTouch = tick
            entries[page] = entry
            return image
        }
        return nil
    }

    /// 取缩略图(Trimmed 态的占位图);不触碰 LRU —— 缩略图只是「垫一下」,
    /// 不该因此把全分辨率预算的淘汰顺序顶掉
    func thumbnail(at page: Int) -> CGImage? {
        entries[page]?.thumbnail
    }

    /// 纯查询(不触碰 LRU):是否存有全分辨率图(预读落地的观测口)
    func hasFullImage(_ page: Int) -> Bool {
        entries[page]?.fullImage != nil
    }

    // MARK: - 写

    /// 登记一页全分辨率图,随后按双阈值执行 LRU 淘汰(图 6 OVER → LRU 分支)
    func insert(page: Int, image: CGImage) {
        tick += 1

        // 同页重插(重解码场景):先按旧条目结清像素账,避免双计
        if let old = entries[page], old.fullImage != nil {
            fullPixelTotal -= old.fullPixels
        }

        entries[page] = Entry(fullImage: image,
                              thumbnail: entries[page]?.thumbnail,
                              fullPixels: Self.pixels(of: image),
                              lastTouch: tick)
        fullPixelTotal += Self.pixels(of: image)

        trim()
    }

    /// 清空(换归档 / teardown)
    func removeAll() {
        entries.removeAll()
        fullPixelTotal = 0
    }

    // MARK: - 淘汰(§5.3 图 6:OVER → LRU → Trimmed → Evicted)

    /// 双阈值任一超出即淘汰;受害者先降缩略图(Trimmed),缩略图超上限再彻底释放。
    /// 保护规则:**绝不动最后一张全分辨率图** —— 单图超预算(>2 亿像素)时,
    /// 否则会出现「插进去就被自己淘汰」的永久缓存穿透
    private func trim() {
        while fullResPageCount > 1,
              fullResPageCount > budget.maxFullPages
              || fullPixelTotal > budget.maxPixels {
            guard let victimKey = oldestFullResKey() else { break }
            demote(victimKey)
        }
        trimThumbnails()
    }

    /// 最旧的全分辨率条目(含保护规则:只剩一张时不返回,调用方已兜底)
    private func oldestFullResKey() -> Int? {
        var best: (key: Int, touch: UInt64)?
        for (key, entry) in entries where entry.fullImage != nil {
            if best == nil || entry.lastTouch < best!.touch {
                best = (key, entry.lastTouch)
            }
        }
        // fullResPageCount > 1 已由 trim() 保证,此处 best 必有值
        return best?.key
    }

    /// Trimmed:全分辨率降为缩略图(缩略图缺失时现场生成),像素账结清
    private func demote(_ page: Int) {
        guard var entry = entries[page], let full = entry.fullImage else { return }

        if entry.thumbnail == nil {
            entry.thumbnail = Self.makeThumbnail(from: full)
        }
        fullPixelTotal -= entry.fullPixels
        entry.fullImage = nil
        entry.fullPixels = 0
        entries[page] = entry
        onEviction?(page, .demoted)
    }

    /// 缩略图上限(budget.maxThumbnails):LRU 彻底释放
    private func trimThumbnails() {
        while thumbnailCount > budget.maxThumbnails {
            guard let key = entries
                .filter({ $0.value.thumbnail != nil })
                .min(by: { $0.value.lastTouch < $1.value.lastTouch })?.key
            else { break }
            entries[key]?.thumbnail = nil
            if entries[key]?.fullImage == nil {
                entries.removeValue(forKey: key)   // Evicted:缩略图也没了,条目移除
                onEviction?(key, .evicted)
            }
        }
    }

    // MARK: - 工具

    private static func pixels(of image: CGImage) -> Int {
        image.width * image.height
    }

    /// 1600px 长边缩略图(等比;手写 CGContext 降采样,失败返回 nil ——
    /// 缩略图只是体验优化,失败不允许影响淘汰主流程)
    private static func makeThumbnail(from image: CGImage) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, DesignSystem.PageBudget.thumbnailLongEdge / CGFloat(longEdge))
        let w = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let h = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }}
