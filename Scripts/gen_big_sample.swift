// ============================================================================
// gen_big_sample.swift —— 合成大样本生成器（M2 末手工验收用，测试文档 §7 缺口）
// ----------------------------------------------------------------------------
// 解决的问题：手头没有 200 页 / 500MB 量级的真实漫画包，无法做「连翻无卡顿 /
// 内存 < 1.5GB / 翻页 < 100ms」的 M2 验收。本工具程序化画出每一页（渐变底 +
// 网点纹理 + 大号页码水印，JPEG q0.7 压不没），再打包成 cbz。
//   · 合成样本反而可控：页数 / 像素尺寸 / 总体积都是已知量，验收可复现
//   · 页码水印画在画面里，翻页时肉眼可直接核对「没有跳页/花页」
//
// 编译即用（零第三方依赖，只链系统框架）：
//   xcrun --sdk macosx swiftc -O -o gen_big_sample gen_big_sample.swift
//
// 用法：
//   ./gen_big_sample --pages 200 --width 2000 --height 3000 --out 样本.cbz
//     [--quality 0.7] [--tmp /tmp/xxx]     （tmp 缺省用 mkdtemp，结束自动清理）
//
// 体积估算：2000×3000 q0.7 ≈ 1.4MB/页 → 200 页 ≈ 280MB；想要 ~500MB 把
//   --width 2600 --height 3900（或调低 --quality 反向压不没）。
//
// 注意：本工具只写用户显式指定的输出路径；临时页全部落在 --tmp 目录，
// 结束即删。不入 git（TestSamples/ 已在 .gitignore）。
// ============================================================================

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ---- 参数解析 ---------------------------------------------------------------
var pages = 200
var width = 2000
var height = 3000
var quality: Double = 0.7
var outURL: URL?
var tmpOverride: URL?

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    func value(_ name: String) -> String? {
        guard arg == "--\(name)" else { return nil }
        defer { if !args.isEmpty { args.removeFirst() } }
        return args.first
    }
    switch arg {
    case "--pages":   pages = Int(value("pages") ?? "") ?? pages
    case "--width":   width = Int(value("width") ?? "") ?? width
    case "--height":  height = Int(value("height") ?? "") ?? height
    case "--quality": quality = Double(value("quality") ?? "") ?? quality
    case "--tmp":     tmpOverride = value("tmp").map { URL(fileURLWithPath: $0) }
    case "--out":     outURL = value("out").map { URL(fileURLWithPath: $0) }
    default:
        FileHandle.standardError.write("未知参数: \(arg)\n用法见文件头注释\n".data(using: .utf8)!)
        exit(2)
    }
}
guard let outURL, pages > 0, width > 0, height > 0 else {
    FileHandle.standardError.write("必须给 --out，且 pages/width/height > 0\n".data(using: .utf8)!)
    exit(2)
}

// ---- 临时目录 ---------------------------------------------------------------
let tmpDir: URL
if let tmpOverride {
    try? FileManager.default.createDirectory(at: tmpOverride, withIntermediateDirectories: true)
    tmpDir = tmpOverride
} else {
    tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("unroll-sample-\(UUID().uuidString.prefix(8))")
    try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
}
// 只清理自己创建的临时目录；用户指定 --tmp 时保留，便于人工检查单页
defer { if tmpOverride == nil { try? FileManager.default.removeItem(at: tmpDir) } }

