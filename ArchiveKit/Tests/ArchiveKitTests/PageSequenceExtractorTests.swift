// AI-Generated | 可修改
// PageSequenceExtractorTests —— 顺序提取器单测(2026-09-21 新功能)
// ----------------------------------------------------------------------------
// fixture 定位方式与 ArchiveDocumentTests / ArchiveIntegrityCheckerTests 相同
// (#filePath 回溯源码树)。跑在 ArchiveKit 包里(`cd ArchiveKit && swift test`,
// **无沙盒**),所以能直接对交付出来的字节做逐字节断言 —— 这也正是把遍历逻辑
// 放进 Kit 而不是 App 层的理由(见 PageSequenceExtractor 文件头)。
//
// 这组用例守的核心是**两件容易悄悄错的事**:
//   ① **顺序**:归档里的物理顺序不是阅读顺序(`plain.cbz` 实测是
//      page10 / page2 / page1)。交付顺序错了不会报任何错 —— 用户只会拿到
//      一堆名字对、内容乱的图。判据必须落在**内容**上,不能只看数量;
//   ② **交付的是原始字节**:一旦有人"顺手"在这里解码再重编码,
//      「提取原素材」这件事就坏了,而且坏得没有任何症状(图还是能看)。
//
// 外加三条诚实性约束(与 ArchiveIntegrityCheckerTests 同款):加密页不算损坏、
// 取消不算失败、**没弄完绝不说成弄完了**。
import XCTest
@testable import ArchiveKit

final class PageSequenceExtractorTests: XCTestCase {

    private enum Fixtures {
        static let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")

        static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

        /// 源图目录 —— 造 fixture 时喂给 zip 的那一份,与归档内的字节完全一致
        /// (2026-09-21 用系统 `ditto` 独立解压后逐字节核对过,不是"看着一样")
        static func src(_ name: String) throws -> Data {
            try Data(contentsOf: dir.appendingPathComponent("src").appendingPathComponent(name))
        }
    }

    // MARK: - @Sendable 回调用的小工具

    /// 收下的一页
    private struct Delivered: Sendable, Equatable {
        let index: Int
        let data: Data
    }

