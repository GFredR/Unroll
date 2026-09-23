# Changelog

## 1.2.0 — 2026-09-23 · 首次公开发布 / First public release

**本版是实际对外公开的第一个版本。** `v1.0.0` / `v1.0.1` / `v1.1.0` 三个标签都只在本机打过、**从未推送过**（仓库此前没有远程）；其中 1.1.0 曾在本机构建并冻结过产物。本版在那一版之上补了下面这组**可发现性**改动；功能不变的部分见下面各段。

**可发现性三件套** —— 补上三处「东西在、但没人找得到」的空档。菜单栏里有 23 条带快捷键的命令，但发现它们的唯一途径是翻菜单栏；冷启动的空窗口什么提示都没有；而**画布手势**（点左右半屏、滑动翻页、双击缩放）是菜单里根本不存在的东西，更没有入口。三个展示面各面向一个时机，内容刻意不重叠：

**中文**
- **空态欢迎页**：图标 + 标题 + 「打开文件…」+ 一行常用快捷键 + **最近打开**（带续读进度，如 `vol01.cbz · P.12/48`）。最近打开的记录本应用一直在存，只是空窗口上从来没显示过 —— 现在打开 App 就能接着上次那本看。最多列 4 条：它是欢迎页不是管理器，列满就把「打开文件…」挤出视觉重心了
- **帮助菜单**（此前**是空的**）：「键盘快捷键…」（`⌘?`）列出全部快捷键，并把**菜单里没有的五个画布手势**单独成组 —— 那一组是这份清单唯一能告诉你的东西；另有「显示阅读提示」与「项目主页」
- **首次阅读提示条**：第一次打开一本归档时，画布上方出现一行可关闭的提示（点左右半屏 / 滑动 / 双击或捏合缩放），点「×」或按 `⌘?` 看更多。它**只自动出现一次**，之后想再看走「帮助 → 显示阅读提示」。三处入口讲的是三件不同的事：空态讲怎么开始、帮助面板讲全部命令、提示条只讲那些**菜单里查不到**的手势
- **它不是浮层**：提示条占据的是窗口布局里的一行，图片拿到的是扣掉它之后的高度 —— 从结构上就不可能盖住页面内容（浮层式引导要靠"算准不遮挡"，那是另一回事）

**English**
- **Empty-state welcome screen**: icon, title, an "Open file…" button, a line of common shortcuts, and **your recent archives** with reading progress (`vol01.cbz · P.12/48`). The app has always stored those records — it just never showed them on the empty window. Up to four entries: this is a welcome screen, not a manager, and a full list would push "Open file…" out of focus.
- **A Help menu** (there was **none**): "Keyboard shortcuts…" (`⌘?`) lists every shortcut and puts the **five canvas gestures that have no menu item** in their own group — that group is the one thing only this panel can tell you. Plus "Show reading tips" and the project homepage.
- **A first-read tip bar**: the first time you open an archive, a dismissible line appears above the canvas (click either half / swipe / double-click or pinch to zoom). It appears **once**; after that, "Help → Show reading tips" brings it back. The three entry points answer three different questions: the welcome screen tells you how to start, the Help panel lists every command, and the tip bar covers only the gestures you **cannot find in any menu**.
- **It is not an overlay**: the tip bar occupies a row in the window layout, and the page gets the height that remains — so it cannot cover content by construction, rather than by being positioned carefully.

## 1.1.0 — 2026-09-21 · 本机里程碑 / Local milestone

**本机里程碑。** 它包含 1.0.x 那条线的全部内容（下面各段），外加本版新落地的四项——缩略图网格、跳转面板就地预览、连续滚动、导出本卷页文件——以及滚动模式带出来的一个横向裁切修复。产物已在本机构建并冻结，但**没有单独对外发布过**：对外公开的安装包只有 1.2.0 那一个（在它的基础上补了可发现性三件套）。

> **本机冻结记录（2026-09-22 冻结 / 2026-09-23 复核）**：产物按 `00e8062` 重建（App 2.18 MB / DMG 972 KB，Universal 2，ad-hoc 签名），`v1.1.0` tag 已打，**从未推送**（仓库当时没有远程）。该版产物**已被 1.2.0 取代** —— `cy/Unroll-dist/Unroll-1.1.0.dmg` 仍在原地，仅作历史留存；对外发布的安装包是 1.2.0 那一份。

