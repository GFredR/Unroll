// AI-Generated | 可修改
// FolderSourceTests —— 目录源(散图目录当一本读)单测(2026-09-28)
// ----------------------------------------------------------------------------
// 为什么不复用 `Fixtures/*.cbz`:本批测的是**文件系统这一层**,样本必须是真目录 +
// 真文件 —— "子目录""隐藏文件""打开之后文件被删"这些东西归档里没有对应物,
// 用归档 fixture 测它们只能是假装测过。
//
// 每个用例在 `temporaryDirectory` 下建一个**带 UUID 的隔离目录**,
// `addTeardownBlock` 里删干净。测试数据不留到下一轮是本仓库的硬纪律,不是洁癖:
// 残留的临时目录会让下一次"空目录"用例莫名其妙地不空,而那种失败看起来像
// 实现坏了,实际是上一轮的垃圾。
//
// 断言策略(对齐 §6.2「断言落在语义上」):
//   · 顺序/过滤沿用归档侧同一套规则 → 断言**逐条对比**
//     (不是"数量对得上",而是"就是这三个名字,这个顺序");
//   · 字节级 ground truth:写进去什么就读出什么(目录源不解码、不重编码,
//     所以样本不必是真 PNG —— 反而更好:真 PNG 会被误以为"解码成功了");
//   · 「不递归」要用**结构**锁:光靠 `isListedImage` 会把 `vol01` 这种无点号的
//     目录名当成"无扩展名的页"收进来 —— 那正是递归从后门溜回来的形态。
import XCTest
@testable import ArchiveKit

final class FolderSourceTests: XCTestCase {

    // MARK: - 样本装置

    /// 建一个隔离的临时目录,登记退出时删除(失败静默:清理失败不该让用例变红)
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 往目录里写一个文件,返回写进去的字节(供后续逐字节对拍)。
    /// 内容由 `seed` 决定,可复现 —— 不用随机数,失败时两次跑得到同样的字节
    @discardableResult
    private func write(_ name: String, into dir: URL, seed: UInt8 = 0, bytes: Int = 32) throws -> Data {
        let data = Data((0..<bytes).map { UInt8(($0 + Int(seed)) % 251) })
        try data.write(to: dir.appendingPathComponent(name))
        return data
    }

    // MARK: - 打开 + 排序 + 读字节(主路径)

