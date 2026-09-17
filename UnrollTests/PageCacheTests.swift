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

    /// 小预算(页数 2 / 像素 32 / 缩略图 3),测试图统一 4×4 = 16 像素。
    ///
    /// 缩略图**像素**预算给得很宽(1000):这一组用例验证的是个数阈值与 LRU 顺序,
    /// 不该被新加的像素阈值顺带影响 —— 两条阈值各有专属用例,混在一起就分不清
    /// 是哪条在起作用(2026-09-17 补像素阈值时特意这么分开)
    private func makeBudget() -> PageCache.Budget {
        PageCache.Budget(maxFullPages: 2, maxPixels: 32,
                         maxThumbnails: 3, maxThumbnailPixels: 1000)
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
        let cache = PageCache(budget: PageCache.Budget(maxFullPages: 2, maxPixels: 8,
                                                       maxThumbnails: 3,
                                                       maxThumbnailPixels: 1000))
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

    // MARK: - 缩略图像素预算(2026-09-17 补的缺口)

    /// **个数没超、像素超了** —— 这正是原先漏掉的那条路径:
    /// 24 张缩略图的个数上限看着很稳妥,但每张的像素随页面长宽比浮动,
    /// 大页场景下个数还没到上限,内存早就上去了
    func testThumbnailPixelBudgetEvictsEvenWhenCountIsUnderLimit() throws {
        // 个数放宽到 10,像素只给 32(测试缩略图 16px/张 → 最多 2 张)
        let cache = PageCache(budget: PageCache.Budget(maxFullPages: 1, maxPixels: 16,
                                                       maxThumbnails: 10,
                                                       maxThumbnailPixels: 32))
        for page in 0..<8 {
            cache.insert(page: page, image: try makeImage())
        }

        XCTAssertLessThanOrEqual(cache.thumbnailPixelTotal, 32,
                                 "缩略图像素总额必须被预算卡住(个数远未到上限)")
        XCTAssertLessThanOrEqual(cache.thumbnailCount, 2)
        XCTAssertNil(cache.thumbnail(at: 0), "最旧的缩略图先被释放(LRU)")
        XCTAssertNotNil(cache.thumbnail(at: 6), "最新的降级页仍有垫图")
    }

    /// 像素账目必须精确结清:降级时加上,释放时减掉,换书时归零 ——
    /// 账目一漂,预算就成了摆设(而它不会报错,只会算错)
    func testThumbnailPixelAccountStaysExact() throws {
        let cache = PageCache(budget: PageCache.Budget(maxFullPages: 1, maxPixels: 16,
                                                       maxThumbnails: 10,
                                                       maxThumbnailPixels: 1000))
        for page in 0..<3 {
            cache.insert(page: page, image: try makeImage())   // 每张 4×4 = 16px
        }
        // 页数阈值 1 → page0/page1 各降一张 16px 缩略图
        XCTAssertEqual(cache.thumbnailCount, 2)
        XCTAssertEqual(cache.thumbnailPixelTotal, 32, "两张 16px 缩略图")

        cache.removeAll()
        XCTAssertEqual(cache.thumbnailPixelTotal, 0, "清空后像素账必须归零")
        XCTAssertEqual(cache.fullResPixelTotal, 0)
    }

    /// **页数增长 ≠ 内存增长**:这是「压缩包里图片很多」时用户真正依赖的保证。
    /// 200 页灌进小预算缓存,内存四项指标全部贴着预算,不随页数漂移
    func testMemoryStaysBoundedAsPageCountGrows() throws {
        let cache = PageCache(budget: makeBudget())   // 2 页 / 32px / 3 张 / 1000px

        for page in 0..<200 {
            cache.insert(page: page, image: try makeImage())
        }

        XCTAssertLessThanOrEqual(cache.fullResPageCount, 2)
        XCTAssertLessThanOrEqual(cache.fullResPixelTotal, 32)
        XCTAssertLessThanOrEqual(cache.thumbnailCount, 3)
        XCTAssertLessThanOrEqual(cache.thumbnailPixelTotal, 1000)
        // 条目表也不该无限留:缩略图被释放的页会整个移除(Evicted)
        XCTAssertLessThanOrEqual(cache.entriesCount, cache.thumbnailCount + cache.fullResPageCount,
                                 "每个留存条目都至少持有一张图,不该有纯占位的空条目")
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
