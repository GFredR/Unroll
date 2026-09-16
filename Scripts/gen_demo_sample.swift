#!/usr/bin/env swift
// AI-Generated | 可修改
// gen_demo_sample.swift —— 生成「演示用归档样本」(README 截图 / 演示 GIF 的素材)
// ============================================================================
// 为什么不用真实漫画:版权。这里用 CoreGraphics 画抽象分镜页(品牌色系),
// 内容确定、可重现、零版权风险。看演示的人关注的是 App 界面,不是漫画本身。
//
// 跑法:
//   swift Scripts/gen_demo_sample.swift [输出目录]
//   默认输出到 ../Unroll-demo/(仓库之外 —— 避免 Xcode/Spotlight 遍历)
//
// 产物:
//   <输出目录>/src/p1.png ... p8.png
//   <输出目录>/demo.cbz           (8 页,macOS 双击即可用开卷打开)
//
// 铁律:演示素材与手工样本一样,用完即删(脚本几秒可重建)。
// ============================================================================
import AppKit
import Foundation
import CoreGraphics
import CoreText
import ImageIO

// MARK: - 颜色(与 DesignSystem.Palette 同步)
func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
            green: CGFloat((v >> 8) & 0xFF) / 255.0,
            blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
}

let paper   = hex(0xF5F2EA)   // 纸面米白
let ink     = hex(0x2C2C2A)   // 墨线
let inkSoft = hex(0x5F5E5A)   // 次级墨
let lineCol = hex(0xB4B2A9)   // 浅描边
let teal600 = hex(0x0F6E56)   // 品牌主色
let teal400 = hex(0x1D9E75)
let teal200 = hex(0x5DCAA5)
let teal100 = hex(0x9FE1CB)
let teal50  = hex(0xE1F5EE)
let gray100 = hex(0xD3D1C7)

let W: CGFloat = 1200
let H: CGFloat = 1700
let pad: CGFloat = 64

// MARK: - 绘制原语(坐标系:已翻转为左上原点、y 向下)
func fillRect(_ ctx: CGContext, _ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
    ctx.setFillColor(color)
    if radius > 0 {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    } else {
        ctx.fill(r)
    }
}

func strokeRect(_ ctx: CGContext, _ r: CGRect, _ color: CGColor, width: CGFloat, radius: CGFloat = 0) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    if radius > 0 {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
    } else {
        ctx.stroke(r)
    }
}

func fillCircle(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
}

func fillThickLine(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ color: CGColor, width: CGFloat) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
}

/// 绘制文字。`baseline` = 文字基线左端(屏幕坐标系,y 向下);文字在基线之上生长。
/// 实现:全局已翻转(y 向下),这里再翻一次让字形正立 —— 净变换回到屏幕坐标系。
func drawText(_ ctx: CGContext, _ text: String, baseline: CGPoint, size: CGFloat,
              color: CGColor, weight: String = "Helvetica-Bold") {
    let font = CTFontCreateWithName(weight as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))

    ctx.saveGState()
    ctx.translateBy(x: baseline.x, y: baseline.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// 对话框:圆角矩形 + 指向下方的小尾巴 + 内部文字占位横线
func drawBubble(_ ctx: CGContext, _ r: CGRect, lines: Int, fill: CGColor = .init(srgbRed: 1, green: 1, blue: 1, alpha: 1)) {
    fillRect(ctx, r, fill, radius: 22)
    strokeRect(ctx, r, ink, width: 4, radius: 22)
    // 尾巴
    ctx.setFillColor(fill)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.minX + 46, y: r.maxY))
    ctx.addLine(to: CGPoint(x: r.minX + 34, y: r.maxY + 34))
    ctx.addLine(to: CGPoint(x: r.minX + 96, y: r.maxY))
    ctx.closePath()
    ctx.fillPath()
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(4)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.minX + 46, y: r.maxY))
    ctx.addLine(to: CGPoint(x: r.minX + 34, y: r.maxY + 34))
    ctx.addLine(to: CGPoint(x: r.minX + 96, y: r.maxY))
    ctx.strokePath()
    // 文字占位线
    let inner = r.insetBy(dx: 30, dy: 34)
    let gap = inner.height / CGFloat(max(lines, 1))
    for i in 0..<lines {
        let w = i == lines - 1 ? inner.width * 0.62 : inner.width
        let y = inner.minY + gap * CGFloat(i) + gap / 2 - 9
        fillRect(ctx, CGRect(x: inner.minX, y: y, width: w, height: 18), lineCol, radius: 9)
    }
}

