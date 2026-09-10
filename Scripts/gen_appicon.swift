#!/usr/bin/env swift
// AI-Generated | 可修改
// gen_appicon.swift —— 重新生成 Unroll AppIcon 全部尺寸 PNG
// ============================================================================
// 设计:候选 A「开卷」(卷摊开 · 翘角动势),主色 teal 600 (#0F6E56)。
// 跑法:
//   swift Scripts/gen_appicon.swift
// 或(需要可执行权限时):
//   Scripts/gen_appicon.swift
// ----------------------------------------------------------------------------
// 产物:覆盖 Unroll/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//       (Contents.json 不变,只重写 PNG,Xcode 重新构建即可看到新图标)
// ---------------------------------------------------------------------------
// 设计依据:设计文档 §5 主色 / 用户 2026-09-10 拍板(teal + 开卷方案)。
// 颜色 token 与 DesignSystem.Palette 共享(写入时人工同步,见 DesignSystem.swift)。
// ============================================================================
import AppKit
import Foundation
import CoreGraphics
import ImageIO

// MARK: - 颜色(取自 DesignSystem.Palette 同步约定)
func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
            green: CGFloat((v >> 8) & 0xFF) / 255.0,
            blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
}

let teal600 = hex(0x0F6E56)   // 主色 · 卷轴主体
let teal800 = hex(0x085041)   // 卷轴顶/底椭圆(深一档)
let teal400 = hex(0x1D9E75)   // 卷轴中线高光(浅一档)
let gray50  = hex(0xF1EFE8)   // squircle 底色(米白)
let gray200 = hex(0xD3D1C7)   // 翘角内线
let gray600 = hex(0x5F5E5A)   // 纸面描边
let gray400 = hex(0x888780)   // 文字线
let white   = hex(0xFFFFFF)

// MARK: - 渲染(以 1024 为基准画布,小尺寸 = 整图按 k 缩放)
func renderIcon(size: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: info) else {
        return nil
    }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let s = CGFloat(size)
    let k = s / 1024.0   // 缩放系数(1024 为设计基准)

    // squircle 容器(macOS Big Sur+ 视觉:rx = 边长 × 22.37%)
    let container = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.beginPath()
    ctx.addPath(CGPath(roundedRect: container, cornerWidth: 229*k, cornerHeight: 229*k, transform: nil))
    ctx.clip()

    // 底色
    ctx.setFillColor(gray50)
    ctx.fill(container)

    // 卷轴主体 rect(244, 352, 90, 333)  rx=20
    ctx.setFillColor(teal600)
    let reel = CGPath(roundedRect: CGRect(x: 244*k, y: 352*k, width: 90*k, height: 333*k),
                      cornerWidth: 20*k, cornerHeight: 20*k, transform: nil)
    ctx.addPath(reel)
    ctx.fillPath()

    // 顶/底椭圆(深一档 teal)
    ctx.setFillColor(teal800)
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 244*k, y: 333*k, width: 90*k, height: 38*k), transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 244*k, y: 666*k, width: 90*k, height: 38*k), transform: nil))
    ctx.fillPath()

    // 卷轴中线(teal400 高光)
    ctx.setStrokeColor(teal400)
    ctx.setLineWidth(5*k)
    ctx.move(to: CGPoint(x: 289*k, y: 352*k))
    ctx.addLine(to: CGPoint(x: 289*k, y: 685*k))
    ctx.strokePath()

    // 摊开的纸面 rect(360, 397, 397, 243)
    let page = CGRect(x: 360*k, y: 397*k, width: 397*k, height: 243*k)
    ctx.setFillColor(white)
    ctx.fill(page)
    ctx.setStrokeColor(gray600)
    ctx.setLineWidth(6*k)
    ctx.stroke(page)

    // 文字线(三条,中间略短)
    ctx.setStrokeColor(gray400)
    ctx.setLineWidth(10*k)
    ctx.setLineCap(.round)
    let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (398, 461, 722, 461),
        (398, 512, 708, 512),
        (398, 563, 722, 563)
    ]
    for (x1, y1, x2, y2) in lines {
        ctx.move(to: CGPoint(x: x1*k, y: y1*k))
        ctx.addLine(to: CGPoint(x: x2*k, y: y2*k))
    }
    ctx.strokePath()

    // 翘角 path: M 754,397 L 832,358 L 832,640 L 754,666 Z
    let lift = CGMutablePath()
    lift.move(to: CGPoint(x: 754*k, y: 397*k))
    lift.addLine(to: CGPoint(x: 832*k, y: 358*k))
    lift.addLine(to: CGPoint(x: 832*k, y: 640*k))
    lift.addLine(to: CGPoint(x: 754*k, y: 666*k))
    lift.closeSubpath()
    ctx.setFillColor(white)
    ctx.addPath(lift)
    ctx.fillPath()
    ctx.setStrokeColor(gray600)
    ctx.setLineWidth(6*k)
    ctx.addPath(lift)
    ctx.strokePath()

    // 翘角内线(对侧边)
    ctx.setStrokeColor(gray200)
    ctx.setLineWidth(5*k)
    ctx.move(to: CGPoint(x: 832*k, y: 358*k))
    ctx.addLine(to: CGPoint(x: 832*k, y: 640*k))
    ctx.strokePath()

    return ctx.makeImage()
}

// MARK: - 输出
let outDir = URL(fileURLWithPath: "Unroll/Resources/Assets.xcassets/AppIcon.appiconset")

let sizes: [(String, Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024)
]

var ok = 0, fail = 0
for (name, size) in sizes {
    guard let img = renderIcon(size: size) else {
        FileHandle.standardError.write("❌ render failed: \(name)\n".data(using: .utf8)!)
        fail += 1
        continue
    }
    let url = outDir.appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("❌ dest failed: \(name)\n".data(using: .utf8)!)
        fail += 1
        continue
    }
    CGImageDestinationAddImage(dest, img, nil)
    if CGImageDestinationFinalize(dest) {
        print("✅ \(name).png  (\(size)x\(size))")
        ok += 1
    } else {
        FileHandle.standardError.write("❌ finalize failed: \(name)\n".data(using: .utf8)!)
        fail += 1
    }
}

print("\n→ 成功 \(ok) 张,失败 \(fail) 张")
exit(fail == 0 ? 0 : 1)