    /// 收集盒。提取器的回调是 `@Sendable`,而 Swift 6 不允许闭包捕获可变的
    /// 局部变量 —— 于是「收了什么」只能自己带一把锁(与 ArchiveIntegrityCheckerTests 同款)
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Delivered] = []
        private var progress: [Int] = []

        var delivered: [Delivered] {
            lock.lock(); defer { lock.unlock() }
            return pages
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return pages.count
        }

        var progresses: [Int] {
            lock.lock(); defer { lock.unlock() }
            return progress
        }

        func take(_ index: Int, _ data: Data) {
            lock.lock()
            pages.append(Delivered(index: index, data: data))
            lock.unlock()
        }

        func noteProgress(_ done: Int) {
            lock.lock()
            progress.append(done)
            lock.unlock()
        }
    }

    // MARK: - ① 顺序与原始字节

    /// 归档里的物理顺序是 `page10 / page2 / page1`(系统 `tar -tf` 实测),
    /// 而交付顺序必须是**阅读顺序** `page1 → page2 → page10`。
    ///
    /// 判据落在内容而不是数量上:三个源图大小互不相同(1117 / 1123 / 1133),
    /// 所以「第 i 页的字节 == 第 i 张源图的字节」这一条同时锁住了顺序与内容。
    /// 只断言"交了 3 页"是抓不到顺序错误的 —— 那正是这个用例存在的原因
    func testPagesArriveInReadingOrderWithOriginalBytes() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        XCTAssertEqual(doc.entries.count, 3, "note.txt / .DS_Store 都不该算页")

        let box = Collector()
        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return true
        }

        XCTAssertEqual(report.stop, .finished)
        XCTAssertEqual(report.delivered, 3)
        XCTAssertEqual(report.skippedEncrypted, 0)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(report.coversWholeArchive, "3 页全部交代清楚")
        XCTAssertEqual(report.remaining, 0)

        let pages = box.delivered
        XCTAssertEqual(pages.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(pages[0].data, try Fixtures.src("page1.png"))
        XCTAssertEqual(pages[1].data, try Fixtures.src("page2.png"))
        XCTAssertEqual(pages[2].data, try Fixtures.src("page10.png"))
    }

    /// 无扩展名的页(`vol01/001`)不只是"能读"——导出时必须**如实交付原始字节**,
    /// 而那张被当成页收进来的纯文本(`vol01/notes`)也在其中。
    ///
    /// 这一条锁的是 App 层扩展名嗅探的**输入**:`notes` 是 13 字节、没有魔数,
    /// 于是落盘时扩展名只能是 `.bin`(见 PageExport.exportFileExtension)。
    /// 若这里悄悄把非图片吞掉,那边就再也没有 .bin 这种诚实的兜底了
    func testExtensionlessEntriesAreDeliveredVerbatim() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("no-extension.cbz"))
        XCTAssertEqual(doc.entries.count, 4, "001..003 + notes(无扩展名一律收,有意为之)")

        let box = Collector()
        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return true
        }

        XCTAssertEqual(report.delivered, 4)
        XCTAssertTrue(report.coversWholeArchive)

        let pages = box.delivered
        XCTAssertEqual(pages[0].data, try Fixtures.src("page1.png"))
        XCTAssertEqual(pages[1].data, try Fixtures.src("page2.png"))
        // ⚠️ 第三页装的是 **page10** 的字节(造样本时 `shutil.copy('page10.png','ext_003')`,
        // 见 Fixtures/make_fixtures.sh)。这条容易想当然写成 page3.png —— 实测核对过
        XCTAssertEqual(pages[2].data, try Fixtures.src("page10.png"))
        XCTAssertEqual(pages[3].data, try Fixtures.src("note.txt"), "纯文本也被如实交付,不静默吞掉")
    }

    // MARK: - ② 加密页 ≠ 损坏(两条方向相反的判据)

    /// 未给密码:2 页明文交付、2 页加密跳过,**失败数为 0**。
    /// 把加密算成失败会让每个部分加密包一导出就报「有 2 页坏了」,
    /// 而用户其实只需要输个密码
    func testEncryptedPagesAreSkippedNotFailed() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"))
        XCTAssertEqual(doc.entries.count, 4)

        let box = Collector()
        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return true
        }

        XCTAssertEqual(report.skippedEncrypted, 2)
        XCTAssertEqual(report.delivered, 2)
        XCTAssertEqual(report.failedCount, 0, "加密不是损坏")
        XCTAssertEqual(report.stop, .finished)
        XCTAssertTrue(report.coversWholeArchive, "跳过的页也是交代清楚的")
    }

    /// 给了密码:同样的 4 页全部交付。
    /// 判据用 `ArchiveDocument.data(at:)`(**每页自建实例**的随机访问路径)取参照,
    /// 与提取器走的**单实例前向扫描**是两条不同的代码路径 —— 两处给出的字节必须一致。
    /// 这样就不必依赖 fixture 源图是否与归档同步,同时顺带钉住「密码必须跟着重开一起带上」
    /// (漏传的症状正是「第一页对、后面每页失败」)
    func testUnlockedArchiveDeliversEncryptedPagesToo() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("partial.cbz"), passphrase: "secret")

        let box = Collector()
        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return true
        }

        XCTAssertEqual(report.delivered, 4)
        XCTAssertEqual(report.skippedEncrypted, 0)
        XCTAssertEqual(report.failedCount, 0)

        let pages = box.delivered
        XCTAssertEqual(pages.count, 4)
        for page in pages {
            XCTAssertEqual(page.data, try doc.data(at: page.index),
                           "第 \(page.index + 1) 页:顺序扫描与随机访问必须给出同一份字节")
        }
    }

    // MARK: - ③ 坏页:点名 + 后面照常交

    /// 单页负载损坏(`damaged-page.cbz`:目录完好,page2 被翻一字节)。
    /// 三条一起断言,缺一条这个功能就不可信:
    ///   ① 坏页被**精确定位**到索引 1;
    ///   ② 坏页**之后**的页仍交付 —— 这是「坏页必须重开扫描器」的直接证据
    ///      (不重开的话流位置已坏,page10 会跟着报错);
    ///   ③ 报告仍是**完整**的:坏页被点名,就算交代清楚了,不该说成「没弄完」
    func testDamagedPageIsNamedAndFollowingPagesStillArrive() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("damaged-page.cbz"))
        XCTAssertEqual(doc.entries.count, 3)

        let box = Collector()
        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return true
        }

        XCTAssertEqual(report.failedPages, [1], "坏页应精确定位到第 2 页(索引 1)")
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.delivered, 2)
        XCTAssertEqual(report.stop, .finished)
        XCTAssertTrue(report.coversWholeArchive, "点名了就等于交代清楚了")
        XCTAssertEqual(report.remaining, 0)
        XCTAssertEqual(box.delivered.map { $0.index }, [0, 2], "坏页之后的第 3 页照样交付")
    }

    // MARK: - ④ 取消 / 消费方叫停:都绝不说成「做完了」

    /// 取消不是失败:失败数为 0、已交付的部分保留,
    /// 但 `coversWholeArchive` 必须是 **false** —— 界面据此说「还有 N 页没处理」
    func testCancelStopsEarlyAndNeverClaimsCompletion() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let box = Collector()

        let report = PageSequenceExtractor.extract(
            document: doc,
            isCancelled: { box.count >= 1 },
            onPage: { index, data in
                box.take(index, data)
                return true
            })

        XCTAssertEqual(report.stop, .cancelled)
        XCTAssertEqual(report.delivered, 1)
        XCTAssertEqual(report.failedCount, 0, "取消不是失败")
        XCTAssertFalse(report.coversWholeArchive, "取消时必须说「没弄完」")
        XCTAssertEqual(report.remaining, 2)
    }

    /// 消费方(`onPage`)回 false 说"别再给我了" —— App 层用它表达**写盘失败**。
    /// 两条要紧的:① 立即收工,不许接着读完(否则报告会变成「200 页全失败」,
    /// 把真实原因埋在页码列表里);② **不算坏页** —— 页本身是好的,失败的是"写出去"
    func testSinkRefusalHaltsImmediatelyAndIsNotCountedAsDamage() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let box = Collector()

        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return box.count < 2      // 第 2 页起拒绝
        }

        XCTAssertEqual(report.stop, .sinkStopped)
        XCTAssertEqual(report.delivered, 1)
        XCTAssertEqual(report.failedCount, 0, "写不出去不是坏页")
        XCTAssertEqual(box.count, 2, "被拒绝的那一页确实读出来了,只是没收下")
        XCTAssertFalse(report.coversWholeArchive)
        XCTAssertEqual(report.remaining, 2)
    }

    // MARK: - ⑤ 进度

    /// 进度只在 `progressStride` 的整数倍上回调(逐页回调在几百页的包上
    /// 等于凭空造几百个任务),且**单调不减、不越过总页数**。
    ///
    /// 用**同一份 3 页样本配三个步长**来钉语义,而不是去找一个"页多的样本":
    /// 现有 fixture 里 `many-entries.cbz` 虽然有 303 个条目,但其中只有 3 个是页
    /// (其余 300 个是 `pad/*.txt`,本来就不该算页)—— 拿条目数当页数会得出
    /// 「样本够长」的错觉。三个步长各钉一件事,合起来没有它是测不出来的:
    ///   · `1` → 每页都回调(证明步长是个真旋钮,不是写死的 8);
    ///   · `2` → **恰好** `[2]`:第 3 页不回调 —— 这半条是「节流」二字的全部内容;
    ///   · `8`(大于总页数)→ **一次都不回调**,而不是"最后一页兜底补一次"
    func testProgressIsThrottledToStrideAndMonotonic() throws {
        let doc = try ArchiveDocument.open(url: Fixtures.url("plain.cbz"))
        let total = doc.entries.count
        XCTAssertEqual(total, 3)

        func progresses(stride: Int) -> [Int] {
            let box = Collector()
            _ = PageSequenceExtractor.extract(
                document: doc,
                progressStride: stride,
                onProgress: { box.noteProgress($0) },
                onPage: { _, _ in true })
            return box.progresses
        }

        XCTAssertEqual(progresses(stride: 1), [1, 2, 3], "步长 1 = 逐页回调")
        XCTAssertEqual(progresses(stride: 2), [2], "只在 2 上回调,第 3 页不补")
        XCTAssertEqual(progresses(stride: 8), [], "不到一个步长就一次都不回调")

        for stride in [1, 2, 8] {
            let values = progresses(stride: stride)
            XCTAssertTrue(values.allSatisfy { $0 % stride == 0 }, "步长 \(stride):只在整数倍上回调")
            XCTAssertEqual(values, values.sorted(), "步长 \(stride):进度必须单调不减")
            XCTAssertTrue(values.allSatisfy { $0 <= total })
        }

        // 三类的和必须等于总页数 —— 否则报告里的「还剩几页」是假的
        let box = Collector()
        let report = PageSequenceExtractor.extract(document: doc) { index, data in
            box.take(index, data)
            return true
        }
        XCTAssertEqual(report.delivered + report.skippedEncrypted + report.failedCount, total)
    }
}
