// 列出屏幕上的普通窗口(坐标 / id / 进程名 / 标题),供 screencapture 使用。
// 只读 CoreGraphics 窗口列表,不需要辅助功能授权。
//
// 用法:
//   swift Scripts/winid.swift                列出全部普通窗口
//   swift Scripts/winid.swift unroll         按进程名/标题过滤
//   swift Scripts/winid.swift unroll --rect  只输出 "x,y,w,h"(可直接喂给 screencapture -R)
//
// 坐标系与 screencapture -R 一致(全局逻辑点,主屏左上为原点)。
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst()
let rectOnly = args.contains("--rect")
let filter = args.first { !$0.hasPrefix("--") }?.lowercased()

// optionOnScreenOnly:只要屏幕上真实可见的;excludeDesktopElements:排除桌面/Dock 等
let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
guard let windows = raw as? [[String: Any]] else {
    FileHandle.standardError.write(Data("无法读取窗口列表\n".utf8))
    exit(1)
}

var hit = 0
for w in windows {
    // layer 0 = 普通应用窗口;layer > 0 是菜单栏/浮层等
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let title = w[kCGWindowName as String] as? String ?? ""
    if let filter, !owner.lowercased().contains(filter), !title.lowercased().contains(filter) {
        continue
    }

    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    func d(_ key: String) -> Int { (bounds[key] as? Double).map { Int($0.rounded()) } ?? 0 }
    let (x, y, width, height) = (d("X"), d("Y"), d("Width"), d("Height"))
    let id = w[kCGWindowNumber as String] as? Int ?? 0

    if rectOnly {
        print("\(x),\(y),\(width),\(height)")
    } else {
        print("\(id)\t\(owner)\t\(title)\t\(width)x\(height) @ \(x),\(y)")
    }
    hit += 1
}

if hit == 0 {
    FileHandle.standardError.write(Data("没有匹配的窗口\n".utf8))
    exit(2)
}
