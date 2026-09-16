// AI-Generated | 可修改
// PageSavePanelTests —— 「另存当前页」的写盘链路(2026-09-16,v2)
// ----------------------------------------------------------------------------
// 面板本身(NSSavePanel)没法自动化,但**面板之外**的链路可以:扩展名 → 格式 → 编码
// → 原子写盘。全部落在临时目录里,用例结束即删(不留测试垃圾)。
import CoreGraphics
import ImageIO
import XCTest
@testable import Unroll

@MainActor
final class PageSavePanelTests: XCTestCase {

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 90,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: sRGB,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        return try XCTUnwrap(context.makeImage())
    }

    /// 每次用例一个独立临时目录,结束即删
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-savepanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 按扩展名选格式:.png 出 PNG,.jpg / .jpeg 出 JPEG(用户可能手打 .jpeg)
    func testWritePicksFormatFromFileExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage()

        let png = directory.appendingPathComponent("page.png")
        XCTAssertTrue(PageSavePanel.write(image: image, to: png))
        XCTAssertEqual(Array(try Data(contentsOf: png).prefix(8)),
                       [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let jpg = directory.appendingPathComponent("page.jpg")
        XCTAssertTrue(PageSavePanel.write(image: image, to: jpg))
        XCTAssertEqual(Array(try Data(contentsOf: jpg).prefix(3)), [0xFF, 0xD8, 0xFF])

        let jpeg = directory.appendingPathComponent("page.jpeg")
        XCTAssertTrue(PageSavePanel.write(image: image, to: jpeg))
        XCTAssertEqual(Array(try Data(contentsOf: jpeg).prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    /// 认不出来的扩展名(手打成 .tiff)按 PNG 处理 —— 有确定行为,不产生"未知格式"的空白
    func testWriteFallsBackToPNGForUnknownExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("page.tiff")
        XCTAssertTrue(PageSavePanel.write(image: try makeImage(), to: url))
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(8)),
                       [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "内容仍是 PNG")
    }

    /// 写不进去 → false(调用方据此弹「保存失败」,不留"点了没反应")
    func testWriteReportsFailureForUnwritableLocation() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/page.png")
        XCTAssertFalse(PageSavePanel.write(image: try makeImage(), to: missing))
    }

    /// 写出的图能被重新解码成同样尺寸(整条链路走通,不只是文件头对)
    func testWrittenPNGDecodesBackToSameSize() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = try makeImage()
        let url = directory.appendingPathComponent("page.png")
        XCTAssertTrue(PageSavePanel.write(image: image, to: url))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }
}
