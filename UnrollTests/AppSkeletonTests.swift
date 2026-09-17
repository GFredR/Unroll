// AI-Generated | 可修改
// AppSkeletonTests —— 基础设施烟囱测试(宿主为 App,§6.2)
// ----------------------------------------------------------------------------
// 验证两条基础设施链路真的通了:
//   1. L10n:本地化表已挂载,key 缺失能第一时间发现(M0 锁占位 key,
//      M2 起锁阅读器首屏 key —— 占位页已按其注释约定删除);
//   2. DesignSystem:Token 常量可访问(防止有人把 Token 删了导致连锁问题)。
// M2 起本目录扩展:PageCacheTests / ReaderViewModelTests / PageStoreTests。
import XCTest
@testable import Unroll

final class AppSkeletonTests: XCTestCase {

    func testL10nResolvesReaderKeys() {
        // key 缺失时 NSLocalizedString 会原样返回 key 本身 —— 据此断言表已挂载
        XCTAssertNotEqual(L10n.tr("app.name"), "app.name")
        XCTAssertNotEqual(L10n.tr("reader.empty.title"), "reader.empty.title")
        XCTAssertFalse(L10n.tr("reader.empty.hint").isEmpty)
        XCTAssertNotEqual(L10n.tr("archive.corrupted.title"), "archive.corrupted.title")
        XCTAssertFalse(L10n.tr("app.name").isEmpty)
    }

    func testPageBudgetTokensAreSane() {
        // §5.3 双阈值:≤8 页 且 ≤2 亿像素,任一超出即 LRU 淘汰
        XCTAssertEqual(DesignSystem.PageBudget.maxCachedPages, 8)
        XCTAssertEqual(DesignSystem.PageBudget.maxPixels, 200_000_000)
        // M2 补充:Trimmed 缩略图上限与长边(见 DesignSystem 注释的取值理由)
        XCTAssertGreaterThan(DesignSystem.PageBudget.maxThumbnails, DesignSystem.PageBudget.maxCachedPages)
        XCTAssertEqual(DesignSystem.PageBudget.thumbnailLongEdge, 1600)
        // 2026-09-17:缩略图**像素**预算。不锁具体数字,锁两条不变量 ——
        // 数字会随手感调,不变量不该跟着动
        let worstCaseThumbPixels = Int(DesignSystem.PageBudget.thumbnailLongEdge
                                       * DesignSystem.PageBudget.thumbnailLongEdge)
        // ① 至少装得下两张「最坏缩略图」(正方形 = 长边定义的上限)。
        //    装不下就会「刚降级即被淘汰」,Trimmed 语义(翻回来不白屏)当场失效
        XCTAssertGreaterThanOrEqual(DesignSystem.PageBudget.maxThumbnailPixels,
                                    worstCaseThumbPixels * 2)
        // ② 缩略图池必须**明显小于**全分辨率池:它只是垫图,
        //    不该长成第二个大池子 —— 那正是 2026-09-17 修掉的那个缺口
        XCTAssertLessThan(DesignSystem.PageBudget.maxThumbnailPixels,
                          DesignSystem.PageBudget.maxPixels / 4)
    }
}
