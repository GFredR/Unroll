// AI-Generated | 可修改
// RecentPresentationTests —— 最近打开展示层(2026-09-22)
// ----------------------------------------------------------------------------
// 菜单「打开最近」与空态欢迎页共用这一份拼装口径,所以这里测的是**两者共同的行为**。
// 断言刻意**不看具体文案**(文案由 §2.6 的键对齐用例把关),只钉住四件会咬人的事:
//   ① 页码换算:存储是 0-based,给人看是 1-based(差一错在这里没人会当场发现);
//   ② 失效后缀是**拼接**在进度之后,不是替换掉进度(否则"这书我读到哪了"就没了);
//   ③ 顺序与身份:菜单顺序 == 存储顺序(最近在前),ForEach 的身份必须稳定;
//   ④ 两条设计承诺:「欢迎页不是管理器」(空态上限 < 菜单上限)、
//      「展示模型只带文件名」(§5.10.4 红线) —— 承诺没有判据就会过期。
import XCTest
@testable import Unroll

final class RecentPresentationTests: XCTestCase {

    // MARK: - 夹具

    private func entry(name: String, id: UUID = UUID()) -> RecentDocuments.Entry {
        RecentDocuments.Entry(id: id, name: name, bookmark: Data())
    }

    private func progress(page: Int, total: Int?) -> ReadingProgress.Entry {
        ReadingProgress.Entry(page: page, layout: "single", direction: "ltr",
                              fitMode: "fit", updatedAt: Date(), total: total,
                              coverAlone: false)
    }

    /// 用**真实**的键格式(「名字|大小」)建索引,不手搓字符串
    private func index(_ name: String, _ saved: ReadingProgress.Entry,
                       size: Int = 1024) -> RecentProgressIndex {
        RecentProgressIndex(entries: [ReadingProgress.key(name: name, size: size): saved])
    }

    private let noProgress = RecentProgressIndex(entries: [:])

    // MARK: - ① 页码换算

    func testEntryWithoutProgressShowsJustTheFileName() {
        XCTAssertEqual(RecentPresentation.title(for: entry(name: "a.cbz"),
                                                progress: noProgress,
                                                staleIDs: []),
                       "a.cbz")
    }

    func testPageNumberIsOneBasedInTheTitle() {
        let name = "a.cbz"
        let first = RecentPresentation.title(for: entry(name: name),
                                             progress: index(name, progress(page: 0, total: 200)),
                                             staleIDs: [])
        XCTAssertTrue(first.contains("P.1/200"),
                      "存储 page=0 是给人看的第 1 页,实际:\(first)")

        let third = RecentPresentation.title(for: entry(name: name),
                                             progress: index(name, progress(page: 2, total: 200)),
                                             staleIDs: [])
        XCTAssertTrue(third.contains("P.3/200"),
                      "存储 page=2 是给人看的第 3 页,实际:\(third)")
    }

    // MARK: - ② 缺总页数的老记录

    /// `total` 缺失(nil)或非正数(0)都只显示页码,不显示「/0」
    func testEntryWithUnknownTotalShowsPageOnly() {
        let name = "a.cbz"

        for total in [Int?.none, Int?.some(0)] {
            let title = RecentPresentation.title(for: entry(name: name),
                                                 progress: index(name, progress(page: 4, total: total)),
                                                 staleIDs: [])
            XCTAssertTrue(title.contains("P.5"), "total=\(String(describing: total)) 实际:\(title)")
            XCTAssertFalse(title.contains("/"),
                           "不清楚总页数时不该出现斜杠(total=\(String(describing: total))):\(title)")
        }
    }

    // MARK: - ③ 失效后缀是拼接

    func testMissingEntryGetsTheSuffix() {
        let id = UUID()
        let title = RecentPresentation.title(for: entry(name: "gone.cbz", id: id),
                                             progress: noProgress,
                                             staleIDs: [id])
        XCTAssertTrue(title.hasPrefix("gone.cbz"), "文件名仍应在最前,实际:\(title)")
        XCTAssertTrue(title.hasSuffix(L10n.tr("app.menu.recentMissingSuffix")),
                      "失效条目应带找不到文件的后缀,实际:\(title)")
    }

    /// 失效 **且** 有续读记录:两样都要在 —— 后缀追加在进度之后,不能顶掉进度
    func testMissingEntryKeepsItsProgressAndAppendsTheSuffix() {
        let id = UUID()
        let name = "gone.cbz"
        let title = RecentPresentation.title(for: entry(name: name, id: id),
                                             progress: index(name, progress(page: 2, total: 200)),
                                             staleIDs: [id])
        XCTAssertTrue(title.contains("P.3/200"), "进度不能被失效后缀顶掉,实际:\(title)")
        XCTAssertTrue(title.hasSuffix(L10n.tr("app.menu.recentMissingSuffix")), "实际:\(title)")
    }

    // MARK: - ④ 顺序与身份

    func testItemsPreserveStorageOrderAndIdentity() {
        let ids = [UUID(), UUID(), UUID()]
        let entries = [entry(name: "newest.cbz", id: ids[0]),
                       entry(name: "mid.cbz", id: ids[1]),
                       entry(name: "oldest.cbz", id: ids[2])]

        let items = RecentPresentation.items(from: entries, progress: noProgress, staleIDs: [ids[2]])

        XCTAssertEqual(items.map(\.entry.name), ["newest.cbz", "mid.cbz", "oldest.cbz"],
                       "最近打开的存储顺序就是展示顺序,不得重排")
        XCTAssertEqual(items.map(\.id), ids, "ForEach 的身份必须来自存储条目")
        XCTAssertEqual(items.map(\.isMissing), [false, false, true],
                       "失效标记只该落在被点名的条目上")
    }

    // MARK: - 设计承诺(可核对,不是口号)

    /// 「空态是欢迎页不是管理器」:上限必须**严格小于**菜单上限。
    /// 相等就意味着有人把空态当列表页用了 —— 会把「打开文件…」挤出视觉重心
    func testVisibleLimitStaysBelowTheMenuLimit() {
        XCTAssertGreaterThan(RecentPresentation.visibleLimit, 0)
        XCTAssertLessThan(RecentPresentation.visibleLimit, RecentDocuments.maxEntries,
                          "空态上限 \(RecentPresentation.visibleLimit) 不该追上菜单上限 \(RecentDocuments.maxEntries)")
    }

    /// 「展示模型只带文件名」—— 字段白名单。
    /// 将来有人加一个 `url` / `path` 之类的字段,这条会当场红(§5.10.4 红线)
    func testDisplayModelCarriesOnlyTheFileName() {
        let item = RecentPresentation.items(from: [entry(name: "a.cbz")],
                                            progress: noProgress,
                                            staleIDs: []).first
        XCTAssertNotNil(item)
        guard let item else { return }

        let fields = Set(Mirror(reflecting: item).children.compactMap(\.label))
        XCTAssertEqual(fields, ["entry", "title", "isMissing"],
                       "加字段前先确认它不含路径 —— 展示模型只该带文件名,实际:\(fields.sorted())")
    }
}