// ---- 画一页：渐变底 + 网点纹理 + 页码水印 -----------------------------------
func renderPage(number n: Int, total: Int) -> CGImage {
    let w = width, h = height
    let ctx = CGContext(data: nil, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // 1) 对角渐变底：色相随页号轮转（页与页画面明显不同，防「翻页假象」）
    let hue = CGFloat(n % 12) / 12.0
    let c0 = NSColor(hue: hue, saturation: 0.55, brightness: 0.92, alpha: 1).cgColor
    let c1 = NSColor(hue: (hue + 0.08), saturation: 0.35, brightness: 0.75, alpha: 1).cgColor
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [c0, c1] as CFArray,
                                      locations: [0, 1])!,
                           start: .zero, end: CGPoint(x: w, y: h), options: [])

    // 2) 网点纹理：错位圆点阵（JPEG 压不没的主力；密度随页号变化）
    let dot = 14 + n % 7
    ctx.setFillColor(NSColor(white: 0, alpha: 0.10).cgColor)
    for row in stride(from: -dot, to: h + dot, by: dot * 2) {
        let offset = (row / (dot * 2)) % 2 == 0 ? 0 : dot
        for col in stride(from: -dot + offset, to: w + dot, by: dot * 2) {
            ctx.fillEllipse(in: CGRect(x: col, y: row, width: dot, height: dot))
        }
    }

    // 3) 高频颗粒：12000 个随机明暗小块（JPEG 的天敌，体积可放大的主力）
    var seed = UInt64(truncatingIfNeeded: n) &* 2654435761
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xFFFF) / 65535.0
    }
    for _ in 0..<12000 {
        let size = 1 + rnd() * 5
        let alpha = 0.08 + rnd() * 0.42
        ctx.setFillColor(NSColor(white: rnd() > 0.5 ? 0 : 1, alpha: alpha).cgColor)
        ctx.fill(CGRect(x: rnd() * CGFloat(w), y: rnd() * CGFloat(h),
                        width: size, height: size))
    }

    // 4) 大页码水印（翻页时肉眼核对用）+ 页脚进度条
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: CGFloat(h) / 8, weight: .bold),
        .foregroundColor: NSColor(white: 1, alpha: 0.85),
    ]
    let text = NSAttributedString(string: "\(n)", attributes: attrs)
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2,
                               y: (CGFloat(h) - bounds.height) / 2)
    CTLineDraw(line, ctx)

    let barH = max(6, h / 300)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(barH)))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w) * CGFloat(n) / CGFloat(total), height: CGFloat(barH)))

    return ctx.makeImage()!
}

// ---- 逐页出 JPEG -------------------------------------------------------------
let started = Date()
var totalBytes = 0
for n in 1...pages {
    let image = renderPage(number: n, total: pages)
    let fileURL = tmpDir.appendingPathComponent(String(format: "p%04d.jpg", n))
    let dest = CGImageDestinationCreateWithURL(fileURL as CFURL,
                                               UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [
        kCGImageDestinationLossyCompressionQuality: quality,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("第 \(n) 页 JPEG 编码失败\n".data(using: .utf8)!)
        exit(1)
    }
    totalBytes += (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    if n % 20 == 0 || n == pages {
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(String(format: "\r%d/%d 页 (%.0fs, %.0fMB)", n, pages, elapsed, Double(totalBytes) / 1_048_576).data(using: .utf8)!)
    }
}
FileHandle.standardError.write("\n".data(using: .utf8)!)

// ---- 打包 cbz（zip：store 已压缩的 JPEG 反而更小更快） ------------------------
if FileManager.default.fileExists(atPath: outURL.path) {
    try? FileManager.default.removeItem(at: outURL)
}
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zip.currentDirectoryURL = tmpDir
zip.arguments = ["-q", "-X", "-0", outURL.path] + (1...pages).map { String(format: "p%04d.jpg", $0) }
try zip.run()
zip.waitUntilExit()
guard zip.terminationStatus == 0 else {
    FileHandle.standardError.write("zip 失败，退出码 \(zip.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}

let outSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
print("完成: \(outURL.path)")
print(String(format: "  %d 页 %dx%d, 页面合计 %.0fMB, cbz %.0fMB, 耗时 %.0fs",
             pages, width, height,
             Double(totalBytes) / 1_048_576, Double(outSize) / 1_048_576,
             Date().timeIntervalSince(started)))
