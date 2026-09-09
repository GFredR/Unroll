// AI-Generated | 可修改
// AppSkeletonTests —— M0 骨架烟囱测试(宿主为 App,§6.2)
// ----------------------------------------------------------------------------
// M0 只验证两条基础设施链路真的通了:
//   1. L10n:本地化表已挂载,key 缺失能第一时间发现;
//   2. DesignSystem:Token 常量可访问(防止有人把 Token 删了导致编译期之外的连锁问题)。
// M2 起本目录扩展:ReaderViewModel 状态机分支(成功/失败/边界,AGENTS.md 九.1)。
import XCTest
@testable import Unroll

final class AppSkeletonTests: XCTestCase {

    func testL10nResolvesPlaceholderKeys() {
        // key 缺失时 NSLocalizedString 会原样返回 key 本身 —— 据此断言表已挂载
        XCTAssertNotEqual(L10n.tr("app.name"), "app.name")
        XCTAssertNotEqual(L10n.tr("placeholder.title"), "placeholder.title")
        XCTAssertFalse(L10n.tr("app.name").isEmpty)
    }

    func testPageBudgetTokensAreSane() {
        // §5.3 双阈值:≤8 页 且 ≤2 亿像素,任一超出即 LRU 淘汰
        XCTAssertEqual(DesignSystem.PageBudget.maxCachedPages, 8)
        XCTAssertEqual(DesignSystem.PageBudget.maxPixels, 200_000_000)
    }
}