/// 速度线:从一侧向另一侧辐射的斜线组
func drawSpeedLines(_ ctx: CGContext, _ r: CGRect, count: Int, fromRight: Bool) {
    ctx.setStrokeColor(lineCol)
    ctx.setLineWidth(5)
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(max(count - 1, 1))
        let y0 = r.minY + 40 + t * (r.height - 80)
        let y1 = r.minY + 20 + t * (r.height - 40)
        ctx.move(to: CGPoint(x: fromRight ? r.maxX - 8 : r.minX + 8, y: y0))
        ctx.addLine(to: CGPoint(x: r.midX + (fromRight ? 40 : -40), y: y1))
        ctx.strokePath()
    }
}

// MARK: - 页面内容
/// 面板装饰:按样式索引画不同的抽象图形
func drawPanelDecor(_ ctx: CGContext, _ r: CGRect, style: Int) {
    switch style % 5 {
    case 0:   // 人脸/主体:大圆 + 内圆
        fillCircle(ctx, CGPoint(x: r.midX, y: r.midY - 40), min(r.width, r.height) * 0.28, teal200)
        fillCircle(ctx, CGPoint(x: r.midX - min(r.width, r.height) * 0.09, y: r.midY - 60),
                   min(r.width, r.height) * 0.055, teal600)
        fillCircle(ctx, CGPoint(x: r.midX + min(r.width, r.height) * 0.09, y: r.midY - 60),
                   min(r.width, r.height) * 0.055, teal600)
        fillThickLine(ctx, CGPoint(x: r.midX - 70, y: r.midY + 90),
                      CGPoint(x: r.midX + 70, y: r.midY + 90), teal600, width: 10)

    case 1:   // 速度线
        drawSpeedLines(ctx, r, count: 14, fromRight: true)
        fillCircle(ctx, CGPoint(x: r.midX + r.width * 0.18, y: r.midY), min(r.width, r.height) * 0.16, teal400)

    case 2:   // 竖条组(城市/森林)
        let cols = 7
        let gap = r.width / CGFloat(cols + 1)
        for i in 0..<cols {
            let h = r.height * (0.28 + 0.52 * abs(sin(Double(i) * 1.7)))
            let x = r.minX + gap * CGFloat(i + 1) - gap * 0.3
            fillRect(ctx, CGRect(x: x, y: r.maxY - h, width: gap * 0.6, height: h),
                     i % 2 == 0 ? teal100 : gray100, radius: 8)
        }

    case 3:   // 网格小方块(人群/窗)
        let cols = 6, rows = 4
        let cw = r.width * 0.72 / CGFloat(cols)
        let ch = r.height * 0.6 / CGFloat(rows)
        let ox = r.midX - r.width * 0.36
        let oy = r.midY - r.height * 0.3
        for row in 0..<rows {
            for col in 0..<cols {
                let shade = (row + col) % 3
                let color = shade == 0 ? teal200 : (shade == 1 ? gray100 : teal100)
                fillRect(ctx, CGRect(x: ox + cw * CGFloat(col) + 6, y: oy + ch * CGFloat(row) + 6,
                                     width: cw - 14, height: ch - 14), color, radius: 10)
            }
        }

    default:  // 斜纹 + 圆
        ctx.setStrokeColor(lineCol)
        ctx.setLineWidth(6)
        var x = r.minX - r.height
        while x < r.maxX {
            ctx.move(to: CGPoint(x: x, y: r.maxY))
            ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            ctx.strokePath()
            x += 46
        }
        fillCircle(ctx, CGPoint(x: r.midX, y: r.midY), min(r.width, r.height) * 0.2, teal600)
    }
}

/// 一格分镜:白底 + 墨线描边 + 装饰 + 可选对话框
func drawPanel(_ ctx: CGContext, _ r: CGRect, style: Int, bubble: Bool) {
    fillRect(ctx, r, hex(0xFFFFFF), radius: 6)
    strokeRect(ctx, r, ink, width: 5, radius: 6)

    ctx.saveGState()
    ctx.clip(to: r.insetBy(dx: 6, dy: 6))
    drawPanelDecor(ctx, r, style: style)
    ctx.restoreGState()

    if bubble {
        let bw = min(r.width * 0.52, 380)
        let bh: CGFloat = 132
        let rect = CGRect(x: r.maxX - bw - 40, y: r.minY + 42, width: bw, height: bh)
        drawBubble(ctx, rect, lines: 3)
    }
}