    /// 目录里的散图按**自然排序**成页,且读出的字节与写进去的逐字节一致。
    /// 写入顺序刻意打乱(10 → 2 → 1):断言的是"排序真的发生了",不是"碰巧有序"
    func testOpenFolderSortsNaturallyAndReadsBackBytes() throws {
        let dir = try makeTemporaryDirectory()
        let page10 = try write("page10.png", into: dir, seed: 10)
        let page2 = try write("page2.png", into: dir, seed: 2)
        let page1 = try write("page1.png", into: dir, seed: 1)

        let doc = try ArchiveDocument.open(url: dir)

        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
        XCTAssertEqual(doc.entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(try doc.data(at: 0), page1)
        XCTAssertEqual(try doc.data(at: 1), page2)
        XCTAssertEqual(try doc.data(at: 2), page10)
    }

    /// 目录源的三个"归档概念"字段必须是中性值 —— 文件系统这一层没有
    /// "加密存储""物理条目序号"这种东西,留下非中性值只会在别处被误读
    func testFolderSourceHasNeutralArchiveSpecificFields() throws {
        let dir = try makeTemporaryDirectory()
        try write("page1.png", into: dir)

        let doc = try ArchiveDocument.open(url: dir)

        XCTAssertTrue(doc.isFolderSource)
        XCTAssertEqual(doc.format, .folder)
        XCTAssertEqual(doc.protection, .none)
        XCTAssertEqual(doc.encryptedImageCount, 0)
        XCTAssertTrue(doc.rawPositions.isEmpty)
        XCTAssertEqual(doc.entryEncrypted, [false])
    }

    /// 条目 size 是真实文件字节数(不是 nil、不是 0)
    func testFolderEntrySizesMatchRealFileSizes() throws {
        let dir = try makeTemporaryDirectory()
        let data = try write("page1.png", into: dir, bytes: 1234)

        let doc = try ArchiveDocument.open(url: dir)

        XCTAssertEqual(doc.entries[0].size, Int64(data.count))
    }

    // MARK: - 过滤(与归档侧同一套规则)

    /// 隐藏文件(`.DS_Store`)与非图片扩展名(`note.txt`)都不当页 ——
    /// macOS 的每个目录都带前者,漏掉它等于每本都多一页垃圾
    func testOpenFolderFiltersHiddenAndNonImageFiles() throws {
        let dir = try makeTemporaryDirectory()
        try write("page1.png", into: dir)
        try write(".DS_Store", into: dir)
        try write("note.txt", into: dir)

        let doc = try ArchiveDocument.open(url: dir)

        XCTAssertEqual(doc.entries.map(\.path), ["page1.png"])
    }

    /// 无扩展名的页要留下(老式扫描包普遍是 `001` / `002`)——
    /// 与归档侧同一条规则:解码按内容识别,不看扩展名,入口白名单不该拦真页
    func testOpenFolderKeepsExtensionlessPages() throws {
        let dir = try makeTemporaryDirectory()
        try write("002", into: dir)
        try write("001", into: dir)

        let doc = try ArchiveDocument.open(url: dir)

        XCTAssertEqual(doc.entries.map(\.path), ["001", "002"])
    }

    // MARK: - 不递归(结构锁)

    /// ★ **不递归**。子目录整棵都不进列表 —— 哪怕它里面全是图片。
    ///
    /// ⚠️ 这条用例锁的是一个**会从后门溜回来**的行为:只靠 `isListedImage` 过滤时,
    /// `vol01` 这个名字没有点号,会命中它的规则 2(无扩展名 → 当页收下),
    /// 于是子目录**自己**变成了"第 0 页"。用户看到的是翻开第一页显示一张
    /// 打不开的失败卡片,而原因是一行"看起来只是过滤图片"的代码。
    /// 实现里因此必须先用 `isRegularFile` 挡一层(`openFolder` 的第二条设计)
    func testOpenFolderDoesNotRecurseIntoSubdirectories() throws {
        let dir = try makeTemporaryDirectory()
        try write("page2.png", into: dir)
        let nested = dir.appendingPathComponent("vol01")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("page1.png", into: nested)

        let doc = try ArchiveDocument.open(url: dir)

        XCTAssertEqual(doc.entries.map(\.path), ["page2.png"],
                       "子目录(及其内容)都不该进列表 —— 包括子目录本身")
    }

    // MARK: - 空 / 无图(错误态语义与归档侧一致)

    /// 空目录 → `.empty`(与"空归档"同一档)。
    /// ⚠️ 判据是"**普通文件**数为 0",但这**不是**唯一出口 ——
    /// "只有子目录、一个文件都没有"走的是另一条(`.subfoldersOnly`,见下一条)。
    /// 两条曾经合并成 `.empty`,2026-09-30 拆开
    func testOpenEmptyFolderThrowsEmpty() throws {
        let dir = try makeTemporaryDirectory()

        XCTAssertThrowsError(try ArchiveDocument.open(url: dir)) { error in
            XCTAssertEqual(error as? ArchiveError, .empty)
        }
    }

    /// 只有子目录、没有任何文件 → `.subfoldersOnly(count:)`,**不是** `.empty`(2026-09-30)。
    ///
    /// 用户选了一个"外面一层壳、里面才是各话"的目录 —— 解压出来的、网盘同步下来的
    /// 目录树常态。此刻最不该说的是"这个文件夹是空的":它一点都不空,
    /// 那句话会把用户推去确认文件到底存没存下来(全是白费功夫)。
    ///
    /// ⚠️ 断言 **count == 2** 而不是"抛了就行" —— 摆两个子目录才证明得了计数在
    /// **累加**,而不是"发现有子目录就凑个 1"
    func testOpenFolderWithOnlySubdirectoriesReportsHowMany() throws {
        let dir = try makeTemporaryDirectory()
        for name in ["第01话", "第02话"] {
            let nested = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try write("001.png", into: nested)
        }

        XCTAssertThrowsError(try ArchiveDocument.open(url: dir)) { error in
            XCTAssertEqual(error as? ArchiveError, .subfoldersOnly(count: 2))
        }
    }

    /// 子目录与普通文件混在一起 → 仍是 `.noImages`,不是 `.subfoldersOnly`。
    /// 两条错误的边界就在这里:后者只描述"这一层没有任何**普通文件**";
    /// 只要有一个(哪怕是 .txt),就该按"读了 N 个、没有图片"来报
    func testOpenFolderWithSubdirectoriesAndNonImagesStillReportsNoImages() throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("第01话"),
                                                withIntermediateDirectories: true)
        try write("note.txt", into: dir)

