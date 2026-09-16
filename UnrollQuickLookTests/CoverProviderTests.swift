// AI-Generated | 可修改
// CoverProviderTests —— QuickLook 扩展「读首页」逻辑的单测(设计文档 §2.4)
// ----------------------------------------------------------------------------
// 为什么单开一个 target:
//   QuickLook 的 appex 天然难以自动验证 —— 它由系统(quicklookd)按需拉起,
//   无头环境里连 `pluginkit -m` 都可能被拒(2026-09-16 实测:PKDiscovery 未授权),
//   「扩展到底有没有被系统调用」在沙箱内无法判定。
//   但扩展里真正容易写错的不是管道,而是「打开归档 → 取首页 → 降采样」这段
//   决策逻辑 —— 它是纯的,把 Shared/ 的源码编进本 target 就能直接测。
//
// 于是 QuickLook 这一块的验证边界被切成两半(诚实记录,不含糊):
//   · 决策逻辑(本文件)—— 明文/加密/损坏/无图/缺文件/降采样上限,逐条锁死
//   · appex 管道(Info.plist 声明 / 嵌套签名 / 系统路由)—— 由 build-app.sh 的
//     硬校验 + Scripts/verify-quicklook.sh 的真机复核兜住
//
// fixture 复用 ArchiveKit/Tests/Fixtures(#filePath 回溯源码树,不入库第二份)。
import CoreGraphics
import Foundation
import XCTest

final class CoverProviderTests: XCTestCase {

    /// fixture 目录:…/ArchiveKit/Tests/Fixtures
    private enum Fixtures {
        static let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/UnrollQuickLookTests
            .deletingLastPathComponent()      // …/Unroll
            .appendingPathComponent("ArchiveKit/Tests/Fixtures")

        static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    }

    // MARK: - 断言辅助

    /// 取出 .page 的两项数据;非 .page 直接失败并报出实际分支
    private func page(_ outcome: CoverOutcome,
                      file: StaticString = #filePath, line: UInt = #line) -> (CGImage, Int)? {
        guard case .page(let pageImage, let total) = outcome else {
            XCTFail("期望 .page,实际 \(outcome)", file: file, line: line)
            return nil
        }
        return (pageImage.image, total)
    }

    // MARK: - 明文归档:取到首页 + 页数

