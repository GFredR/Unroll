// AI-Generated | 可修改
// ReaderTipsTests —— 一次性提示标记(2026-09-22)
// ----------------------------------------------------------------------------
// 全部走注入的 UserDefaults(suiteName:),不碰生产配置。
// 除了读写语义,这里还钉住一条**隐私性质**:这个存储只该有 1 个布尔键。
// 「只存布尔」是写在 Core/ReaderTips.swift 顶部的一句承诺 ——
// 承诺没有判据就会在未来某次"顺手多存一个字段"里悄悄过期。
import XCTest
@testable import Unroll

final class ReaderTipsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ReaderTipsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 读写语义

    /// key 缺失 = "没见过"。**不能**反过来(缺省当成见过)——
    /// 那样第一次打开文档时提示条永远不出现,而且没有任何报错
    func testFreshStoreHasNotShown() {
        XCTAssertFalse(ReaderTips(defaults: defaults).hasShownHintBar)
    }

    func testMarkFlipsToShownAndSurvivesANewInstance() {
        ReaderTips(defaults: defaults).markHintBarShown()
        // 换一个实例读(模拟下次启动):标记必须真的落了盘,不是内存里的假象
        XCTAssertTrue(ReaderTips(defaults: defaults).hasShownHintBar)
    }

    func testMarkTwiceKeepsShown() {
        let tips = ReaderTips(defaults: defaults)
        tips.markHintBarShown()
        tips.markHintBarShown()
        XCTAssertTrue(tips.hasShownHintBar)
    }

    // MARK: - 隐私性质(可核对,不是口号)

    /// 「只存一个布尔」—— 键名与类型都钉住。
    /// 将来有人往这里加一个字段(尤其是路径/文件名那种),这条会当场红
    func testStoreWritesExactlyOneBooleanKey() {
        ReaderTips(defaults: defaults).markHintBarShown()

        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(domain.count, 1,
                       "提示存储只该有 1 个键,实际:\(domain.keys.sorted())")
        XCTAssertEqual(domain["reader.tips.hintShown"] as? Bool, true,
                       "唯一那个键必须是布尔且为 true")
    }
}
