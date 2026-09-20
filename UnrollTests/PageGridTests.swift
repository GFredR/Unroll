// AI-Generated | 可修改
// PageGridTests —— 缩略图网格的算法层(2026-09-18,v1.1 新功能)
// ----------------------------------------------------------------------------
// 测的是 `PageGridBuilder.build` 本身(顺序生成 / 双预算 / 取消 / 异常分流)
// 与 `PageDecoder.decodeThumbnail` / `ThumbnailStore` 这两个零件。
//
// 为什么这些必须测到而不是"跑一次看着对":
//   · **它是唯一会「一趟读完整个包」的浏览功能** —— 顺序性一旦破掉就是 O(n²),
//     而 O(n²) 在 3 页的 fixture 上**看不出来**(实测差异在 150 页才显形);
//   · **双预算**是本项目踩过两次的坑(按个数限制大小可变的资源等于没限制),
//     这两个上界都必须有一条会真的触发它的用例;
//   · **失败分流**决定文案:加密页被算成损坏 → 部分加密包永远报红;
//     解码失败被当成读失败去重开扫描器 → 退化成 O(n²)。
//
// ⚠️ 与 PageStoreTests / IntegrityCheckTests 同款沙盒说明:宿主 App 开着 App Sandbox,
// 测试进程继承,仓库 fixture 可能不可读。不可读时 **skip**,不伪造结论。
import ArchiveKit
import CoreGraphics
import XCTest
@testable import Unroll

final class PageGridTests: XCTestCase {

