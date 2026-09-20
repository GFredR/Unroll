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

    func testGridThumbnailBudgetIsNotJustACount() {
        // v1.1 网格缩略图池(第三个池)。同一个教训第三次出现:
        // 2026-09-17 修的是「Trimmed 池只限张数」,本池若照抄个数上限等于没限 ——
        // 单张像素随长宽比浮动,而 `gridThumbnailLongEdge` 卡的是**长边**。
        // 这里只锁不变量、不锁数字(数字会随手感调,不变量不该跟着动)。
        typealias Budget = DesignSystem.PageBudget
        let worstCasePage = Int(Budget.gridThumbnailLongEdge * Budget.gridThumbnailLongEdge)

        // ① 对**最坏页型(正方形)**像素上限必须**先**到顶。否则像素预算是摆设,
        //    个数上限会一路放行到 600 × 最坏单张 ≈ 39 Mpx —— 悄悄涨成全分辨率池的三分之一
        XCTAssertLessThan(Budget.maxGridThumbnailPixels / worstCasePage,
                          Budget.maxGridThumbnails)

        // ② 反过来,对**细长页(约 1:3)**个数上限必须**先**到顶,否则个数上限是死代码。
        //    两个方向都要留:只留个数漏掉更贵的方页,只留像素漏掉更省的细长页
        let slenderPage = Int(Budget.gridThumbnailLongEdge / 3) * Int(Budget.gridThumbnailLongEdge)
        XCTAssertLessThan(Budget.maxGridThumbnails * slenderPage, Budget.maxGridThumbnailPixels)

        // ③ 第三池与降级池**差一个数量级**(单张长边小 4 倍以上、张数多一个量级)——
        //    这正是「不能共用一个池」的理由:共用必然互相挤爆
        XCTAssertLessThanOrEqual(Budget.gridThumbnailLongEdge * 4, Budget.thumbnailLongEdge)
        XCTAssertGreaterThan(Budget.maxGridThumbnails, Budget.maxThumbnails * 4)

        // ④ 网格池不能长成第二个大池子(与全分辨率池的关系)
        XCTAssertLessThan(Budget.maxGridThumbnailPixels, Budget.maxPixels / 4)

        // ⑤ 跳转预览长边夹在中间:比网格格子大(要能认清是不是这一页)、
        //    比降级图小(它只是"确认一下",不进任何池子)
        XCTAssertGreaterThan(Budget.jumpPreviewLongEdge, Budget.gridThumbnailLongEdge)
        XCTAssertLessThan(Budget.jumpPreviewLongEdge, Budget.thumbnailLongEdge)
    }
}
