// AI-Generated | 可修改
// WindowGeometryTests —— 窗口尺寸/位置记忆(2026-09-24)
// ----------------------------------------------------------------------------
// 这一组测的是**判据层**(`WindowMemory.resolve` / `bestScreen`)与**存储层**
// (`WindowFrameStore`),不碰 AppKit:屏幕列表是参数,所以「外接屏被拔掉」
// 「换到小屏」「存的尺寸比最小值还小」这些真实场景在单测里都能造出来。
//
// 不可单测的那一小块(什么时候读、什么时候写)在 `UnrollApp.swift` 的
// `WindowChrome` 里,由 `Scripts/probe-window-memory.sh` 端到端取证 ——
// 两者是**互补**的:这里锁判据,那边锁"判据真的被接上了"。
import XCTest
@testable import Unroll

final class WindowGeometryTests: XCTestCase {

    /// 单测里的"屏幕":主屏 1280×775 可见区(AppKit 的可见区已扣掉菜单栏/程序坞)
    private let mainScreen = CGRect(x: 0, y: 0, width: 1280, height: 775)
    /// 外接屏:贴在主屏右侧,更大
    private let externalScreen = CGRect(x: 1280, y: 0, width: 1920, height: 1080)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.windowframe.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 存储层

    /// 存 → 取往返一致(四个数字一个不差)
    func testStoreRoundtrip() {
        let store = WindowFrameStore(defaults: defaults)
        let geometry = WindowGeometry(x: 12, y: 34, width: 900, height: 600)

        store.save(geometry)

        XCTAssertEqual(store.load(), geometry)
    }

    /// 没有记录 → nil(而不是某个默认值:默认值由 `.defaultSize` 负责,
    /// 存储层**不该**替它说话)
    func testStoreLoadsNilWhenNothingSaved() {
        XCTAssertNil(WindowFrameStore(defaults: defaults).load())
    }

    /// 坏值 → nil。这条防的是"用户不该看见的崩溃":解码失败必须静默当作没有记录
    func testStoreLoadsNilOnGarbageInsteadOfThrowing() {
        let store = WindowFrameStore(defaults: defaults)
        defaults.set(Data("这不是 JSON".utf8), forKey: WindowFrameStore.key)

        XCTAssertNil(store.load())
    }

    /// clear 之后取不到 —— 探针的**负向对照**依赖这一条
    func testStoreClearRemovesTheRecord() {
        let store = WindowFrameStore(defaults: defaults)
        store.save(WindowGeometry(x: 1, y: 2, width: 3, height: 4))

        store.clear()

        XCTAssertNil(store.load())
    }

    /// 覆盖写:后一次为准(用户每次拖完都写,不能攒着)
    func testStoreOverwritesPreviousRecord() {
        let store = WindowFrameStore(defaults: defaults)
        store.save(WindowGeometry(x: 0, y: 0, width: 900, height: 600))
        store.save(WindowGeometry(x: 40, y: 30, width: 940, height: 640))

        XCTAssertEqual(store.load(), WindowGeometry(x: 40, y: 30, width: 940, height: 640))
    }

    // MARK: - resolve:三种"不干预"

    /// 没有记录 → nil = 不干预(交回 `.defaultSize`)
    func testResolveReturnsNilWithoutRecord() {
        XCTAssertNil(WindowMemory.resolve(saved: nil, screens: [mainScreen],
                                          minSize: CGSize(width: 900, height: 600)))
    }

    /// 拿不到屏幕信息 → nil。**不能照搬坐标**:那时我们对环境一无所知,
    /// 照搬可能把窗口放到屏外,用户看到的是"窗口消失了"
    func testResolveReturnsNilWithoutScreens() {
        let saved = WindowGeometry(x: 0, y: 0, width: 960, height: 640)
        XCTAssertNil(WindowMemory.resolve(saved: saved, screens: [],
                                          minSize: CGSize(width: 900, height: 600)))
    }

    // MARK: - resolve:四种真实场景

    /// ① 普通情形:几何完全在屏内且不小于最小值 → **逐字不动**
    func testResolveKeepsGeometryThatAlreadyFits() {
        let saved = WindowGeometry(x: 100, y: 80, width: 960, height: 640)
        let resolved = WindowMemory.resolve(saved: saved, screens: [mainScreen],
                                            minSize: CGSize(width: 900, height: 600))
        XCTAssertEqual(resolved, saved)
    }

    /// ② 记录来自**更小最小值**的版本:890×590 要被抬到 900×600。
    /// 这正是本批 880×600 → 900×600 的活样本;位置不动(还没越界)
    func testResolveRaisesSizeToCurrentMinimum() {
        let saved = WindowGeometry(x: 100, y: 100, width: 890, height: 590)
        let resolved = WindowMemory.resolve(saved: saved, screens: [mainScreen],
                                            minSize: CGSize(width: 900, height: 600))
        XCTAssertEqual(resolved, WindowGeometry(x: 100, y: 100, width: 900, height: 600))
    }

