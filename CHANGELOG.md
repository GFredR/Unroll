# Changelog

## 1.0.1 — 2026-09-16 · 首个公开发布 / First public release

首个公开版本 / First public release.

**中文**
- 直接从归档流式读页:cbz / cbr / cb7 / cbt,裸 zip / rar / 7z / tar 同样支持(按内容嗅探,不看扩展名)
- 双页模式 + 日漫右开;缩放四档:适应窗口 / 适应宽 / 适应高 / 实际大小(⌘3–⌘6)
- **封面单独一页**(⌥⌘C):日式单行本的封面是独立一页,开着才是正确的跨页配对(0 | 1-2 | 3-4);旧实现把配对写死成 0-1 / 2-3,每翻一摊都错位一面
- **续读记忆**:每本记住页码、单双页、左右开与缩放档位,重开自动回到原处(按「文件名 + 文件大小」认档,不存路径)
- **书签**:⌘D 标记当前页,⌥⌘↑/↓ 在书签间跳转(到端点绕回),书签菜单可直达某一页
- **跳转到页**:⌥⌘G 输入页码直达;窗口大小与位置自动记忆
- 最近打开(security-scoped bookmark,最多 10 条,只存文件名),菜单标注每本读到第几页
- 最近打开里文件已被移走的条目会标「(找不到文件)」,**点开时说明原因再清理,不再无声消失**
- **Finder 集成（QuickLook）**:按空格预览封面 + 总页数,文件图标直接显示封面,不必先打开 App。两个扩展(缩略图 + 预览)随 App 一起分发;加密/读不出来的归档刻意退回系统默认图标,不挂误导性占位图;只认 cbz/cbr/cb7/cbt,不碰裸 zip
- 加密归档三态呈现:无 / 部分页占位卡片 / 整档说明,绝不闪退
- 崩溃采集 L0:零依赖零后端,异常退出自愿上报(App 自身零网络请求)
- 零第三方依赖(系统 libarchive,BSD-2);Universal 2;App 约 1.7 MB(其中绝大多数是 Universal 2 二进制与两个 Finder 扩展)

**English**
- Streams pages straight from the archive: cbz / cbr / cb7 / cbt, plus bare zip / rar / 7z / tar (content sniffing, extension-agnostic)
- Dual-page mode with manga right-to-left; four fit modes: fit window / fit width / fit height / actual size (⌘3–⌘6)
- **Cover on its own page** (`⌥⌘C`): manga volumes keep the cover on a page of its own, which is what makes spreads pair up correctly (0 | 1-2 | 3-4); the old fixed pairing was 0-1 / 2-3 and shifted every spread by one page
- **Resume**: remembers the page, single/two-page layout, reading direction and zoom mode per archive (identified by file name + size, no path stored)
- **Bookmarks**: `⌘D` to mark the current page, `⌥⌘↑` / `⌥⌘↓` to jump between them (wrapping at the ends), with a menu to jump straight to a marked page
- **Go to page** (`⌥⌘G`); window size and position are remembered too
- Recents (security-scoped bookmarks, up to 10, filenames only) — the menu also shows how far you got in each one
- Recents entries whose file is gone are marked "(missing)" and **explained when clicked before being cleaned up — no more silent disappearance**
- **Quick Look integration**: press Space in Finder to preview the cover and page count, and let the file icon show the actual cover — no need to open the app. Two extensions (thumbnail + preview) ship inside the app; encrypted or unreadable archives deliberately fall back to the system icon instead of a misleading placeholder; only cbz/cbr/cb7/cbt are claimed, never plain zip
- Encrypted archives rendered in three states: none / placeholder cards for locked pages / explanation — never crashes
- Crash reporting L0: zero dependencies, zero backend, voluntary upload (the app itself makes no network requests)
- Zero third-party dependencies (system libarchive, BSD-2); Universal 2; app about 1.7 MB (mostly the Universal 2 binary plus the two Finder extensions)

## 1.0.0 — 2026-09-15（仅本机打标，从未发布 / tagged locally, never published）

无对外产物：`v1.0.0` 标签指向本机一次更早的构建，当时的产物**不含**「封面单独一页」修正与 QuickLook 扩展。
**1.0.1 才是第一个对外的版本**，内容为上方全部条目。
