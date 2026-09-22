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

    /// 两份 `Localizable.strings` 的**键集合必须完全相等**(2026-09-21)。
    ///
    /// 这条以前是靠人手 `plutil` 比出来的(2026-09-20 那次记了「两份各 108 条、
    /// 键一一对应」),而它恰好是一条**只加代码不会失败**的缺口:
    /// 给菜单加一项、只往中文表补了译文,英文用户看到的就是菜单里那一行写着
    /// `reader.layout.scroll` —— 一个键名。没有崩溃、没有日志、测试全绿。
    ///
    /// 读**源码文件**而不是构建产物:这样在编译之前就能拦下,
    /// 而不是等有人切到英文再肉眼发现(顺带也免了「产物里是 UTF-16」那件事)
    ///
    /// ⚠️ **必须先把块注释剥掉**(2026-09-22 补):键的识别规则是"行首(去空白后)
    /// 是双引号",而注释里**行首恰好是引号**的那一行会被当成一个键。实测撞上的是
    /// 一句英文注释,断行后以 `"everything below"` 开头 —— 于是这条测试报
    /// "中文表缺 everything below 这个键",而它根本不是一个键。
    /// 那属于**把正常状态说成故障**,并且给出的修法方向是错的(去中文表里找一个
    /// 不存在的东西)。所以修的是提取器,不是把那句注释改掉
    func testLocalizationTablesCarryTheSameKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnrollTests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Unroll/Resources")
        let tables = ["en", "zh-Hans"].map {
            root.appendingPathComponent("\($0).lproj/Localizable.strings")
        }
        guard tables.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("本地化源文件不可达(疑似测试宿主沙盒限制)")
        }

        func keys(_ url: URL) throws -> Set<String> {
            let text = try String(contentsOf: url, encoding: .utf8)
            var result: Set<String> = []
            for line in Self.withoutComments(text).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""),
                      let closing = trimmed.dropFirst().firstIndex(of: "\"") else { continue }
                result.insert(String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing]))
            }
            return result
        }

        let en = try keys(tables[0])
        let zh = try keys(tables[1])
        XCTAssertFalse(en.isEmpty, "英文表一个键都没读到 —— 多半是解析或路径坏了")

        // 两个方向分开报:只说"不相等"的话,拿到报错的人还得自己找出是哪几个
        XCTAssertEqual(en.subtracting(zh), [], "中文表缺这些键(英文用户看得到、中文用户看到键名):")
        XCTAssertEqual(zh.subtracting(en), [], "英文表缺这些键(反向的同一个问题):")
    }

    /// 反向测试:上面的键提取必须真的**不受注释里行首引号**影响。
    /// 没有它,这条守卫会在下次有人写一句带引号的注释时又变成假故障
    func testCommentStrippingKeepsQuotedCommentLinesOutOfTheKeySet() {
        let sample = """
        /* 说明:下面这一行**行首就是引号** —— 它不是一个键
        "not a key" = "x";
        */
        "real.key" = "值";
        """
        let stripped = Self.withoutComments(sample)
        XCTAssertFalse(stripped.contains("not a key"), "注释里行首带引号的那一行没被剥掉")
        XCTAssertTrue(stripped.contains("\"real.key\""), "真键被误剥了")
    }

    /// 去掉 `.strings` 里的 `/* … */` 块注释(换行保留,免得行结构变样)。
    ///
    /// 为什么逐字符而不是正则:要处理的只有"在注释里 / 不在注释里"两态,
    /// 而这段文本同时含中文、`"`、`*`、`/` —— 逐字符走一遍最不容易出错,
    /// 也不必让正则引擎去猜编码。注释不嵌套,所以再遇到 `/*` 照旧进入注释态
    private static func withoutComments(_ text: String) -> String {
        var out = ""
        var inside = false
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if !inside, text[index] == "/", next < text.endIndex, text[next] == "*" {
                inside = true
                index = text.index(after: next)
                continue
            }
            if inside, text[index] == "*", next < text.endIndex, text[next] == "/" {
                inside = false
                index = text.index(after: next)
                continue
            }
            if inside {
                if text[index] == "\n" { out.append("\n") }
            } else {
                out.append(text[index])
            }
            index = next
        }
        return out
    }

    /// 连续滚动的**活跃窗口**必须留在全分辨率池的规模之内(2026-09-21)。
    ///
    /// 这是本项目第四次修同一个形状的问题,但这次的落点最隐蔽:
    /// 前面三次(Trimmed 池、网格池、网格像素)都能在 `PageCache` 的账本里查到;
    /// 而滚动模式下**行视图自己攥着 `CGImage`** —— 引用计数在视图手上,
    /// `PageCache` 无论怎么淘汰都收不回来。也就是说:
    /// 「LazyVStack 会回收看不见的行」这句话**不能当内存上限用**,
    /// 真正能当上限的是这个窗口 + 行主动置空。
    ///
    /// 只锁不变量,不锁数字:窗口是手感参数(大小会调),但**它和页缓存的关系不该变**
    func testScrollActiveWindowStaysWithinPageCacheBudget() {
        typealias Budget = DesignSystem.PageBudget
        // 窗口是「锚点两侧各 N 行」→ 同时驻留 2N+1 行(每行一页)
        let residentPages = Budget.scrollActiveWindow * 2 + 1

        // ① 驻留行数 ≤ 全分辨率池本来的页数上限 —— 滚动模式不许当那个
        //    「偷偷把内存涨上去」的例外。调大到 4 就变成 9 行,当场被拦下
        XCTAssertLessThanOrEqual(residentPages, Budget.maxCachedPages)

        // ② 窗口至少要盖住一屏多一点:两侧各留一行,滚动时下面那张才不至于
        //    刚进视野才开始解码(那样每次滚动都会先看到一次占位框)
        XCTAssertGreaterThanOrEqual(Budget.scrollActiveWindow, 2)
    }
}
