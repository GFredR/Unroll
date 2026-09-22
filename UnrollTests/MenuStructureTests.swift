// AI-Generated | 可修改
// MenuStructureTests —— 菜单命令体系的守卫(2026-09-16,v2)
// ----------------------------------------------------------------------------
// 为什么可以这么测:单元测试的宿主**就是 App 本身**,`NSApp.mainMenu` 由 SwiftUI 在
// 启动时构建完毕,于是"菜单项是否存在 / 快捷键对不对 / 有没有撞车"全都能断言。
//
// 这三件事过去只能靠人点一遍,而它们的失效方式恰好都是**沉默的**:
//   · 漏把某个 Button 放进 `commands` → 功能在,但菜单里找不到,也没有任何报错;
//   · 两个命令用了同一个快捷键 → 系统只触发其中一个,另一个"按了没反应";
//   · 改快捷键时手滑写成 `.shift` 而不是 `.command` → 看着像对的。
//
// M3 的验收标准是「纯键盘可完成全部操作」—— 这份测试就是那条标准的机器判据。
//
// ⚠️ 反向测试实测到的机制边界(2026-09-16,别误以为是测试写错了):
//   把 ⇧⌘F 故意改成已被「从右往左读」占用的 ⇧⌘R 之后,失败的是
//   ① `testFileMenuCarriesRevealInFinderWithShiftCommandF`(快捷键变了),以及
//   ② `testCommonCommandsCarryShortcuts` —— 报「从右往左读(日漫)」**没有快捷键**。
//   也就是说:**系统会把撞车的那一项的 keyEquivalent 清空**,而不是保留冲突。
//   于是"唯一性扫描"这一条几乎不会自己触发(它看到的是"被清空后"的菜单),
//   真正的探测器是 ② ——「常用命令必须都带快捷键」。
//   两条都留着:① 防"改错修饰键",② 顺带把"撞车被系统吞掉"这件事翻出来。
import AppKit
import XCTest
@testable import Unroll

@MainActor
final class MenuStructureTests: XCTestCase {

