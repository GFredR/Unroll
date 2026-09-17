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
- **另存当前页**(⌘S):存成 PNG 或 JPEG;**双页模式下导出的是屏幕上那一整摊**(按当前阅读方向并排),不是单页。建议文件名带归档名与补零页号(`vol01-p003.png`),排出来就是阅读顺序
- **进度条可拖动**(HUD):拖动中页码跟着变,松手才跳页 —— 不是每挪一格就解码一次
- **窗口标题带页码**(`文件名 · P.3/200`)+ ⇧⌘F「在访达中显示」:多窗口与 Dock 悬停能分辨读到哪,接着看下一卷不用重新找文件
- **静止后光标一并隐藏**:与 HUD 的 2.5 秒淡出同一拍,鼠标一动就回来
- 最近打开(security-scoped bookmark,最多 10 条,只存文件名),菜单标注每本读到第几页
- 最近打开里文件已被移走的条目会标「(找不到文件)」,**点开时说明原因再清理,不再无声消失**
- **Finder 集成（QuickLook）**:按空格预览封面 + 总页数,文件图标直接显示封面,不必先打开 App。两个扩展(缩略图 + 预览)随 App 一起分发;加密/读不出来的归档刻意退回系统默认图标,不挂误导性占位图;只认 cbz/cbr/cb7/cbt,不碰裸 zip
- **加密归档可输密码解压阅读**:加密的 cbz / cbr 打开时直接弹密码输入框,输对即读、输错原地说明原因(区分大小写)并重试,不再只有一句"暂不支持"。**ZIP 的 ZipCrypto 与传统加密、AES-256 均实测可解**;部分加密的包在阅读中用 ⇧⌘K(或占位卡片上的按钮)一次解锁全部加密页,**阅读位置不动**。**加密 7z 刻意不给密码框** —— 系统 libarchive 实测给对密码也解不开,让你输一个注定无效的密码比直接说不支持更糟。加密 RAR 给入口但未实测,措辞弱于 7z。密码只驻留内存:不落盘、不记入钥匙串(不做"记住密码")、不进崩溃报告(只记"需要密码"与"成功/失败")
- 加密归档三态呈现:无 / 部分页占位卡片 / 整档说明,绝不闪退;**「密码不对」与「文件损坏」分开报**——前者再试一次,后者别浪费时间
- 崩溃采集 L0:零依赖零后端,异常退出自愿上报(App 自身零网络请求)
- 零第三方依赖(系统 libarchive,BSD-2);Universal 2;App 约 1.9 MB(主程序 1.2 MB + 两个 Finder 扩展约 0.5 MB),DMG 756 KB
- **产物可自证来源**:App 内记有构建时的提交号,拿到 dmg 的人不必只信 SHA256 —— 打开包里的 `Info.plist` 就能核对这个二进制对应哪个公开提交。本项目没有付费签名,这是一条可以自查的信任锚

**English**
- Streams pages straight from the archive: cbz / cbr / cb7 / cbt, plus bare zip / rar / 7z / tar (content sniffing, extension-agnostic)
- Dual-page mode with manga right-to-left; four fit modes: fit window / fit width / fit height / actual size (⌘3–⌘6)
- **Cover on its own page** (`⌥⌘C`): manga volumes keep the cover on a page of its own, which is what makes spreads pair up correctly (0 | 1-2 | 3-4); the old fixed pairing was 0-1 / 2-3 and shifted every spread by one page
- **Resume**: remembers the page, single/two-page layout, reading direction and zoom mode per archive (identified by file name + size, no path stored)
- **Bookmarks**: `⌘D` to mark the current page, `⌥⌘↑` / `⌥⌘↓` to jump between them (wrapping at the ends), with a menu to jump straight to a marked page
- **Go to page** (`⌥⌘G`); window size and position are remembered too
- **Save the current page** (`⌘S`) as PNG or JPEG. In two-page mode it writes **the whole spread you are looking at** (side by side, in your reading direction) rather than one isolated page. The suggested file name carries the archive name and a zero-padded page number (`vol01-p003.png`), so the exports sort in reading order
- **Draggable progress bar** (HUD) — the page number follows your drag and it jumps when you let go, instead of decoding a page for every step
- **Page number in the window title** (`file name · P.3/200`) plus `⇧⌘F` "Show in Finder" — multiple windows and Dock hover tell you where you are, and moving on to the next volume no longer means hunting for the file
- **The cursor hides once you stop moving**, on the same beat as the HUD fading out; any mouse movement brings it back
- Recents (security-scoped bookmarks, up to 10, filenames only) — the menu also shows how far you got in each one
- Recents entries whose file is gone are marked "(missing)" and **explained when clicked before being cleaned up — no more silent disappearance**
- **Quick Look integration**: press Space in Finder to preview the cover and page count, and let the file icon show the actual cover — no need to open the app. Two extensions (thumbnail + preview) ship inside the app; encrypted or unreadable archives deliberately fall back to the system icon instead of a misleading placeholder; only cbz/cbr/cb7/cbt are claimed, never plain zip
- **Encrypted archives can be unlocked with a password**: an encrypted cbz / cbr opens straight into a password prompt — the right password gets you reading, a wrong one explains itself in place (case-sensitive) and lets you retry, instead of the old flat "not supported yet". **ZipCrypto and AES-256 ZIP are both verified to open**; for partially encrypted archives, `⇧⌘K` (or the button on the placeholder card) unlocks every locked page at once **without moving your reading position**. **Encrypted 7z deliberately gets no password box** — the system libarchive cannot decrypt it even with the correct password, and asking for a password that cannot work is worse than plainly saying it's unsupported. Encrypted RAR does get a prompt but is untested, and is worded more cautiously than 7z. The password stays in memory: never written to disk, never stored in the Keychain (no "remember password"), never sent in a crash report (only "a password was required" and success/failure)
- Encrypted archives rendered in three states: none / placeholder cards for locked pages / explanation — never crashes; **"wrong password" and "damaged file" are reported separately**, because the first means try again and the second means stop wasting time
- Crash reporting L0: zero dependencies, zero backend, voluntary upload (the app itself makes no network requests)
- Zero third-party dependencies (system libarchive, BSD-2); Universal 2; app about 1.9 MB (1.2 MB main binary plus ~0.5 MB for the two Finder extensions), DMG 756 KB
- **The build can prove its own origin**: the app records the commit it was built from, so a downloader does not have to take the SHA256 on faith — read `Info.plist` inside the bundle and check which public commit this binary corresponds to. With no paid signing certificate in play, that is a trust anchor you can verify yourself

## 1.0.0 — 2026-09-15（仅本机打标，从未发布 / tagged locally, never published）

无对外产物：`v1.0.0` 标签指向本机一次更早的构建，当时的产物**不含**「封面单独一页」修正与 QuickLook 扩展。
**1.0.1 才是第一个对外的版本**，内容为上方全部条目。
