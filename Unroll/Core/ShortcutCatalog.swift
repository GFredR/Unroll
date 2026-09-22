// AI-Generated | 可修改
// ShortcutCatalog —— 「帮助 → 键盘快捷键…」与空态小抄的**展示清单**(2026-09-22)
// ----------------------------------------------------------------------------
// 为什么需要这份清单:菜单栏里有 23 条**带快捷键**的命令,不翻菜单就完全看不见
// 它们存在(菜单里还有几条不带键位的,比如「清空最近打开」/「显示阅读提示」,
// 那些不属于这份清单)。
// 但把清单**手抄一份**进 App 有个众所周知的下场 —— 与真实菜单分叉,
// 而且分叉是沉默的(用户看到的是错的那份,没有人会报错)。
//
// 所以这里的对策是**让机器钉住它**:`MenuStructureTests` 会拿本清单的每一条
// 去真实菜单(`NSApp.mainMenu`)里找同名项,把菜单项的 (keyEquivalent,
// modifierMask) 格式化成同一个「⌃⌥⇧⌘ + 键位」串,断言**两边逐字相等**。
// 也就是说:改快捷键忘了改这里 / 改这里忘了改菜单,测试当场就红。
//
// ⚠️ **有菜单项的才钉得住**(`hasMenuItem = true`)。空格翻页、滚轮、双击缩放
// 这些没进菜单,机器无处对照 —— 它们标 `false`,**改错了没有人拦**。
// 这一条要如实告诉用户,不能把"列出来了"说成"验过了"。
//
// 于是面板的说明文字也跟着受约束:`help.shortcuts.subtitle` 只能写
// **「带 ⌘ 的都能在菜单栏里找到」** —— 清单里凡带 ⌘ 的都有菜单项、不带的都没有,
// 这条恒等式由测试断言(`testCatalogMenuFlagsMatchTheCommandKey`)。
// 写成"下面这些都能在菜单栏里找到"就把最后一组变成了假话(2026-09-22 订正)。
//
// 组合串的格式(与测试的格式化函数同一口径,顺序固定):
//   ⌃ control → ⌥ option → ⇧ shift → ⌘ command,后接键位;方向键写作 ← → ↑ ↓
import Foundation

/// 一条快捷键展示项
struct ShortcutItem: Identifiable, Equatable {

    /// L10n key。有菜单项的条目,**它的值就是菜单项标题**(测试据此在菜单里查找)
    let id: String
    /// 展示用的组合串,如 `⌘0` / `⇧⌘G` / `⌥⌘↑`;无组合键的写作 `—`
    let shortcut: String
    /// 是否存在对应菜单项。`false` = 机器验不了(仅展示)
    let hasMenuItem: Bool

    init(_ id: String, _ shortcut: String, hasMenuItem: Bool = true) {
        self.id = id
        self.shortcut = shortcut
        self.hasMenuItem = hasMenuItem
    }
}

/// 一个分组(id 即分组标题的 L10n key)
struct ShortcutGroup: Identifiable, Equatable {
    let id: String
    let items: [ShortcutItem]
}

enum ShortcutCatalog {

    /// 手抄自 `UnrollApp.commands` —— 顺序也照着菜单走,方便两边对着看。
    /// ⚠️ 手抄不是问题,**抄完不钉才是问题**:每条 `hasMenuItem = true` 的项
    /// 都由 `MenuStructureTests` 与真实菜单逐字对照
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(id: "help.shortcut.group.file", items: [
            ShortcutItem("app.menu.open", "⌘O"),
            ShortcutItem("app.menu.saveCurrentPage", "⌘S"),
            ShortcutItem("app.menu.exportPages", "⇧⌘E"),
            ShortcutItem("app.menu.revealInFinder", "⇧⌘F"),
            ShortcutItem("app.menu.unlock", "⇧⌘K"),
            ShortcutItem("app.menu.checkIntegrity", "⌥⌘V"),
        ]),
        ShortcutGroup(id: "help.shortcut.group.layout", items: [
            ShortcutItem("reader.layout.single", "⌘1"),
            ShortcutItem("reader.layout.dual", "⌘2"),
            ShortcutItem("reader.layout.scroll", "⌘0"),
            ShortcutItem("app.menu.coverAlone", "⌥⌘C"),
            ShortcutItem("reader.direction.ltr", "⇧⌘L"),
            ShortcutItem("reader.direction.rtl", "⇧⌘R"),
        ]),
        ShortcutGroup(id: "help.shortcut.group.navigate", items: [
            ShortcutItem("app.menu.firstPage", "⇧⌘↑"),
            ShortcutItem("app.menu.lastPage", "⇧⌘↓"),
            ShortcutItem("app.menu.jumpToPage", "⌥⌘G"),
            ShortcutItem("app.menu.thumbnailGrid", "⇧⌘G"),
        ]),
        ShortcutGroup(id: "help.shortcut.group.zoom", items: [
            ShortcutItem("reader.fit.window", "⌘3"),
            ShortcutItem("reader.fit.width", "⌘4"),
            ShortcutItem("reader.fit.height", "⌘5"),
            ShortcutItem("reader.fit.actual", "⌘6"),
        ]),
        ShortcutGroup(id: "help.shortcut.group.bookmark", items: [
            ShortcutItem("app.menu.addBookmark", "⌘D"),
            ShortcutItem("app.menu.previousBookmark", "⌥⌘↑"),
            ShortcutItem("app.menu.nextBookmark", "⌥⌘↓"),
        ]),
        ShortcutGroup(id: "help.shortcut.group.gesture", items: [
            ShortcutItem("help.shortcut.turnPage", "← → · 空格", hasMenuItem: false),
            ShortcutItem("help.shortcut.wheelSwipe", "滚轮", hasMenuItem: false),
            ShortcutItem("help.shortcut.halfClick", "单击", hasMenuItem: false),
            ShortcutItem("help.shortcut.doubleClick", "双击", hasMenuItem: false),
            ShortcutItem("help.shortcut.pinch", "捏合 · 拖拽", hasMenuItem: false),
        ]),
    ]

    /// 有菜单项的那些条目(测试逐条与真实菜单对照)
    static var verifiableItems: [ShortcutItem] {
        groups.flatMap(\.items).filter(\.hasMenuItem)
    }

    /// 没有菜单项的那些(**机器验不了**,如实计数给测试当"已知未覆盖"用)
    static var unverifiableItems: [ShortcutItem] {
        groups.flatMap(\.items).filter { !$0.hasMenuItem }
    }
}
