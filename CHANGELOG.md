# Changelog

## 1.0.0 — 2026-09-15（未发布 / unreleased）

首个公开版本 / First public release.

**中文**
- 直接从归档流式读页:cbz / cbr / cb7 / cbt,裸 zip / rar / 7z / tar 同样支持(按内容嗅探,不看扩展名)
- 双页模式 + 日漫右开;缩放四档:适应窗口 / 适应宽 / 适应高 / 实际大小(⌘3–⌘6)
- **续读记忆**:每本记住页码、单双页、左右开与缩放档位,重开自动回到原处(按「文件名 + 文件大小」认档,不存路径)
- **书签**:⌘D 标记当前页,⌥⌘↑/↓ 在书签间跳转(到端点绕回),书签菜单可直达某一页
- **跳转到页**:⌥⌘G 输入页码直达;窗口大小与位置自动记忆
- 最近打开(security-scoped bookmark,最多 10 条,只存文件名),菜单标注每本读到第几页
- 加密归档三态呈现:无 / 部分页占位卡片 / 整档说明,绝不闪退
- 崩溃采集 L0:零依赖零后端,异常退出自愿上报(App 自身零网络请求)
- 零第三方依赖(系统 libarchive,BSD-2);Universal 2;App < 1MB

**English**
- Streams pages straight from the archive: cbz / cbr / cb7 / cbt, plus bare zip / rar / 7z / tar (content sniffing, extension-agnostic)
- Dual-page mode with manga right-to-left; four fit modes: fit window / fit width / fit height / actual size (⌘3–⌘6)
- **Resume**: remembers the page, single/two-page layout, reading direction and zoom mode per archive (identified by file name + size, no path stored)
- **Bookmarks**: `⌘D` to mark the current page, `⌥⌘↑` / `⌥⌘↓` to jump between them (wrapping at the ends), with a menu to jump straight to a marked page
- **Go to page** (`⌥⌘G`); window size and position are remembered too
- Recents (security-scoped bookmarks, up to 10, filenames only) — the menu also shows how far you got in each one
- Encrypted archives rendered in three states: none / placeholder cards for locked pages / explanation — never crashes
- Crash reporting L0: zero dependencies, zero backend, voluntary upload (the app itself makes no network requests)
- Zero third-party dependencies (system libarchive, BSD-2); Universal 2; app under 1 MB