    /// 仓库内 fixture 目录(与 PageStoreTests / IntegrityCheckTests 同一口径)
    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    private func fixture(_ name: String) throws -> URL {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)—— 算法层本应可独立验证")
        }
        return url
    }

    /// 收集回调产出的缩略图(页码 → 图)。用锁是因为回调发生在调用方线程,
    /// 而 `build` 目前是同步的 —— 留着锁是为了将来挪到后台时用例不用改
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int: CGImage] = [:]
        func add(_ page: Int, _ image: CGImage) {
            lock.lock(); defer { lock.unlock() }
            stored[page] = image
        }
        var pages: [Int] { lock.lock(); defer { lock.unlock() }; return stored.keys.sorted() }
        var images: [CGImage] { lock.lock(); defer { lock.unlock() }; return Array(stored.values) }
    }

    // MARK: - 顺序生成

    /// 明文包:每一页都要有一张缩略图,且 `stop` 必须是 `.finished`。
    /// 断言**逐页齐全**(而不是只看张数)—— 张数对但漏了第 1 页是同一种错
    func testPlainArchiveYieldsOneThumbnailPerPage() throws {
        let document = try ArchiveDocument.open(url: try fixture("plain.cbz"))
        XCTAssertEqual(document.entries.count, 3, "fixture 变了,下面的断言需要一起改")

        let sink = Sink()
        let report = PageGridBuilder.build(document: document,
                                          maxPixel: 256,
                                          onThumbnail: { sink.add($0, $1) })

        XCTAssertEqual(report.stop, .finished)
        XCTAssertEqual(report.generated, 3)
        XCTAssertEqual(sink.pages, [0, 1, 2], "页码必须逐页齐全且升序")
        XCTAssertEqual(report.skippedEncrypted, 0)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(report.coversAllPages, "没有漏页时 coversAllPages 必须为真")
    }

    /// 降采样必须**真的发生**:长边要落到 maxPixel 以内。
    /// 少了 kCGImageSourceThumbnailMaxPixelSize,这里拿到的是全尺寸图 ——
    /// 而那种情况下网格在 200 页的包上会吃掉几个 GB,界面上却"看起来都对"
    func testThumbnailIsActuallyDownsampled() throws {
        let document = try ArchiveDocument.open(url: try fixture("plain.cbz"))

        let sink = Sink()
        _ = PageGridBuilder.build(document: document,
                                  maxPixel: 64,
                                  onThumbnail: { sink.add($0, $1) })

        let images = sink.images
        XCTAssertEqual(images.count, 3)
        for image in images {
            XCTAssertLessThanOrEqual(max(image.width, image.height), 64,
                                     "长边 \(max(image.width, image.height)) 超过了 64 —— 降采样没生效")
        }
        // 源图是 240×320,缩到 64 长边应当是 48×64。断言**缩小了**而不是只看上限:
        // 「原图本来就小于 64」会让上限断言假通过
        XCTAssertTrue(images.contains { $0.height == 64 && $0.width == 48 },
                      "期望 240×320 缩到 48×64,实际:\(images.map { "\($0.width)×\($0.height)" })")
    }

    // MARK: - 双预算:两条都必须真的能触发

    /// 条数预算到顶 → 停下来,并**如实报告** `.budgetReached`(不是 `.finished`)。
    /// 报错成 finished 的后果:界面显示「已生成 2/200」却说不出为什么不再涨,
    /// 用户会一直等
    func testCountBudgetStopsGenerationAndSaysSo() throws {
        let document = try ArchiveDocument.open(url: try fixture("plain.cbz"))

        let sink = Sink()
        let report = PageGridBuilder.build(
            document: document,
            maxPixel: 256,
            budget: PageGridBudget(maxCount: 2, maxPixels: Int.max),
            onThumbnail: { sink.add($0, $1) })

        XCTAssertEqual(report.generated, 2)
        XCTAssertEqual(report.stop, .budgetReached)
        XCTAssertFalse(report.coversAllPages, "提前停下时必须承认「没覆盖全档」")
        XCTAssertEqual(sink.pages, [0, 1], "留下的必须是**前**两页 —— 顺序扫描的语义")
    }

    /// 像素预算到顶。**这条用例存在的理由**:条数与像素是两个独立上界,
    /// 只测条数的话,「像素判据写漏了」不会被任何断言发现 ——
    /// 而 `PageCache` 的缩略图池正是这样悄悄涨到 244 MB 的
    func testPixelBudgetStopsGenerationAtZeroWhenEvenOnePageDoesNotFit() throws {
        let document = try ArchiveDocument.open(url: try fixture("plain.cbz"))

        let sink = Sink()
        let report = PageGridBuilder.build(
            document: document,
            maxPixel: 256,
            budget: PageGridBudget(maxCount: 999, maxPixels: 1),   // 连一张都装不下
            onThumbnail: { sink.add($0, $1) })

        XCTAssertEqual(report.generated, 0, "第一张就超预算时不该收下它")
        XCTAssertEqual(report.stop, .budgetReached)
        XCTAssertTrue(sink.pages.isEmpty, "拒收的图绝不能已经交给调用方")
    }

    // MARK: - 取消

    /// 取消:立刻收工、**不产出任何图**、状态是 `.cancelled`(不是 `.finished`)。
    /// 把取消写成 finished 会让界面说「已生成全部缩略图」——而它一张都没有
    func testCancellationStopsImmediatelyAndIsNotReportedAsFinished() throws {
        let document = try ArchiveDocument.open(url: try fixture("plain.cbz"))

        let sink = Sink()
        let report = PageGridBuilder.build(
            document: document,
            maxPixel: 256,
            isCancelled: { true },
            onThumbnail: { sink.add($0, $1) })

        XCTAssertEqual(report.stop, .cancelled)
        XCTAssertEqual(report.generated, 0)
        XCTAssertTrue(sink.pages.isEmpty)
    }

    // MARK: - 异常分流(这两条直接决定界面文案)

    /// 部分加密包:加密页算**跳过**,不算损坏。
    /// 算成损坏的后果:一个「只是没输密码」的包会被报成「包坏了」——
    /// 用户会去重新下载一个完好的文件
    ///
    /// fixture 结构(见 `make_fixtures.sh`):`partial.cbz` = page1/2 明文 + page3/4 ZipCrypto,
    /// 共 **4** 条 —— 明文 2 张,加密 2 张
    func testEncryptedPagesAreSkippedNotFailed() throws {
        let document = try ArchiveDocument.open(url: try fixture("partial.cbz"))
        XCTAssertEqual(document.entries.count, 4, "fixture 变了,下面的断言需要一起改")

        let sink = Sink()
        let report = PageGridBuilder.build(document: document,
                                          maxPixel: 256,
                                          onThumbnail: { sink.add($0, $1) })

        XCTAssertEqual(report.skippedEncrypted, 2, "4 条里 2 条加密")
        XCTAssertEqual(report.failedCount, 0, "加密页**绝不许**被算成损坏")
        XCTAssertEqual(report.generated, 2)
        XCTAssertEqual(report.stop, .finished)
        XCTAssertTrue(report.coversAllPages, "跳过 + 生成 + 失败 = 总页数 时仍算覆盖全档")
    }

    /// 单页坏掉:如实点名,而且**其余页照常出图**。
    ///
    /// 这条同时钉住一个容易写错的分支:坏页之后**必须重开扫描器**
    /// (数据读失败后流位置不可信,不重开则后面每页都会跟着失败,
    /// 报告变成「除第一页外全坏」这种假结论)
    func testSingleDamagedPageIsNamedAndDoesNotBreakTheRest() throws {
        let document = try ArchiveDocument.open(url: try fixture("damaged-page.cbz"))
        XCTAssertEqual(document.entries.count, 3, "fixture 变了,下面的断言需要一起改")

        let sink = Sink()
        let report = PageGridBuilder.build(document: document,
                                          maxPixel: 256,
                                          onThumbnail: { sink.add($0, $1) })

        XCTAssertEqual(report.failedPages, [1], "坏页是第 2 页(index 1),必须点名")
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.generated, 2, "坏页之外的页必须照常出图(重开扫描器失效的话这里会变成 1 或 0)")
        XCTAssertEqual(report.stop, .finished)
        XCTAssertEqual(sink.pages, [0, 2])
    }

    // MARK: - 零件:降采样解码

    /// 不是图片的字节 → 抛 `ArchiveError.corrupted`(与全分辨率 `decode` 同一判据)。
    /// 网格据此把这一页记成 failed 而不是崩掉
    func testDecodeThumbnailThrowsCorruptedOnGarbage() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertThrowsError(try PageDecoder.decodeThumbnail(garbage, maxPixel: 64)) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupted)
        }
    }

    // MARK: - 零件:缩略图池

    /// 双账本要一起记:同页重存必须**先结清旧账**再记新账,否则像素总额只涨不减。
    /// 这正是「账上还有、实际已换掉」那类不会被任何断言发现的泄漏
    func testThumbnailStoreReplacesAndKeepsPixelAccountsBalanced() throws {
        let store = ThumbnailStore()
        let big = try XCTUnwrap(Self.solidImage(width: 40, height: 30))
        let small = try XCTUnwrap(Self.solidImage(width: 10, height: 10))

        store.store(big, at: 3)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.pixels, 40 * 30)

        store.store(small, at: 3)     // 同页重存
        XCTAssertEqual(store.count, 1, "同页重存不该多出一条")
        XCTAssertEqual(store.pixels, 10 * 10, "旧账没结清 —— 像素总额只涨不减")

        store.removeAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.pixels, 0)
    }

    // MARK: - 工具

    /// 造一张纯色图(单测用,不碰磁盘)
    private static func solidImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
