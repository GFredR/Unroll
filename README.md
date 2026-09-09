# 开卷 / Unroll

macOS 原生轻量归档看图器:双击 `.cbz / .cbr / .cb7 / .cbt` 直接阅读,不解压、不建库、退出无痕。

A lightweight, native macOS comic archive reader. Double-click `.cbz / .cbr / .cb7 / .cbt` to read — no extraction, no library, no traces left behind.

## 状态

**M0 · 工程骨架**(2026-09-09)。当前仅含可编译的工程结构与 UTI 文件关联声明,阅读功能自 M2 起提供。

- 技术栈:SwiftUI · Swift 6(strict concurrency)· 系统自带 libarchive(零第三方依赖)
- 最低系统:macOS 14 Sonoma
- 许可:MIT

## 开发

```bash
# 首次使用:从 project.yml 生成 Xcode 工程(生成物不入库)
./Scripts/regen.sh

# 打开开发
open Unroll.xcodeproj     # scheme: Unroll

# 纯逻辑快车道(不启动 App,毫秒级)
cd ArchiveKit && swift test
```

README 将在 M4(发布里程碑)完善双语内容与使用说明。
