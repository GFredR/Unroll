// AI-Generated | 可修改
// WindowGeometry —— 窗口尺寸/位置记忆:纯几何 + 自管存储(2026-09-24)
// ----------------------------------------------------------------------------
// 为什么"自管"而不是交给系统 —— 两条系统路都实测过,**都不生效**:
//   ① AppKit `window.setFrameAutosaveName("UnrollMainWindow")`:
//      `NSWindow Frame UnrollMainWindow` 这个键**从未出现过**(逐键检查容器 plist)。
//   ② SwiftUI 自己派生的 `NSWindow Frame SwiftUI.…` 键:键名里含**一次性的代码地址**
//      (`…ModifiedContent<(unknown context at $10b1fce30).WindowChrome>…`),
//      于是**每次启动都是新键** ⇒ 系统永远读不到"上次"。
//      取证:`Scripts/probe-window-memory.sh`(同一二进制连启两次,frame 键数 20 → 21 → 22);
//      第二条独立证据:`Saved Application State/` 目录**是空的**。
// 于是改用一个**固定键**存 4 个数字,与视图修饰符链彻底解耦。
//
// 隐私:只存窗口几何(4 个数字),不含文档名/路径 —— 与最近打开同一条基线。
//
// 本文件全是**纯函数 + 纯存储**,不碰 AppKit。理由:唯一不可单测的那部分被压到
// `UnrollApp.swift` 那个几十行的粘合层(什么时候读、什么时候写),而"该不该夹、
// 夹到哪、跨屏怎么办"这些真正会出错的判断都在这儿,可以逐条断言。
import CoreGraphics
import Foundation

/// 窗口几何。坐标系 = **AppKit 屏幕坐标**(原点在主屏左下角,y 向上)——
/// 不写成 `CGRect` 的别名,是因为要把语义钉住:`NSScreen.visibleFrame` 与
/// `NSWindow.frame` 都在这个空间里,调用方直接传 `CGRect` 即可,不需要转换层
struct WindowGeometry: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// 窗口记忆的**判据层**(纯函数)。
enum WindowMemory {

    /// 把「上次存下的几何」解析成「这次该用的几何」。
    ///
    /// 返回 `nil` = **不干预**(让 `.defaultSize` 说了算)。三种情况:
    /// 没有记录 / 拿不到屏幕信息 / 记录是坏值(解不出来就当作没有)。
    ///
    /// ⚠️「拿不到屏幕信息时不动窗口」是刻意的:那段信息缺失说明我们对环境一无所知,
    /// 此时**照搬一个可能落在屏外的坐标**比什么都不做更糟 —— 用户会看到窗口"消失"。
    ///
    /// 四步,顺序不能换(每一步都在改后一步的输入):
    /// ① 尺寸抬到最小值 —— 记录可能来自**更小最小值的版本**
    ///    (本批 880×600 → 900×600 就是活样本:用户拖出来的 890 宽窗口,
    ///     在最小值抬高之后不该以 890 被恢复)
    /// ② 尺寸压进归属屏 —— 换过小屏之后,存下来的大窗口会大到"拖动把手都在屏外"
    /// ③ 选归属屏 —— 与窗口重叠面积最大的那块(外接屏被拔掉的情形见 `bestScreen`)
    /// ④ 位置夹进归属屏 —— 一条**有代价的**取舍,代价见下
    ///
    /// ⚠️ ④ 的代价要写明白:夹的是"整个窗口进屏",不是"露一角即可"。
    /// 于是**用户故意摆到屏外一半的位置不会被记住**(下次启动会被拉回来)。
    /// 取舍理由:标题栏是唯一的拖动把手,只露一条边在屏外的窗口在下次启动时
    /// 是"用户自己都找不回来"的状态;代价只是"故意摆出去的位置会回来"。
    /// 代价真实存在,所以登记在案(测试文档 §23.3),不假装没有。
    ///
    /// ⚠️ 极端情形不修,但要说清:若**屏本身比最小值还小**(宽 800 却最小 900),
    /// ② 会让尺寸落到最小值以下。这里选"以屏为准" —— 用户更需要看得见窗口,
    /// 而 SwiftUI 的 `.frame(minWidth:minHeight:)` 之后还会再夹一次,
    /// 两者合力 = 窗口比屏略宽,仍在屏内可拖。真实机器上到不了这一步。
    static func resolve(saved: WindowGeometry?,
                        screens: [CGRect],
                        minSize: CGSize) -> WindowGeometry? {
        guard let saved else { return nil }
        guard !screens.isEmpty else { return nil }
        guard let home = bestScreen(for: saved.rect, screens: screens) else { return nil }

        let width = min(max(saved.width, minSize.width), home.width)
        let height = min(max(saved.height, minSize.height), home.height)
        // 尺寸已被 ①② 压进归属屏,故下面两个区间一定非空(`home.maxX - width ≥ home.minX`)——
        // 区间不会写反,`min(max(...))` 不需要再兜一层
        let x = min(max(saved.x, home.minX), home.maxX - width)
        let y = min(max(saved.y, home.minY), home.maxY - height)
        return WindowGeometry(x: x, y: y, width: width, height: height)
    }

    /// 归属屏 = 与 `rect` **重叠面积最大**的那块可见区。
    ///
    /// 完全不重叠时(典型:外接屏被拔掉,记录里还留着那块屏的坐标)退回**第一块** ——
    /// `NSScreen.screens[0]` 就是菜单栏所在的主屏。这条兜底不能省:
    /// 返回 `nil` 等于"外接屏一拔,窗口稳定出现在屏外"。
    ///
    /// 面积相等时取**先出现**的那块(严格大于比较)。刻意不用 `max(by:)`:
    /// 两块屏面积相同时它的胜者不保证,而这条判据要可复现。
    static func bestScreen(for rect: CGRect, screens: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? screens.first
    }
}

/// 自管存储:一个**固定键** + 一段 JSON。与 `ReadingProgress` 同款
/// (注入 defaults、全链路 `try?` 静默容错 —— 记忆失败绝不该影响开窗)。
///
/// 键里带版本号(`.v1`):将来若几何的含义变了(比如改成存内容区而不是窗口框),
/// 换键就能让老记录自然失效,不必写迁移代码。
struct WindowFrameStore {

    static let key = "window.frame.v1"

    private let defaults: UserDefaults

    /// defaults 可注入(单测用 suite);生产用 standard(沙盒下 = 本 App 的容器)
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WindowGeometry? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(WindowGeometry.self, from: data)
    }

    func save(_ geometry: WindowGeometry) {
        guard let data = try? JSONEncoder().encode(geometry) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// 清掉记忆。生产路径上**没有**调用点(没有「重置窗口位置」菜单项,那是 v2 的事)。
    /// 它存在是为了探针的**负向对照**:`Scripts/probe-window-memory.sh` 要能造出
    /// "没有记忆"的对照态 —— 否则"重启后回到原处"这条结论分不清是"记忆生效"
    /// 还是"碰巧一样"
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
