# Changelog

## 1.0.0 — 2026-09-14

首个公开版本 / First public release.

**中文**
- 直接从归档流式读页:cbz / cbr / cb7 / cbt,裸 zip / rar / 7z / tar 同样支持(按内容嗅探,不看扩展名)
- 双页模式 + 日漫右开;缩放四档:适应窗口 / 适应宽 / 适应高 / 实际大小(⌘3–⌘6)
- 最近打开(security-scoped bookmark,最多 10 条,只存文件名)
- 加密归档三态呈现:无 / 部分页占位卡片 / 整档说明,绝不闪退
- 崩溃采集 L0:零依赖零后端,异常退出自愿上报(App 自身零网络请求)
- 零第三方依赖(系统 libarchive,BSD-2);Universal 2;App < 1MB

**English**
- Streams pages straight from the archive: cbz / cbr / cb7 / cbt, plus bare zip / rar / 7z / tar (content sniffing, extension-agnostic)
- Dual-page mode with manga right-to-left; four fit modes: fit window / fit width / fit height / actual size (⌘3–⌘6)
- Recents (security-scoped bookmarks, up to 10, filenames only)
- Encrypted archives rendered in three states: none / placeholder cards for locked pages / explanation — never crashes
- Crash reporting L0: zero dependencies, zero backend, voluntary upload (the app itself makes no network requests)
- Zero third-party dependencies (system libarchive, BSD-2); Universal 2; app under 1 MB
