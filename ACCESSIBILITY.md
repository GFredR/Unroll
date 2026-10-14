# Accessibility / 无障碍支持

**中文**

## 先说验证状态（这段最重要，请先读）

下面写的「已支持」指**代码里确实这么写的**，不是「已通过 VoiceOver 走查」。

- ✅ 下面的功能**已实现**，可在代码中核对
- ⚠️ **尚未做完整的 VoiceOver 人工走查** —— 如果你用 VoiceOver 遇到问题，欢迎开 issue，这会是第一条有用的反馈

## 已支持

### 全键盘操作

每个功能都能纯键盘完成，不需要鼠标。`⌘?` 打开的菜单里列了全部快捷键，包括**五个在菜单里没有对应项的画布手势**——除此之外没有任何地方告诉你它们存在。

几个常用的：

| 操作 | 快捷键 |
|---|---|
| 上一页 / 下一页 | `←` `→`（会跟随阅读方向，漫画模式下「下一页」是左边那个） |
| 下一页（也可） | `Space` `↓` `Page Down` `End` |
| 单页 / 双页 | `⌘1` / `⌘2` |
| 连续滚动 | `⌘0` |
| 缩略图网格 / 返回 | `⇧⌘G` / `Esc` |
| 跳到某页 | `⌥⌘G`（边打边预览那一页，打错立刻看得见） |
| 书签 | `⌘D` 加/删，`⌥⌘↑` `⌥⌘↓` 在书签间跳 |
| 缩放 | `⌘3`–`⌘6`（适窗 / 适宽 / 适高 / 原始大小） |
| 完整性检查 | `⌥⌘V` |

### 界面元素有辅助功能标注

HUD、缩略图网格、连续滚动视图、密码输入框、阅读工具条、提示条等界面元素设置了 `accessibilityLabel`，让 VoiceOver 能读出它们是什么，而不只是「按钮」。

### 不依赖颜色传达信息

界面用文字标签配合色条，而不是只靠颜色区分。红黄绿分级（重要 / 谨慎 / 可清理）都有文字说明。

### 界面不闪烁

没有自动播放的动效。HUD 在鼠标静止 2.5 秒后淡出——**淡出后的元素仍会重新出现**，不会永久消失导致找不到方向。

## 已知不足

- **未做 VoiceOver 完整走查**，画布区域的朗读表现可能有问题。
- 缩略图网格里的图片**没有逐格的详细描述**（能读到「第几页」，读不到画面内容）。
- 主题跟随系统（浅色 / 深色），但没有单独的「高对比度」选项。
- 加密包输入密码时，**输错会原地说明**（区分大小写）—— 这条对密码管理器用户可能不太友好。

## 反馈

如果你遇到任何无障碍问题，开一个 issue，标题里带上「Accessibility」。

**这对我有特殊意义** —— 视觉、听觉、操作方面的障碍是我做这类工具时最容易漏掉的部分，而只有真正需要的人才能指出哪里不行。

---

**English**

## Verification status (read this first)

"Supported" below means **the code does it** — not "verified by a VoiceOver walkthrough".

- ✅ Implemented; verifiable in the source
- ⚠️ **No full VoiceOver pass has been done.** If you hit a problem with VoiceOver, please open an issue — it would be the first useful piece of feedback here.

## What is supported

### Full keyboard operation

Everything is reachable without a mouse. `⌘?` lists every shortcut, **including the five canvas gestures that have no menu item at all** — nothing else in the app tells you those exist.

Common ones:

| Action | Shortcut |
|---|---|
| Previous / next page | `←` `→` (follows reading direction — under RTL, "next" is the left one) |
| Next page (also) | `Space` `↓` `Page Down` `End` |
| Single page / spread | `⌘1` / `⌘2` |
| Continuous scroll | `⌘0` |
| Grid / back | `⇧⌘G` / `Esc` |
| Go to page | `⌥⌘G` (previews that page as you type, so a typo is visible before you commit) |
| Bookmarks | `⌘D` to toggle, `⌥⌘↑` `⌥⌘↓` to jump |
| Zoom | `⌘3`–`⌘6` (fit window / width / height / 1:1) |
| Integrity check | `⌥⌘V` |

### Labelled interface elements

The HUD, thumbnail grid, continuous scroll view, password prompt, reader chrome and hint bar carry `accessibilityLabel` values, so VoiceOver can read what they are instead of just "button".

### Not colour-only

Colour-coded states are always paired with text labels. The red/amber/green grading (important / careful / cleanable) includes wording.

### No flashing

Nothing autoplays. The HUD fades 2.5 s after you stop moving — **and the faded controls return**, rather than vanishing permanently and leaving you lost.

## Known gaps

- **No VoiceOver pass yet**; the canvas area in particular may read poorly.
- Thumbnails in the grid have **no per-cell description** (you hear "page 3", not the image content).
- The theme follows the system, but there is **no separate high-contrast option**.
- Password errors are explained in place and are **case-sensitive** — which can be awkward with password managers.

## Feedback

Open an issue titled with "Accessibility" if anything here doesn't work for you.

**This matters to me specifically** — visual, hearing and motor limitations are exactly what I miss when building a tool like this, and only someone who actually needs it can say where it falls short.