/// 分镜布局:每页不同,避免翻页时画面重复
func panels(for page: Int, in area: CGRect) -> [(CGRect, Int, Bool)] {
    let g: CGFloat = 26   // 格间距
    let layouts: [[CGRect]] = [
        // A:上下 2 格
        [CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height - g) / 2),
         CGRect(x: area.minX, y: area.minY + (area.height - g) / 2 + g, width: area.width, height: (area.height - g) / 2)],
        // B:上大 + 下 2
        [CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * 0.55),
         CGRect(x: area.minX, y: area.minY + area.height * 0.55 + g, width: (area.width - g) / 2, height: area.height * 0.45 - g),
         CGRect(x: area.minX + (area.width - g) / 2 + g, y: area.minY + area.height * 0.55 + g,
                width: (area.width - g) / 2, height: area.height * 0.45 - g)],
        // C:2x2
        [CGRect(x: area.minX, y: area.minY, width: (area.width - g) / 2, height: (area.height - g) / 2),
         CGRect(x: area.minX + (area.width - g) / 2 + g, y: area.minY, width: (area.width - g) / 2, height: (area.height - g) / 2),
         CGRect(x: area.minX, y: area.minY + (area.height - g) / 2 + g, width: (area.width - g) / 2, height: (area.height - g) / 2),
         CGRect(x: area.minX + (area.width - g) / 2 + g, y: area.minY + (area.height - g) / 2 + g,
                width: (area.width - g) / 2, height: (area.height - g) / 2)],
        // D:上 2 + 下大
        [CGRect(x: area.minX, y: area.minY, width: (area.width - g) / 2, height: area.height * 0.45 - g),
         CGRect(x: area.minX + (area.width - g) / 2 + g, y: area.minY, width: (area.width - g) / 2, height: area.height * 0.45 - g),
         CGRect(x: area.minX, y: area.minY + area.height * 0.45, width: area.width, height: area.height * 0.55)],
    ]
    let chosen = layouts[(page - 2) % layouts.count]
    return chosen.enumerated().map { (idx, rect) in
        (rect, page + idx, (page + idx) % 2 == 0)
    }
}

/// 画满一页(封面 or 内页)
func renderPage(_ page: Int, total: Int) -> CGImage? {
    let w = Int(W), h = Int(H)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // 翻转为左上原点、y 向下 —— 布局按直觉写
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    fillRect(ctx, CGRect(x: 0, y: 0, width: W, height: H), paper)

    if page == 1 {
        // 封面:品牌色块 + 圆形主体 + 标题线
        let card = CGRect(x: pad, y: pad, width: W - pad * 2, height: H - pad * 2)
        fillRect(ctx, card, teal600, radius: 28)
        fillCircle(ctx, CGPoint(x: W / 2, y: H * 0.44), 300, paper)
        fillCircle(ctx, CGPoint(x: W / 2, y: H * 0.44), 158, teal600)
        fillRect(ctx, CGRect(x: W / 2 - 260, y: H * 0.72, width: 520, height: 34), paper, radius: 17)
        fillRect(ctx, CGRect(x: W / 2 - 170, y: H * 0.72 + 66, width: 340, height: 24), teal200, radius: 12)
    } else {
        // 内容区给页脚留出空间(否则分镜框会压到页码上)
        let area = CGRect(x: pad, y: pad, width: W - pad * 2, height: H - pad * 2 - 130)
        for (rect, style, bubble) in panels(for: page, in: area) {
            drawPanel(ctx, rect, style: style, bubble: bubble)
        }
        // 页脚:页码 + 页眉名(基线对齐到内边距线)
        drawText(ctx, "PAGE \(page) / \(total)",
                 baseline: CGPoint(x: W - pad - 240, y: H - pad), size: 42, color: inkSoft)
        drawText(ctx, "UNROLL DEMO",
                 baseline: CGPoint(x: pad, y: H - pad), size: 30, color: lineCol)
    }

    return ctx.makeImage()
}

// MARK: - 主流程
let args = Array(CommandLine.arguments.dropFirst())
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = args.first.map { URL(fileURLWithPath: $0) } ?? repoRoot.deletingLastPathComponent().appendingPathComponent("Unroll-demo")
let srcDir = outDir.appendingPathComponent("src")

try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

let totalPages = 8
var generated: [URL] = []

for page in 1...totalPages {
    guard let img = renderPage(page, total: totalPages) else {
        FileHandle.standardError.write(Data("渲染失败: p\(page)\n".utf8))
        exit(1)
    }
    let url = srcDir.appendingPathComponent("p\(page).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("创建 PNG 失败: p\(page)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("写 PNG 失败: p\(page)\n".utf8))
        exit(1)
    }
    generated.append(url)
    print("  p\(page).png")
}

// 打包成 cbz(内部条目名保持自然排序可读的 p1..p8)
let cbz = outDir.appendingPathComponent("demo.cbz")
try? FileManager.default.removeItem(at: cbz)
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zip.currentDirectoryURL = srcDir
zip.arguments = ["-j", "-X", "-q", cbz.path] + (1...totalPages).map { "p\($0).png" }
try zip.run()
zip.waitUntilExit()
guard zip.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("zip 打包失败\n".utf8))
    exit(1)
}

let attrs = try? FileManager.default.attributesOfItem(atPath: cbz.path)
let kb = ((attrs?[.size] as? Int) ?? 0) / 1024
print("\n→ \(totalPages) 页 → \(cbz.path) (\(kb) KB)")
