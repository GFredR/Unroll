// AI-Generated | 可修改
// PageExportTests —— 另存当前页的合成 / 编码 / 命名(2026-09-16,v2)
// ----------------------------------------------------------------------------
// 这层刻意做成纯函数就是为了能这样测:造两张纯色图,合完看左右顺序对不对。
// 口径错误(左右反了 / 白底没铺 / 矮页没居中)在界面上都只表现为"图有点怪",
// 肉眼很容易忽略,断言必须落在像素上。
//
// ⚠️ 本文件踩过并已改正的一个坑(别重犯):**不要对颜色做绝对分量断言**。
// `CGColor(red:green:blue:alpha:)` 造出来的是通用 RGB,填进设备 RGB 上下文会过
// 一次色彩空间转换 —— 实测"纯红"读回来是 (255,38,0)、"纯绿"是 (0,249,0)。
// 第一版断言写 (255,0,0) 于是 5 条用例全红,一度被误读成"左右画反了"
// (实际布局一直是对的,只是值不"纯")。断言现在落在**哪个通道占优**上:
// 那才是在测布局,而不是在测色彩管理。
import CoreGraphics
import ImageIO
import XCTest
@testable import Unroll

final class PageExportTests: XCTestCase {

    // MARK: - 造图 / 取样工具

    /// 造图用 sRGB(与 ImageIO 解码出来的页面同族,比 DeviceRGB 更贴近生产)
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 纯色图(测试用的"页面")
    private func solid(width: Int, height: Int,
                       r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: sRGB,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: sRGB, components: [r, g, b, 1])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func red() throws -> CGImage { try solid(width: 240, height: 320, r: 1, g: 0, b: 0) }
    private func green() throws -> CGImage { try solid(width: 200, height: 320, r: 0, g: 1, b: 0) }

