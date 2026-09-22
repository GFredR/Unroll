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
}
