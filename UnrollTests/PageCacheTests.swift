// AI-Generated | 可修改
// PageCacheTests —— LRU + 像素预算 + 缩略图降级单测(设计文档 §5.3 图 6)
// ----------------------------------------------------------------------------
// 真实预算(8 页 / 2 亿像素)在单测里造不出来,故用注入的小 Budget 验证
// 淘汰逻辑本身;预算默认值与 DesignSystem 的绑定由 AppSkeletonTests 锁。
// 断言落在语义上(§6.2):Trimmed 后全分辨率消失但缩略图在(「翻回来不白屏」),
// 像素账目准确,LRU 顺序真实生效。
import CoreGraphics
import XCTest
@testable import Unroll

final class PageCacheTests: XCTestCase {

    /// 小预算(页数 2 / 像素 32 / 缩略图 3),测试图统一 4×4 = 16 像素
    private func makeBudget() -> PageCache.Budget {
        PageCache.Budget(maxFullPages: 2, maxPixels: 32, maxThumbnails: 3)
    }

    /// 合成纯色小图
    private func makeImage(width: Int = 4, height: Int = 4) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: - 基本读写

    func testInsertAndHit() throws {
        let cache = PageCache(budget: makeBudget())
        let image = try makeImage()

        cache.insert(page: 0, image: image)
        XCTAssertEqual(cache.fullImage(at: 0), image)
        XCTAssertEqual(cache.fullResPageCount, 1)
        XCTAssertEqual(cache.fullResPixelTotal, 16)
    }

    func testMissReturnsNil() {
        let cache = PageCache(budget: makeBudget())
        XCTAssertNil(cache.fullImage(at: 0))
        XCTAssertNil(cache.thumbnail(at: 0))
    }

    /// 同页重插(重解码场景):像素账目结清,不得双计
    func testReinsertSamePageDoesNotDoubleCount() throws {
        let cache = PageCache(budget: makeBudget())
        let image = try makeImage()

        cache.insert(page: 0, image: image)
        cache.insert(page: 0, image: image)
        XCTAssertEqual(cache.fullResPageCount, 1)
        XCTAssertEqual(cache.fullResPixelTotal, 16)
    }

    // MARK: - 页数阈值 → Trimmed(§5.3:Trimmed ≠ 释放)

    /// 插入第 3 页超页数阈值:最旧的 page0 降级 —— 全分辨率消失、缩略图保留
    func testOverPageBudgetDemotesOldestButKeepsThumbnail() throws {
        let cache = PageCache(budget: makeBudget())
        for page in 0..<3 {
            cache.insert(page: page, image: try makeImage())
        }

        XCTAssertEqual(cache.fullResPageCount, 2, "页数阈值淘汰后仍保留 2 页全分辨率")
        XCTAssertNil(cache.fullImage(at: 0), "最旧的 page0 全分辨率被淘汰")
        XCTAssertNotNil(cache.thumbnail(at: 0), "但缩略图必须保留(Trimmed ≠ 释放,图 6)")
        XCTAssertEqual(cache.fullResPixelTotal, 32, "像素账目随降级结清")
    }

    /// 像素阈值单独触发:4 页 × 16px = 64 > 32,只留 2 页
    func testOverPixelBudgetDemotesOldest() throws {
        let cache = PageCache(budget: makeBudget())
        for page in 0..<4 {
            cache.insert(page: page, image: try makeImage())
        }

        XCTAssertEqual(cache.fullResPageCount, 2)
        XCTAssertNil(cache.fullImage(at: 0))
        XCTAssertNil(cache.fullImage(at: 1))
        XCTAssertNotNil(cache.fullImage(at: 2))
        XCTAssertNotNil(cache.fullImage(at: 3))
        XCTAssertEqual(cache.fullResPixelTotal, 32)
    }

    /// LRU 顺序真实生效:触碰过的页不该被先淘汰
    func testTouchProtectsPageFromDemotion() throws {
        let cache = PageCache(budget: makeBudget())
        cache.insert(page: 0, image: try makeImage())
        cache.insert(page: 1, image: try makeImage())

        _ = cache.fullImage(at: 0)          // 触碰 page0 → 它变成最近使用
        cache.insert(page: 2, image: try makeImage())

        XCTAssertNotNil(cache.fullImage(at: 0), "刚触碰的 page0 应存活")
        XCTAssertNil(cache.fullImage(at: 1), "未触碰的 page1 应是受害者")
        XCTAssertNotNil(cache.thumbnail(at: 1))
    }

    // MARK: - 保护规则(单图超预算不产生缓存穿透)

    /// 单图 16px > maxPixels=8:插入后不许被自己淘汰(否则永远缓存未命中)
    func testSingleOversizedImageIsNeverDemoted() throws {
        let cache = PageCache(budget: PageCache.Budget(maxFullPages: 2, maxPixels: 8, maxThumbnails: 3))
        let image = try makeImage(width: 4, height: 4)   // 16px > 8px 预算

        cache.insert(page: 0, image: image)
        XCTAssertEqual(cache.fullResPageCount, 1, "唯一一张全分辨率图受保护规则豁免")
        XCTAssertNotNil(cache.fullImage(at: 0))
    }

    // MARK: - 缩略图 LRU 上限

    /// 缩略图超上限:最旧的缩略图被彻底释放(Evicted,图 6 终态)
    func testThumbnailLRUCap() throws {
        let cache = PageCache(budget: makeBudget())   // maxThumbnails = 3
        for page in 0..<8 {
            cache.insert(page: page, image: try makeImage())
        }

        XCTAssertLessThanOrEqual(cache.thumbnailCount, 3)
        // 最旧的几张缩略图已被彻底释放
        XCTAssertNil(cache.thumbnail(at: 0))
        XCTAssertNil(cache.thumbnail(at: 1))
        XCTAssertNil(cache.thumbnail(at: 2))
        // 最近降级的 page5 缩略图仍在(Trimmed)
        XCTAssertNotNil(cache.thumbnail(at: 5))
        // 最新插入的 page7 仍是全分辨率(未降级,自然无缩略图)
        XCTAssertNotNil(cache.fullImage(at: 7))
    }

    // MARK: - 清空

    func testRemoveAll() throws {
        let cache = PageCache(budget: makeBudget())
        cache.insert(page: 0, image: try makeImage())
        cache.insert(page: 1, image: try makeImage())

        cache.removeAll()
        XCTAssertEqual(cache.fullResPageCount, 0)
        XCTAssertEqual(cache.fullResPixelTotal, 0)
        XCTAssertNil(cache.fullImage(at: 0))
    }
}