    /// 整图重绘成 RGBA 缓冲后直接读字节 —— 下标就是像素下标,没有采样歧义
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// 取归一化坐标处的颜色(0,0 = 左上)。
    /// 断言都用「中间行」或上下对称的位置,故不依赖行的存储朝向
    private func components(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> (Int, Int, Int) {
        let width = image.width
        let bytes = try rgba(image)
        let column = min(max(Int(CGFloat(width) * x), 0), width - 1)
        let row = min(max(Int(CGFloat(image.height) * y), 0), image.height - 1)
        let index = (row * width + column) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// 测试"墨水"色:红 / 绿 / 白(见文件头:不做绝对分量断言)
    private enum Ink: String {
        case red, green, white
    }

    private func ink(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> Ink {
        let (r, g, b) = try components(image, x: x, y: y)
        if r > 200, g > 200, b > 200 { return .white }
        return r > g ? .red : .green
    }

    private func assertInk(_ image: CGImage, x: CGFloat, y: CGFloat, is expected: Ink,
                           _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try ink(image, x: x, y: y)
        let raw = try components(image, x: x, y: y)
        XCTAssertEqual(actual, expected,
                       "该处是 \(actual.rawValue) rgb\(raw),期望 \(expected.rawValue)。\(message)",
                       file: file, line: line)
    }

    // MARK: - 摊图合成

    /// 单页:原样返回(连对象都不该换 —— 免得白走一趟重绘)
    func testComposeWithoutSecondaryReturnsPrimaryAsIs() throws {
        let primary = try red()
        let result = PageExport.compose(primary: primary, secondary: nil, rightToLeft: false)
        XCTAssertEqual(result.width, primary.width)
        XCTAssertEqual(result.height, primary.height)
    }

    /// 左开:第一页在左,第二页在右(与屏幕上看到的一致)
    func testComposeLeftToRightKeepsPrimaryOnTheLeft() throws {
        let result = PageExport.compose(primary: try red(), secondary: try green(), rightToLeft: false)
        XCTAssertEqual(result.width, 240 + 200)
        XCTAssertEqual(result.height, 320)
        try assertInk(result, x: 0.25, y: 0.5, is: .red, "左半应为第一页(红)")
        try assertInk(result, x: 0.85, y: 0.5, is: .green, "右半应为第二页(绿)")
    }

    /// 右开(日漫):第二面跑到底下,合成顺序随之反转 —— 导出的图和看到的必须一样
    func testComposeRightToLeftPutsSecondaryOnTheLeft() throws {
        let result = PageExport.compose(primary: try red(), secondary: try green(), rightToLeft: true)
        XCTAssertEqual(result.width, 240 + 200)
        try assertInk(result, x: 0.25, y: 0.5, is: .green, "右开时第二面应在左")
        try assertInk(result, x: 0.85, y: 0.5, is: .red, "右开时第一面应在右")
    }

    /// 两页不等高:画布取较高者,矮页垂直居中,空白处是白底(不是黑边、不是拉伸)
    func testComposeCentersShorterPageOnWhiteBackground() throws {
        let tall = try solid(width: 240, height: 320, r: 1, g: 0, b: 0)
        let short = try solid(width: 200, height: 160, r: 0, g: 1, b: 0)
        let result = PageExport.compose(primary: tall, secondary: short, rightToLeft: false)
        XCTAssertEqual(result.height, 320)
        try assertInk(result, x: 0.85, y: 0.5, is: .green, "矮页应落在中间")
        try assertInk(result, x: 0.85, y: 0.05, is: .white, "上方的补白应为白色")
        try assertInk(result, x: 0.85, y: 0.95, is: .white, "下方的补白应为白色")
    }

    /// 画布沿用源页色彩空间 —— 用 DeviceRGB 会平白多一次色彩解释(导出图色偏的隐患)
    func testComposeKeepsSourceColorSpace() throws {
        let primary = try red()
        let result = PageExport.compose(primary: primary, secondary: try green(), rightToLeft: false)
        XCTAssertEqual(result.colorSpace?.name as String?, primary.colorSpace?.name as String?)
    }

    // MARK: - 编码

    func testEncodePNGProducesPNGMagic() throws {
        let data = try XCTUnwrap(PageExport.encode(try red(), as: .png))
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(data.prefix(8)), magic)
    }

    func testEncodeJPEGProducesJPEGMagic() throws {
        let data = try XCTUnwrap(PageExport.encode(try red(), as: .jpeg))
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    /// 编码后的 PNG 能被重新解出同样尺寸(不是只对了个文件头)
    func testEncodedPNGRoundTripsToSamePixelSize() throws {
        let image = PageExport.compose(primary: try red(), secondary: try green(), rightToLeft: false)
        let data = try XCTUnwrap(PageExport.encode(image, as: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    // MARK: - 建议文件名

    /// 归档名 + 补零页号;扩展名跟格式走(JPEG 用 .jpg,不是 .jpeg)
    func testSuggestedFileNameUsesBaseNameAndPaddedPage() {
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "My Comic.cbz", page: 2,
                                                    pageCount: 4, format: .png),
                       "My Comic-p003.png")
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "vol01.cbr", page: 0,
                                                    pageCount: 200, format: .jpeg),
                       "vol01-p001.jpg")
    }

    /// 页数过千时补零位宽跟着涨(排序友好:文件名排出来就是阅读顺序)
    func testSuggestedFileNameWidensPaddingForLargeArchives() {
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "big.cbz", page: 0,
                                                    pageCount: 1200, format: .png),
                       "big-p0001.png")
    }

