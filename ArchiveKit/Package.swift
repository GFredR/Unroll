// swift-tools-version:6.0
// AI-Generated | 可修改
// ============================================================================
// ArchiveKit · 本地 SPM 包(设计文档 §4.1)
// ----------------------------------------------------------------------------
// 定位:归档读取与加密四态检测的纯逻辑层,零 UI 依赖。
// 分层(由底向上):
//   CArchiveShim  C 桥接 —— 手写 libarchive 原型 + modulemap 链接系统库
//   ArchiveKit    Swift 封装 —— open / entries / data(at:) / 自然排序 / 四态检测
// 收益:整个包可脱离 App 独立单测(cd ArchiveKit && swift test,毫秒级),
//       将来做 iOS/iPadOS 端可直接 100% 复用(§4.2 注)。
// swift-tools-version 6.0 → 包内 target 默认 Swift 6 语言模式(strict concurrency)。
// ============================================================================
import PackageDescription

let package = Package(
    name: "ArchiveKit",
    platforms: [
        .macOS(.v14),   // 与 App 一致:最低 Sonoma(§7.1-2)
    ],
    products: [
        // 只对外暴露 Swift 层;CArchiveShim 是内部实现细节(AGENTS.md 七.4 抽象层)
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    ],
    targets: [
        // C 桥接:systemLibrary target。
        // 目录内只有 module.modulemap + shim.h;modulemap 里 `link "archive"`
        // 会让 import 方在链接期自动带上 -larchive(SDK 内有 libarchive.tbd,已验证)。
        .systemLibrary(
            name: "CArchiveShim",
            path: "Sources/CArchiveShim"
        ),
        .target(
            name: "ArchiveKit",
            dependencies: ["CArchiveShim"]
        ),
        // 测试直接依赖 CArchiveShim:烟囱测试要能调 archive_version_string()
        // 验证「声明 + 链接 + ABI」整条链路在 M0 就通了(§6.2)。
        .testTarget(
            name: "ArchiveKitTests",
            dependencies: ["ArchiveKit", "CArchiveShim"]
        ),
    ]
)