    /// plain.cbz(3 页):首页可读,且 total 是排序后的图片条目数(不含 note.txt)
    func testPlainCbzYieldsFirstPage() throws {
        let outcome = CoverProvider.firstPage(at: Fixtures.url("plain.cbz"),
                                             maxPixel: CoverProvider.thumbnailPixel)
        guard let (image, total) = page(outcome) else { return }
        XCTAssertEqual(total, 3, "note.txt 不该被算进页数")
        // 源图 240×320,maxPixel 1024 远大于它 → 不放大,保持原尺寸
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 320)
    }

    /// 取的是**排序后**的第 0 页,而且那条字节链(data(at:) → ImageIO 解码)确实
    /// 拿到了对的图。plain.cbz 物理写入顺序是 page10,page2,page1 —— 若扩展漏了
    /// 自然排序,这里会拿到 page10。降采样后没法逐字节比对,改用**角像素底色**:
    /// page1 红底(255,0,0) / page10 洋红底(255,0,255),蓝通道足以区分
    func testPlainCbzTakesFirstPageBySortedOrder() throws {
        let outcome = CoverProvider.firstPage(at: Fixtures.url("plain.cbz"), maxPixel: 64)
        guard let (first, _) = page(outcome) else { return }

        let page1 = try XCTUnwrap(CoverProvider.downsample(try srcData("page1.png"), maxPixel: 64))
        let page10 = try XCTUnwrap(CoverProvider.downsample(try srcData("page10.png"), maxPixel: 64))

        XCTAssertEqual(cornerPixel(first), cornerPixel(page1),
                       "首页应是排序后的 page1")
        XCTAssertNotEqual(cornerPixel(first), cornerPixel(page10),
                          "拿到了 page10 —— 说明排序没生效,或 data(at:) 定位错了条目")
    }

    /// cbt(tar)也走同一条路径 —— P0 四格式里的最后一个
    func testPlainCbtYieldsFirstPage() throws {
        let outcome = CoverProvider.firstPage(at: Fixtures.url("plain.cbt"), maxPixel: 256)
        guard let (image, total) = page(outcome) else { return }
        XCTAssertEqual(total, 3)
        XCTAssertGreaterThan(image.width, 0)
    }

    /// 部分加密 zip:open 成功(.partial),首页明文 → 仍应出封面。
    /// 「部分页占位卡片」是 App 内的策略,缩略图侧只认首页能不能读
    func testPartiallyEncryptedArchiveStillYieldsFirstPage() throws {
        let outcome = CoverProvider.firstPage(at: Fixtures.url("partial.cbz"), maxPixel: 256)
        guard let (_, total) = page(outcome) else { return }
        XCTAssertEqual(total, 4)
    }

    // MARK: - 降采样(缩略图性能的前提)

    /// maxPixel 是长边上限:240×320 + maxPixel 120 → 90×120(等比,不裁切)
    func testDownsampleCapsLongSideAndKeepsAspect() throws {
        let outcome = CoverProvider.firstPage(at: Fixtures.url("plain.cbz"), maxPixel: 120)
        guard let (image, _) = page(outcome) else { return }
        XCTAssertEqual(max(image.width, image.height), 120)
        XCTAssertEqual(image.width, 90)
        XCTAssertEqual(image.height, 120)
    }

    /// 大上限不放大:确认 downsample 只缩不放,避免小图被插值糊掉
    func testDownsampleDoesNotUpscale() throws {
        let image = try XCTUnwrap(CoverProvider.downsample(try srcData("page1.png"), maxPixel: 4096))
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 320)
    }

    /// 非图片字节:返回 nil 而不是崩 —— downsample 是扩展里唯一直接吃文件字节的地方
    func testDownsampleRejectsNonImageData() {
        XCTAssertNil(CoverProvider.downsample(Data("not an image".utf8), maxPixel: 256))
        XCTAssertNil(CoverProvider.downsample(Data(), maxPixel: 256))
    }

    // MARK: - 失败三态:一律不抛,由调用方决定呈现

    /// 无图片条目 → .unreadable(ArchiveError.noImages)
    func testNoImagesArchiveIsUnreadable() {
        let outcome = CoverProvider.firstPage(at: Fixtures.url("no-images.cbz"), maxPixel: 256)
        XCTAssertTrue(isUnreadable(outcome))
    }

    /// 损坏 / 非归档 / 空包 / 文件不存在 → 全部 .unreadable,且不抛不崩
    func testBrokenArchivesAreUnreadable() {
        for name in ["corrupted.cbz", "empty.cbz", "does-not-exist.cbz"] {
            let outcome = CoverProvider.firstPage(at: Fixtures.url(name), maxPixel: 256)
            XCTAssertTrue(isUnreadable(outcome), "\(name) 应为 .unreadable,实际 \(outcome)")
        }
    }

    /// 加密四态里三种加密都必须映射到 .encrypted,**不能**吞成 .unreadable ——
    /// 缩略图侧要靠它决定「宁可退默认图标,也不挂误导性占位图」;
    /// 预览侧要靠它显示「已加密」而不是「文件损坏」
    func testAllEncryptedVariantsMapToEncrypted() {
        // ZIP + ZipCrypto / ZIP + AES-256 / 7z 内容加密 / 7z 头部加密
        for name in ["encrypted-zip.cbz", "encrypted-zip-aes.cbz",
                     "encrypted-content.cb7", "encrypted-header.cb7"] {
            let outcome = CoverProvider.firstPage(at: Fixtures.url(name), maxPixel: 256)
            guard case .encrypted = outcome else {
                XCTFail("\(name) 应为 .encrypted,实际 \(outcome)")
                continue
            }
        }
    }

    // MARK: - 尺寸常量(两个扩展各用一档,别写反)

    /// 缩略图档禁止超过预览档:写反会导致 Finder 缩略图比预览还大(白耗内存)
    func testPixelBudgetsAreOrdered() {
        XCTAssertLessThanOrEqual(CoverProvider.thumbnailPixel, CoverProvider.previewPixel)
        XCTAssertGreaterThanOrEqual(CoverProvider.thumbnailPixel, 512,
                                    "Finder 图标最大 512pt,@1x 也不能低于 512")
    }

    // MARK: - 私有工具

    private func isUnreadable(_ outcome: CoverOutcome) -> Bool {
        if case .unreadable = outcome { return true }
        return false
    }

    /// 左上角像素 = 页面底色(fixture 是纯色底 + 白框 + 文字,四角都是底色)。
    /// 用 .none 插值把小图直接采出来,避免混合出中间色。
    /// 返回数组而非元组:元组不满足 Equatable,XCTAssertEqual 用不了
    private func cornerPixel(_ image: CGImage) -> [UInt8]? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                 bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return [pixel[0], pixel[1], pixel[2]]
    }

    private func srcData(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.dir.appendingPathComponent("src/\(name)"))
    }
}