    /// 只掐掉最后一段扩展名,名字里的点保留原样
    func testSuggestedFileNameStripsOnlyTheLastExtension() {
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "v1.2 (final).cbz", page: 9,
                                                    pageCount: 10, format: .png),
                       "v1.2 (final)-p010.png")
    }

    /// 没有文档名(空态不应走到这里,但要有个确定行为):退化成 page-pNNN
    func testSuggestedFileNameFallsBackWithoutDocumentName() {
        XCTAssertEqual(PageExport.suggestedFileName(documentName: nil, page: 0,
                                                    pageCount: 4, format: .png),
                       "page-p001.png")
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "", page: 0,
                                                    pageCount: 4, format: .png),
                       "page-p001.png")
    }

    /// 批量导出走的是**同一个**命名实现 —— 只换扩展名,补零规则不许有两份
    /// (两条链各写一遍的话,「总页数从 999 变 1000 时补零跳档」只会在一侧被修)。
    /// 所以这里两条各写一遍**字面量**,而不是拿一个去改另一个 ——
    /// 互相推导的断言在两边一起写错时照样绿
    func testBulkNamingReusesTheSamePaddedRuleAsSave() {
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "My Comic.cbz", page: 2,
                                                    pageCount: 4, format: .png),
                       "My Comic-p003.png")
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "My Comic.cbz", page: 2,
                                                    pageCount: 4, fileExtension: "webp"),
                       "My Comic-p003.webp")
        XCTAssertEqual(PageExport.suggestedFileName(documentName: "big.cbr", page: 0,
                                                    pageCount: 1200, fileExtension: "bin"),
                       "big-p0001.bin", "补零位宽跟总页数走,与 ⌘S 同一份实现")
    }

    // MARK: - 批量导出的扩展名(2026-09-21)

    /// 判据一:**条目原名里的扩展名优先** —— 它带着打包者的原始信息。
    /// 大小写要归一到小写(访达不认 `.PNG`,但 `UTType` 认;统一小写两边都对)
    func testFileExtensionPrefersTheOriginalEntryExtension() {
        let png = Self.pngMagic + Data(repeating: 0, count: 32)
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "vol01/page1.PNG", data: png),
                       "png")
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "a/b/cover.jpeg", data: png),
                       "jpeg", "原名说是 jpeg 就落 jpeg,不按魔数改口")
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "p.jpg", data: png),
                       "jpg")
    }

    /// 无扩展名的条目(老式扫描包的 `vol01/001`):**靠魔数救回来**。
    /// 阅读时 ImageIO 按内容识别、根本不看扩展名,所以这些页照样能显示;
    /// 导出时少了这一步,它们会全部落成 `.bin`,在访达里双击打不开
    func testFileExtensionSniffsWhenEntryHasNoExtension() {
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "vol01/001",
                                                      data: Self.pngMagic), "png")
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "vol01/002",
                                                      data: Self.jpegMagic), "jpg")
    }

    /// 含数字的"扩展名"不是扩展名 —— `ch01.p01` 的 `p01` 是名字的一部分。
    /// 拿它落盘会得到一堆系统不认识的文件(`.p01` 没有关联的图片查看器)
    func testFileExtensionRejectsDigitBearingExtension() {
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "ch01.p01",
                                                      data: Self.pngMagic),
                       "png", "p01 含数字 → 当没扩展名,按魔数嗅")
    }

    /// 兜底是 `.bin` 而**不是**猜一个 `.jpg`:包里混进被当成页的非图片
    /// (`vol01/notes` 这种纯文本)时,如实标成未知 ——
    /// 谎报成 jpg 会让用户以为"导出的图坏了"
    func testFileExtensionFallsBackToBinForUnknownBytes() {
        let text = Data("a note, 13 B".utf8)
        XCTAssertEqual(PageExport.exportFileExtension(forEntryPath: "vol01/notes", data: text),
                       "bin")
        XCTAssertNil(PageExport.sniffedExtension(text), "认不出来就不认")
        XCTAssertNil(PageExport.sniffedExtension(Data([0x89, 0x50, 0x4E])), "不足 4 字节不做判断")
        XCTAssertNil(PageExport.sniffedExtension(Data()))
    }

    /// 嗅探表覆盖的是**系统必然能显示**的那几种;表外的一律 nil(不猜)。
    /// 这一条同时是「以后有人往 `isListedImage` 里加格式」的提醒:
    /// 阅览支持新格式时,这里也跟着该加一条,否则导出会退化成 `.bin`
    func testSniffedExtensionRecognisesSystemDisplayableFormats() {
        let cases: [(String, Data)] = [
            ("png",  Self.pngMagic),
            ("jpg",  Self.jpegMagic),
            ("gif",  Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
            ("bmp",  Data([0x42, 0x4D, 0x00, 0x00])),
            ("tiff", Data([0x49, 0x49, 0x2A, 0x00])),
            ("tiff", Data([0x4D, 0x4D, 0x00, 0x2A])),
            ("webp", Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)),
            ("avif", Self.isoBMFF("avif")),
            ("heic", Self.isoBMFF("heic")),
            ("heif", Self.isoBMFF("mif1")),
        ]
        for (expected, data) in cases {
            XCTAssertEqual(PageExport.sniffedExtension(data), expected,
                           "\(expected) 魔数没被认出来")
        }
        XCTAssertNil(PageExport.sniffedExtension(Self.isoBMFF("mp42")),
                     "MP4 也是 ISO-BMFF,但不是图片 —— 不许蹭成 heic")
    }

    // MARK: - 魔数样本

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let jpegMagic = Data([0xFF, 0xD8, 0xFF, 0xE0])

    /// ISO-BMFF 头:`00 00 00 18` + `ftyp` + 4 字节兼容品牌
    private static func isoBMFF(_ brand: String) -> Data {
        Data([0x00, 0x00, 0x00, 0x18]) + Data("ftyp".utf8) + Data(brand.utf8)
    }
}