    /// ③ 存下来的位置在屏外(比如外接屏被拔掉,记录还留着那块屏的坐标)——
    /// **必须拉回屏内**,否则窗口再也不会出现在用户眼前。
    /// 这里屏幕列表里只剩主屏,所以归属屏退回主屏(`bestScreen` 的兜底)
    func testResolvePullsBackWindowWhoseScreenIsGone() {
        let saved = WindowGeometry(x: 2000, y: 100, width: 800, height: 600)
        let resolved = WindowMemory.resolve(saved: saved, screens: [mainScreen],
                                            minSize: CGSize(width: 900, height: 600))

        // 尺寸先抬到最小值 900,再夹进主屏:x 的上界 = 1280 - 900 = 380
        XCTAssertEqual(resolved, WindowGeometry(x: 380, y: 100, width: 900, height: 600))
    }

    /// ④ 换到小屏:存的窗口比屏还大 → 压进屏;同时位置落到屏内左上角
    func testResolveShrinksWindowLargerThanScreen() {
        let saved = WindowGeometry(x: 0, y: 0, width: 1400, height: 900)
        let resolved = WindowMemory.resolve(saved: saved, screens: [mainScreen],
                                            minSize: CGSize(width: 900, height: 600))
        XCTAssertEqual(resolved, WindowGeometry(x: 0, y: 0, width: 1280, height: 775))
    }

    /// ⑤ 双屏:窗口在**外接屏**上 → 夹到外接屏,不许被拉回主屏
    /// (把归属屏选错,用户的窗口每次启动都会"跳屏"—— 这条就是防它)
    func testResolveClampsToOwningScreenNotMainScreen() {
        let saved = WindowGeometry(x: 1300, y: 100, width: 900, height: 600)
        let resolved = WindowMemory.resolve(saved: saved,
                                            screens: [mainScreen, externalScreen],
                                            minSize: CGSize(width: 900, height: 600))
        XCTAssertEqual(resolved, saved)
    }

    /// ⑥ 双屏 + 外接屏比记录矮:压到外接屏的高度,宽度不动;
    /// y 也要跟着落回屏内(压到 1080 高之后,原 y=100 会让顶边越界 ⇒ 归 0)
    func testResolveShrinksToExternalScreenHeight() {
        let saved = WindowGeometry(x: 1300, y: 100, width: 900, height: 1200)
        let resolved = WindowMemory.resolve(saved: saved,
                                            screens: [mainScreen, externalScreen],
                                            minSize: CGSize(width: 900, height: 600))
        XCTAssertEqual(resolved, WindowGeometry(x: 1300, y: 0, width: 900, height: 1080))
    }

    // MARK: - bestScreen

    /// 重叠面积最大者胜(不是"第一个相交的")
    func testBestScreenPicksLargestOverlap() {
        let rect = CGRect(x: 1000, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowMemory.bestScreen(for: rect,
                                               screens: [mainScreen, externalScreen]),
                       externalScreen)
    }

    /// 完全不重叠 → 退回**第一块**(`NSScreen.screens[0]` = 菜单栏所在的主屏)。
    /// 返回 nil 会让"外接屏拔掉之后"窗口稳定出现在屏外 —— 这条兜底不能省
    func testBestScreenFallsBackToFirstWhenNothingOverlaps() {
        let offScreen = CGRect(x: 9000, y: 9000, width: 800, height: 600)
        XCTAssertEqual(WindowMemory.bestScreen(for: offScreen,
                                               screens: [mainScreen, externalScreen]),
                       mainScreen)
    }

    /// 两块屏重叠面积**相等**时取先出现的那块 —— 结果只由输入顺序决定,**可复现**。
    /// 刻意不用 `max(by:)`:面积相同时它的胜者不保证,而这条判据要能复现
    func testBestScreenIsDeterministicOnTie() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        // 窗口横跨两屏边界,两边各重叠 100×600 —— 面积相等
        let straddling = CGRect(x: 900, y: 100, width: 200, height: 600)

        XCTAssertEqual(WindowMemory.bestScreen(for: straddling, screens: [left, right]), left)
        // 顺序反过来 → 胜者也反过来(证明"胜者 = 顺序",不是某块屏的固有属性)
        XCTAssertEqual(WindowMemory.bestScreen(for: straddling, screens: [right, left]), right)
    }

    // MARK: - WindowGeometry 与 CGRect 的互转

    /// `init(rect:)` / `rect` 互转不丢信息 —— 粘合层就是靠这一对
    /// 把 `NSWindow.frame` 换成可存的四个数字
    func testGeometryAndRectRoundTrip() {
        let rect = CGRect(x: 12.5, y: 34.25, width: 900, height: 600.75)
        XCTAssertEqual(WindowGeometry(rect: rect).rect, rect)
    }
}