        XCTAssertThrowsError(try ArchiveDocument.open(url: dir)) { error in
            XCTAssertEqual(error as? ArchiveError, .noImages(found: 1))
        }
    }

    /// 有文件但一个图片都没有 → `.noImages(found:)`,found 是**普通文件数**。
    /// UI 会据此换成"文件夹"版文案(见 ReaderViewModel.openFailure)
    func testOpenFolderWithoutImagesThrowsNoImages() throws {
        let dir = try makeTemporaryDirectory()
        try write("note.txt", into: dir)
        try write("index.xml", into: dir)

        XCTAssertThrowsError(try ArchiveDocument.open(url: dir)) { error in
            XCTAssertEqual(error as? ArchiveError, .noImages(found: 2))
        }
    }

    // MARK: - 顺序扫描器直通(四条上层链路的公共入口)

    /// 顺序扫描器对目录源必须可用,且**任意访问顺序**都正确。
    /// 这一条锁的是那处"目录直通"分支 —— 少了它,`reopen()` 会拿着一个
    /// 空句柄去 `archive_read_open_filename`,目录被当归档打开 ⇒ 报"文件损坏"。
    /// 上层四条链路(PageStore / 缩略图网格 / 批量导出 / 完整性检查)都 new 这个类,
    /// 所以这一个用例实际守住的是四个功能
    func testSequentialReaderWorksOnFolderSourceInAnyOrder() throws {
        let dir = try makeTemporaryDirectory()
        let p1 = try write("page1.png", into: dir, seed: 1)
        let p2 = try write("page2.png", into: dir, seed: 2)
        let p3 = try write("page3.png", into: dir, seed: 3)

        let doc = try ArchiveDocument.open(url: dir)
        let reader = SequentialPageReader(document: doc)

        // 乱序:前向 → 跳跃 → 后向(归档上后向要重开重建,目录上应当同样正确)
        XCTAssertEqual(try reader.data(at: 0), p1)
        XCTAssertEqual(try reader.data(at: 2), p3)
        XCTAssertEqual(try reader.data(at: 1), p2)
        XCTAssertEqual(try reader.data(at: 0), p1)
    }

    // MARK: - 打开之后文件消失(单页失败不扩散)

    /// 打开之后删掉某一页的文件:该页报错,**其余页照常**。
    /// (§5.9.4 约束 4 在目录源上的直接推论 —— 一张失败卡片,不是整本报废)
    func testPageFailsAloneAfterItsFileDisappears() throws {
        let dir = try makeTemporaryDirectory()
        let p1 = try write("page1.png", into: dir, seed: 1)
        try write("page2.png", into: dir, seed: 2)
        let p3 = try write("page3.png", into: dir, seed: 3)

        let doc = try ArchiveDocument.open(url: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("page2.png"))

        XCTAssertEqual(try doc.data(at: 0), p1)
        XCTAssertThrowsError(try doc.data(at: 1)) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupted)
        }
        XCTAssertEqual(try doc.data(at: 2), p3)
    }

    // MARK: - 取消

    /// `isCancelled` 一开始就为 true → 抛 `CancellationError`(不是失败态)。
    /// 目录枚举是同步阻塞的,几万个文件的目录不该让"用户已经换文件了"这张票
    /// 一直等到枚举跑完 —— 这条锁的就是那个节流检查点
    func testOpenFolderHonoursCancellation() throws {
        let dir = try makeTemporaryDirectory()
        try write("page1.png", into: dir)

        XCTAssertThrowsError(try ArchiveDocument.open(url: dir, isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError, "取消必须是 CancellationError,不是失败态;实际:\(error)")
        }
    }

    // MARK: - 回归:普通文件仍走归档那条路

    /// 加了目录分流之后,**文件**必须仍然走归档路径。判据是拿一个真归档
    /// 开出来:format 是 .zip 而非 .folder、isFolderSource 为假、条目照常。
    /// (少了这条,「目录分流写反了」这种错要等到用户打开 cbz 报错才发现)
    func testOpeningAFileStillUsesTheArchivePath() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/ArchiveKitTests
            .deletingLastPathComponent()      // …/Tests
            .appendingPathComponent("Fixtures")
        let doc = try ArchiveDocument.open(url: fixtures.appendingPathComponent("plain.cbz"))

        XCTAssertFalse(doc.isFolderSource)
        XCTAssertEqual(doc.format, .zip)
        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
    }
}