    /// 递归收集主菜单里的全部菜单项
    private func allMenuItems() -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        func walk(_ menu: NSMenu?) {
            guard let menu else { return }
            for item in menu.items {
                result.append(item)
                walk(item.submenu)
            }
        }
        walk(NSApp.mainMenu)
        return result
    }

    private func menuItem(titled title: String) -> NSMenuItem? {
        allMenuItems().first { $0.title == title }
    }

    /// 测试宿主若没跑起 App 生命周期(例如将来换成无宿主测试),不伪造成失败
    private func requireMenu() throws -> [NSMenuItem] {
        let items = allMenuItems()
        try XCTSkipIf(items.isEmpty, "测试宿主里 mainMenu 尚未构建 —— 属环境差异,非缺陷")
        return items
    }

    // MARK: - 本次新增的两个命令

    func testFileMenuCarriesSaveCurrentPageWithCommandS() throws {
        _ = try requireMenu()
        let title = L10n.tr("app.menu.saveCurrentPage")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "s")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
    }

    func testFileMenuCarriesRevealInFinderWithShiftCommandF() throws {
        _ = try requireMenu()
        let title = L10n.tr("app.menu.revealInFinder")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    /// 部分加密包的解锁入口(⇧⌘K,2026-09-17)。
    /// 取「Key」的联想键:⇧⌘L / ⇧⌘R 已被左右开方向占用,⇧⌘F 给了「在访达中显示」。
    /// 它平时是 disabled 的(只有真存在加密页时才可用),但 keyEquivalent
    /// 与 disabled 无关 —— 断言的正是「这一项被正确注册进了菜单」
    func testFileMenuCarriesUnlockWithShiftCommandK() throws {
        _ = try requireMenu()
        let title = L10n.tr("app.menu.unlock")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "k")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    /// 完整性检查(⌥⌘V,2026-09-17)。取「Verify」的联想键;
    /// ⌘/⇧⌘/⌥⌘ 的常用位已占满(见上面几条注释),⌥⌘V 是剩下的合适位置。
    /// 它只在阅读态可用(disabled),但 keyEquivalent 与 disabled 无关 ——
    /// 断言的正是「这一项被正确注册进了菜单」
    func testFileMenuCarriesCheckIntegrityWithOptionCommandV() throws {
        _ = try requireMenu()
        let title = L10n.tr("app.menu.checkIntegrity")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
    }

    /// 缩略图网格(⇧⌘G,v1.1 2026-09-18)。取「Grid」的联想键 ——
    /// ⌥⌘G 已给「跳转到页」,两者是一对(知道页号去 / 看看有什么再点)。
    /// 它只在阅读态可用(disabled),但 keyEquivalent 与 disabled 无关 ——
    /// 断言的正是「这一项被正确注册进了菜单」
    func testViewMenuCarriesThumbnailGridWithShiftCommandG() throws {
        _ = try requireMenu()
        let title = L10n.tr("app.menu.thumbnailGrid")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "g")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    /// 连续滚动(⌘0,v2 候选池最后一项 2026-09-21)。取 ⌘0 而不是 ⌘7:
    /// 数字键 3–6 已被缩放档位占满,而 0 与「单页 ⌘1 / 双页 ⌘2」**物理相邻**,
    /// 菜单里同属「怎么排」那一组(分隔线与「怎么缩放」那组隔开)。
    /// 放在 7 会让它看起来属于缩放那一组 —— 而它在滚动模式下恰好是灰的
    func testViewMenuCarriesContinuousScrollWithCommand0() throws {
        _ = try requireMenu()
        let title = L10n.tr("reader.layout.scroll")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "0")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
    }

    /// 导出本卷页文件(⇧⌘E,2026-09-21)。取「Export」的联想键:
    /// ⇧⌘S 不行(它已被系统「存储为…」占着),而 ⇧⌘E 与 ⌘S(另存当前页)
    /// 在字母上就分得清 —— 一个存眼前这一摊,一个导出整卷。
    /// 它只在阅读态可用(disabled),但 keyEquivalent 与 disabled 无关 ——
    /// 断言的正是「这一项被正确注册进了菜单」
    func testFileMenuCarriesExportPagesWithShiftCommandE() throws {
        _ = try requireMenu()
        let title = L10n.tr("app.menu.exportPages")
        let item = try XCTUnwrap(menuItem(titled: title), "菜单里找不到「\(title)」")
        XCTAssertEqual(item.keyEquivalent, "e")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    // MARK: - 既有命令不许在重构里掉队

    /// M3 验收标准「纯键盘可完成全部操作」的可执行版本:逐个点名常用命令
    func testKeyboardReachableCommandsAreAllPresent() throws {
        _ = try requireMenu()
        let expected = [
            "app.menu.open",
            "reader.layout.single", "reader.layout.dual", "reader.layout.scroll",
            "app.menu.coverAlone",
            "reader.direction.ltr", "reader.direction.rtl",
            "app.menu.firstPage", "app.menu.lastPage", "app.menu.jumpToPage",
            "app.menu.thumbnailGrid",
            "reader.fit.window", "reader.fit.width", "reader.fit.height", "reader.fit.actual",
            "app.menu.addBookmark", "app.menu.previousBookmark", "app.menu.nextBookmark",
            "app.menu.saveCurrentPage", "app.menu.exportPages", "app.menu.revealInFinder",
            "app.menu.unlock",
            "app.menu.checkIntegrity",
        ]
        for key in expected {
            let title = L10n.tr(key)
            XCTAssertNotNil(menuItem(titled: title), "菜单项缺失:\(key)(「\(title)」)")
        }
    }

    /// 常用命令都必须**带**快捷键(只有一个例外:标题会随状态变化的书签开关,
    /// 它在已标记时标题变成「取消书签」,因此按两个候选标题分别找)
    func testCommonCommandsCarryShortcuts() throws {
        _ = try requireMenu()
        let keys = [
            "app.menu.open", "reader.layout.single", "reader.layout.dual", "reader.layout.scroll",
            "reader.direction.ltr", "reader.direction.rtl",
            "app.menu.firstPage", "app.menu.lastPage", "app.menu.jumpToPage",
            "app.menu.thumbnailGrid",
            "reader.fit.window", "reader.fit.width", "reader.fit.height", "reader.fit.actual",
            "app.menu.nextBookmark", "app.menu.previousBookmark",
            "app.menu.saveCurrentPage", "app.menu.exportPages", "app.menu.revealInFinder",
            "app.menu.unlock",
            "app.menu.checkIntegrity",
        ]
        for key in keys {
            let title = L10n.tr(key)
            let item = try XCTUnwrap(menuItem(titled: title))
            XCTAssertFalse(item.keyEquivalent.isEmpty,
                           "「\(title)」没有快捷键 —— 多半是它和另一个命令撞了同一个组合:"
                           + "系统会**静默清空**后来者的 keyEquivalent(按下去没反应,也不报错)")
        }
    }

    // MARK: - 快捷键不许撞车

    /// 同一组 (字符, 修饰键) 只允许出现一次 —— 撞车的表现是"其中一个按了没反应",
    /// 而系统不会给出任何提示(2026-09-16 加 ⇧⌘F 时正因如此才显式检查:
    /// ⇧⌘R 已被「从右往左读」占用)
    func testKeyboardShortcutsAreUnique() throws {
        var seen: [String: String] = [:]
        var conflicts: [String] = []
        for item in try requireMenu() where !item.keyEquivalent.isEmpty {
            let modifiers = item.keyEquivalentModifierMask
            let signature = "\(modifiers.rawValue)-\(item.keyEquivalent)"
            if let existing = seen[signature] {
                conflicts.append("「\(existing)」与「\(item.title)」都用 \(description(of: signature))")
            } else {
                seen[signature] = item.title
            }
        }
        XCTAssertTrue(conflicts.isEmpty, "快捷键冲突:\n" + conflicts.joined(separator: "\n"))
    }

    private func description(of signature: String) -> String {
        let parts = signature.split(separator: "-", maxSplits: 1)
        let mask = NSEvent.ModifierFlags(rawValue: UInt(parts.first ?? "0") ?? 0)
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + (parts.count > 1 ? String(parts[1]) : "")
    }

    // MARK: - 快捷键清单(帮助面板 / 空态小抄)必须与真实菜单一致

    /// `ShortcutCatalog` 是「帮助 → 键盘快捷键…」面板与空态小抄的展示源。
    /// 它**是手抄的**(从 `UnrollApp.commands` 抄一份) —— 手抄本身不是问题,
    /// **抄完没人钉**才是:那份清单错了用户会一直照着看,而没有任何东西会报错。
    ///
    /// 所以这里把真实菜单项的 (keyEquivalent, modifierMask) 格式化成同一个
    /// 「⌃⌥⇧⌘ + 键位」串,与清单里的字面量**逐字对照** —— 改菜单忘改清单、
    /// 改清单忘改菜单,两个方向的分叉都当场红(2026-09-22)
    func testShortcutCatalogMatchesTheRealMenu() throws {
        _ = try requireMenu()
        let items = ShortcutCatalog.verifiableItems
        XCTAssertFalse(items.isEmpty, "清单空了 —— 这条对照测试会退化成空转")
        for item in items {
            let title = L10n.tr(item.id)
            guard let menu = menuItem(titled: title) else {
                XCTFail("快捷键清单里有「\(title)」(\(item.id)),但菜单里没有这一项")
                continue
            }
            XCTAssertEqual(combination(of: menu), item.shortcut,
                           "「\(title)」的组合键与清单不符"
                           + "(菜单=\(combination(of: menu)),清单=\(item.shortcut))")
        }
    }

    /// 帮助菜单(2026-09-22)。macOS 用户的肌肉记忆是「不知道就翻菜单栏 Help」,
    /// 而这里原先**什么都没有**。三项都要在,且各自的键位约定要对:
    ///   · 键盘快捷键… 带 ⌘?(系统惯例:⇧/ 打出 ?);
    ///   · 显示阅读提示 **刻意不带键位**;
    ///   · 项目主页只是打开链接。
    /// **顺序也钉住**:三个入口的排列就是「看全部 → 重看那一条 → 去主页」。
    func testHelpMenuCarriesItsThreeEntriesInOrder() throws {
        _ = try requireMenu()
        let shortcutTitle = L10n.tr("help.menu.shortcuts")
        let menu = try XCTUnwrap(menuItem(titled: shortcutTitle)?.menu,
                                 "菜单栏里找不到帮助菜单(「\(shortcutTitle)」不在任何子菜单里)")

        // 帮助菜单里还有系统自己塞的项(搜索框等),所以只断言"我们这三项都在,且相对顺序对"
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        let tipsTitle = L10n.tr("help.menu.showTips")
        let homeTitle = L10n.tr("help.menu.homepage")
        let positions = [shortcutTitle, tipsTitle, homeTitle].compactMap { titles.firstIndex(of: $0) }
        XCTAssertEqual(positions.count, 3, "帮助菜单里缺项,实际是:\(titles)")
        if positions.count == 3 {
            XCTAssertEqual(positions, positions.sorted(), "帮助菜单三项的顺序变了:\(titles)")
        }

        let shortcutItem = try XCTUnwrap(menuItem(titled: shortcutTitle))
        XCTAssertEqual(shortcutItem.keyEquivalent, "?")
        XCTAssertEqual(shortcutItem.keyEquivalentModifierMask, .command)

        // ⚠️ 「没有键位」是**设计决定**,不是遗漏:快捷键清单的口径是
        //    「带 ⌘ 的命令 + 纯手势」,`ShortcutCatalog` 正是照这个口径手抄的。
        //    哪天给它配了键位,这条会红 —— 提醒你同时把它加进清单,
        //    否则清单就不再是"完整的"了(而它存在的意义恰恰是完整)
        let tipsItem = try XCTUnwrap(menuItem(titled: tipsTitle), "帮助菜单里缺少「\(tipsTitle)」")
        XCTAssertTrue(tipsItem.keyEquivalent.isEmpty,
                      "「\(tipsTitle)」不该有快捷键 —— 配了就得同时进 Core/ShortcutCatalog")
    }

    /// 快捷键清单的**成清单口径**:凡带 ⌘ 的条目都在菜单栏里有对应项,
    /// 不带 ⌘ 的那 5 条恰恰都没有(它们是画布手势)。
    ///
    /// 面板的说明文字 `help.shortcuts.subtitle` 就写在这条恒等式上
    /// (「带 ⌘ 的都能在菜单栏里找到」)——2026-09-22 之前它写的是
    /// 「下面这些都能在菜单栏里找到」,而那对手势那组是假话。
    /// 文字本身没法被断言,能断言的是它依赖的这个事实
    func testCatalogMenuFlagsMatchTheCommandKey() {
        for item in ShortcutCatalog.groups.flatMap(\.items) {
            XCTAssertEqual(item.shortcut.contains("⌘"), item.hasMenuItem,
                           "\(item.id):组合串「\(item.shortcut)」与 hasMenuItem="
                           + "\(item.hasMenuItem) 不符(带 ⌘ 就该有菜单项;没有菜单项就不该带 ⌘)")
        }
    }

    /// 清单里每个 id 都必须**真的取到文案**。
    /// `NSLocalizedString` 对缺失的 key 会**原样回退成 key 串** ——
    /// 于是 `tr(id) != id` 正好是「这个 key 真的在 strings 里」的判据。
    /// 对没进菜单的那 5 条尤其要紧:它们没有对照物,漏文案不会被别的测试逮到
    func testEveryShortcutCatalogEntryHasLocalizedText() {
        for group in ShortcutCatalog.groups {
            XCTAssertNotEqual(L10n.tr(group.id), group.id, "缺少分组文案:\(group.id)")
            for item in group.items {
                XCTAssertNotEqual(L10n.tr(item.id), item.id, "缺少文案:\(item.id)")
                XCTAssertFalse(item.shortcut.isEmpty, "\(item.id) 的组合串是空的")
            }
        }
    }

    // MARK: - 组合串格式化(与 ShortcutCatalog 同一口径)

    /// 把菜单项格式化成 `ShortcutCatalog` 里那种组合串(⌃⌥⇧⌘ 固定顺序 + 键位)
    private func combination(of item: NSMenuItem) -> String {
        var text = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + keyLabel(item.keyEquivalent)
    }

    /// 键位的人类可读形式。方向键在 AppKit 里是 Unicode 私有区的字符
    /// (`NSUpArrowFunctionKey` 等),原样打出来是一串乱码 —— 必须映射,
    /// 否则 ⇧⌘↑ / ⇧⌘↓ 那两条会被判成"不一致"
    private func keyLabel(_ raw: String) -> String {
        switch raw {
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        default: return raw.uppercased()
        }
    }
}