**中文**
- **连续滚动**（`⌘0`）——竖向一列，一页接一页。滚动位置与页码是**同一份状态**：视口驱动页码、跳页也带动视口，两者不可能对不上；只有视口附近的几行保留全分辨率图，出窗的行主动交还像素，这才是长距离滚动仍守在内存预算内的原因。缩放四档与「封面单独一页」描述的是「摊怎么放进窗口」，在滚动模式下会一并灰掉
- 新增「显示 → 连续滚动」菜单项（`⌘0`）
- **修掉一个肉眼看不见的缺陷**：滚动模式原先按窗口画布宽（900pt）给行定宽，而滚动视图内容区实宽只有 885pt（系统设成「始终显示滚动条」时，macOS 会给传统滚动条留 15pt 占位），于是**页面左右各被裁掉 7.5pt**。改用 `containerRelativeFrame` 认容器实宽，并新增**内容判据**把这条锁住：拿样本页脚自带的进度条（宽度 = 页宽的 n/总页数，是个已知比例）量出的期望值去比对实测值 —— 「铺满」与「铺满但被裁」在肉眼看来逐像素相同，只有换一把有已知位置的尺子才分辨得出来
- **缩略图网格**（`⇧⌘G`）——一眼看全卷，点任一格直达该页。此前所有快速移动手段（`⌥⌘G` 跳页 / `⌘D` 书签 / `⇧⌘↑↓` 首末页）都假设"你已经知道要去哪"，想找某一页只能一张张翻着认，这是第一个补上这个空缺的功能。三条实现口径值得说明：① **一趟顺序扫完**，不是"滚到哪生成哪"（后者在 solid 7z 上会让一遍滚动退化成平方级）；② 内存到顶即**停止生成**并**明说**"后面的页不会有图"，绝不让你一直等 —— 而不是偷偷淘汰已经生成的页（那会把平方级请回来）；③ 渲染路径**不碰任何 I/O**，滚动永远不会把读盘带进来
- **跳转面板就地预览**（`⌥⌘G`）——输入页码时就地显示那一页，输错当场看得见，不必先跳过去再退回来。停止输入 300ms 才解码（不会每敲一个字符解一次）；网格里已经有那一页时直接复用，不再解码第二遍
- 新增「显示 → 缩略图网格」菜单项；网格面板里可随时**停止**生成、也可**重新生成**；换书或重新生成都会作废旧的一批缩略图
- 网格生成进度与四种停止原因（扫完了 / 内存到顶 / 你叫停的 / 包坏得走不下去）**分别说明** —— 合成一句必然要说谎
- **导出本卷页文件**（`⇧⌘E`）—— 把**这一卷的每一页**按阅读顺序导成图片文件，**原始字节直通**：不解码、不重新编码、不合成。与 `⌘S`「另存当前页」是一对分工：`⌘S` 存的是**屏幕上那一摊**（双页会并成一张、JPEG 会重编码，要的是"所见即所得"），`⇧⌘E` 存的是**归档里的每一页**（要的是"原素材"）—— 把跨页彩图导成两张还是合成一张，本来就是两种真实需求。文件名是「归档名 + 补零页号 + 扩展名」（`vol01-p003.png`），排出来就是阅读顺序；扩展名优先用条目原名，原名给不出时按文件头（魔数）判断，认不出来就如实标 `.bin` 而不是猜一个 `.jpg`。加密页**跳过而不算损坏**（界面会分别说明"跳过 N 页加密页"与"有 N 页读不出来"）；写不出去（没权限 / 没空间）**立即停下并如实说是写入失败**，不会接着把剩下的页读完、最后报一句"200 页全失败"。选完目录即可停止，已写出的文件保留
- **这一版顺带收回一条错的免除理由**：早先"不做整包导出"的依据是"整包解压可以交给系统归档工具"。实情是系统归档工具**压根不认 RAR**（`cbr` 没有兜底），而且**就算能解，解出来的也不是我们要的东西** —— 解出的是归档顺序（`page10` 排在 `page1` 前面）加上 `__MACOSX` / `.DS_Store` / `note.txt` 这类条目；「哪些算页」与「页的先后」只有阅读器自己知道

