// AI-Generated | 可修改
// ql_probe.swift —— QuickLook 扩展的无头探针(2026-09-16)
// ----------------------------------------------------------------------------
// 为什么不用 `qlmanage -t`:qlmanage 启动时会给自己套一层 sandbox_init,
// 在受限环境里报 `sandbox initialization failed: Operation not permitted`
// 直接退出 —— 与本项目代码无关,是运行环境限制(实测确认)。
//
// 本探针走 QLThumbnailGenerator(公开 API,不套沙箱),请求系统为某个文件生成
// 缩略图 —— 系统会去加载**我们注册的 appex**,于是这条链路的每一段都被真实验证:
//   LaunchServices 认到扩展 → 宿主加载 appex → 扩展读归档 → 回图
// 把结果写成 PNG,便于直接人眼/像素校验。
//
// 用法:
//   swift Scripts/ql_probe.swift <归档路径> <输出.png> [边长,默认 512]
// 退出码:0 = 拿到缩略图;3 = 请求失败(未注册扩展 / 扩展报错 / 无缩略图)
import AppKit
import Foundation
import QuickLookThumbnailing

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("用法: swift ql_probe.swift <归档> <输出.png> [边长]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let side = CGFloat(Double(args.count > 3 ? args[3] : "512") ?? 512)

guard FileManager.default.fileExists(atPath: input.path) else {
    FileHandle.standardError.write(Data("输入不存在: \(input.path)\n".utf8))
    exit(2)
}

let request = QLThumbnailGenerator.Request(
    fileAt: input,
    size: CGSize(width: side, height: side),
    scale: 2,
    representationTypes: .thumbnail
)

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 3

QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
    defer { semaphore.signal() }

    if let error {
        print("✗ 生成失败: \(error)")
        return
    }
    guard let image = representation?.nsImage else {
        // 扩展回 (nil, nil) = 「本扩展不产出缩略图」,宿主不会给错误
        print("✗ 无缩略图(扩展判定为不可预览,或扩展未被加载)")
        return
    }

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("✗ PNG 编码失败")
        return
    }
    do {
        try png.write(to: output)
        print("✓ \(Int(image.size.width))x\(Int(image.size.height)) pt → \(output.path) (\(png.count) 字节)")
        exitCode = 0
    } catch {
        print("✗ 写文件失败: \(error)")
    }
}

_ = semaphore.wait(timeout: .now() + 30)
exit(exitCode)