**English**
- **Continuous scroll** (`⌘0`) — one vertical column, page after page. The scroll position and the page number are the **same state** (the viewport drives the counter and a jump moves the viewport), so the two can never disagree. Only the rows near where you are keep full-resolution images; rows leaving the viewport hand their pixels back, which is what keeps a long scroll inside the memory budget. The zoom modes and cover-alone describe how a *spread* fits the window, so they are greyed out here.
- New "View → Continuous scroll" menu item (`⌘0`).
- **Fixed a defect you could not have seen.** Rows used to take their width from the window canvas (900 pt) while the scroll view's content area was only 885 pt — with "Always show scroll bars" macOS reserves 15 pt for legacy scrollers — so **every page lost 7.5 pt on each side**. Rows now take the container's real width (`containerRelativeFrame`), and a **content-based guard** locks it in: the fixture's own page-footer progress bar is a known fraction of the page width, so its measured edge is checked against the measured content width. "Fits the width" and "fits the width but is clipped" are pixel-identical by eye; only a ruler at a known position can tell them apart.
- **Thumbnail grid** (`⇧⌘G`) — see the whole book at a glance and click any cell to jump there. Every earlier shortcut assumed you already knew where you were going; this is the first one that answers "which page was that spread on again?". Three implementation choices worth naming: (1) it generates in **one sequential pass**, not "whatever you scroll to" — the latter degrades to quadratic on solid 7z; (2) hitting the memory ceiling **stops generation and says so** rather than silently evicting pages you already have (which would reintroduce the quadratic cost); (3) the render path does **no I/O at all**, so scrolling never pulls disk reads into drawing.
- **Preview in the go-to-page panel** (`⌥⌘G`) — typing a page number shows that page in place, so a typo is visible before you commit. Decoding waits 300 ms after you stop typing; if the thumbnail grid already has that page it is reused instead of decoded twice.
- New "View → Thumbnail grid" menu item. The panel can **stop** generation at any time and **regenerate** on demand; opening another archive or regenerating discards the previous batch.
- Progress and the four stop reasons (finished / memory ceiling / cancelled by you / archive unreadable) are reported **separately** — collapsing them into one message would have to lie about at least one.
- **Export every page of the volume** (`⇧⌘E`) — writes **every page** to image files in reading order, **passing the original bytes through untouched**: no decoding, no re-encoding, no compositing. It is one half of a pair with `⌘S` "Save current page": `⌘S` saves **the spread you are looking at** (two pages become one image, JPEG gets re-encoded — it is meant to be what-you-see-is-what-you-get), while `⇧⌘E` saves **every page in the archive** (it is meant to be the source material). Exporting a double-page spread as two files or as one was always two legitimate needs. Files are named `<archive>-p003.png` (zero-padded page number), so they sort in reading order; the extension comes from the entry's own name when it has one, otherwise from the file's magic number, and falls back to `.bin` rather than guessing `.jpg`. Encrypted pages are **skipped, not counted as damage** (the panel reports "N encrypted pages skipped" and "N pages unreadable" separately); a failed write (no permission / no space) **stops immediately and says the write failed**, instead of ploughing through the rest and reporting "200 pages failed". You can stop at any point — files already written are kept.
- **And it retracts a bad excuse**: the original reason for "no bulk export" was that the system archive tool could do it. In fact the system tool **does not handle RAR at all** (no fallback for `cbr`), and **even where it does, its output is not what we need** — you get the archive's physical order (`page10` before `page1`) plus `__MACOSX` / `.DS_Store` / `note.txt` entries. Which entries count as pages, and in what order, is something only the reader knows.

## 1.0.1 — 2026-09-17 · 本机里程碑，从未对外发布 / Local milestone, never published

冻结 1.0 线核心功能的一个本机里程碑：产物与 tag 都已打好，**但从未推送过**（仓库当时还没有远程）。对外公开发布的版本是 **1.2.0**，它包含本段全部条目。

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
- **可以检查归档完整性**(⌥⌘V):逐页验字节,有坏页就**点名第几页**,而不是笼统说"有问题";加密页不算损坏(那是"要密码",不是"文件坏了");中途取消或损坏太多时如实报"没查完"—— **绝不把"没查完"说成"没问题"**
- **打开大归档不再假死**:列目录搬出主线程(网络卷 / 数千页的包不再让窗口转圈),并且**可以取消**(换书、关窗立刻生效,不留后台苦读)。对"库既报错也不给出条目"的坏包设了停滞上限,不再原地空转
- 内存:缩略图池补上**像素预算**(原先只限张数)。页数再多,常驻内存也有界
- 密码输入页改为居中大面板,输入框与说明不再挤成窄窄一条
- 零第三方依赖(系统 libarchive,BSD-2);Universal 2;App 约 1.9 MB(主程序 1.3 MB + 两个 Finder 扩展约 0.5 MB),DMG 812 KB
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
- **Archive integrity check** (`⌥⌘V`): verifies every page's bytes and **names the broken page numbers** instead of vaguely saying "something is wrong". Encrypted pages are not counted as damage — that is "needs a password", not "the file is broken". If you cancel it, or there is damage past the retry budget, it says so plainly: it **never reports "not finished checking" as "no problems found"**
- **Large archives no longer freeze the app on open**: listing the archive now runs off the main thread (a network volume or a several-thousand-page archive no longer spins the window), and it **can be cancelled** — switching archives or closing the window takes effect immediately instead of leaving a background read grinding away. Archives where the library neither errors nor yields an entry hit a stagnation cap instead of spinning forever
- Memory: the thumbnail pool now has a **pixel budget** (it used to be capped by count only), so resident memory stays bounded no matter how many pages there are
- The password prompt is now a centred, larger panel — the field and its explanation are no longer squeezed into a narrow strip
- Zero third-party dependencies (system libarchive, BSD-2); Universal 2; app about 1.9 MB (1.3 MB main binary plus ~0.5 MB for the two Finder extensions), DMG 812 KB
- **The build can prove its own origin**: the app records the commit it was built from, so a downloader does not have to take the SHA256 on faith — read `Info.plist` inside the bundle and check which public commit this binary corresponds to. With no paid signing certificate in play, that is a trust anchor you can verify yourself

## 1.0.0 — 2026-09-15（仅本机打标，从未发布 / tagged locally, never published）

无对外产物：`v1.0.0` 标签指向本机一次更早的构建，当时的产物**不含**「封面单独一页」修正与 QuickLook 扩展。
**对外公开发布的版本是 1.2.0**，内容为 1.0.1 与 1.1.0 两段的全部条目，加上 1.2.0 段的新增项。
