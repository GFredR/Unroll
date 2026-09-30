// AI-Generated | 可修改
// FolderSourceViewModelTests —— 目录源的 App 层粘合(2026-09-28)
// ----------------------------------------------------------------------------
// ArchiveKit/Tests 里的 FolderSourceTests 管的是「库这一层读得对不对」(排序 /
// 过滤 / 不递归 / 字节直通)。本文件只管**App 层的三件事** —— 它们都不在库的视野里:
//   · 入口通路:open 收到**目录**时会不会真的分流到 openFolder 并落到 .reading;
//   · 文案分流:目录打开失败的措辞与归档不同(empty / noImages / corrupted 各一套);
//   · 边角口径:完整性检查对目录要灰掉、续读键对目录取**页数**而不是目录大小。
//
// 为什么样本必须是**真目录 + 真图片**:目录源在 App 层要走「预读 → 解码」,
// 用 ArchiveKit 那种「任意可复现字节」的文件会在解码那一步失败,于是「失败页」
// 与「打开没成功」在断言里会混成同一个现象。图片用 CoreGraphics 现造
// (CGImageDestination 编 PNG)—— 编出来的 PNG 必然能被 ImageIO 解回来,
// 比内嵌一段 base64 更不容易写错,也不依赖仓库 fixture。
//
// ⚠️ 沙盒:临时图片目录建在 temporaryDirectory 下(带 UUID 隔离),`addTeardownBlock`
//    删干净 —— 残留会让下一次「空目录」用例莫名不空,而那种红看起来像实现坏了。
//    fixture 那条路(plain.cbz)仍受宿主沙盒限制,不可达就 skip。
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Unroll

@MainActor
final class FolderSourceViewModelTests: XCTestCase {

    // MARK: - 测试隔离(与 ReaderViewModelTests 同一套约定,suite 名独立)

    private static let suiteName = "test.foldervm.progress"
    private static let bookmarkSuiteName = "test.foldervm.bookmarks"
    private static let tipsSuiteName = "test.foldervm.tips"

    private func makeViewModel(reuseStores: Bool = false) -> ReaderViewModel {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        let bookmarkDefaults = UserDefaults(suiteName: Self.bookmarkSuiteName) ?? .standard
        let tipsDefaults = UserDefaults(suiteName: Self.tipsSuiteName) ?? .standard
        if !reuseStores {
            defaults.removePersistentDomain(forName: Self.suiteName)
            bookmarkDefaults.removePersistentDomain(forName: Self.bookmarkSuiteName)
            tipsDefaults.removePersistentDomain(forName: Self.tipsSuiteName)
        }
        return ReaderViewModel(progressStore: ReadingProgress(defaults: defaults),
                               bookmarkStore: Bookmarks(defaults: bookmarkDefaults),
                               tips: ReaderTips(defaults: tipsDefaults))
    }

    // MARK: - 样本装置

    /// 隔离的临时目录,退出时删除(清理失败静默:不该让用例因此变红)
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-foldervm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 造一张真能解码的 PNG(尺寸固定小图,只有颜色随 tint 变 —— 可复现,不用随机数)
    private func pngData(tint: UInt8) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 12,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                                "造不出位图上下文")
        ctx.setFillColor(CGColor(red: CGFloat(tint) / 255, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        let image = try XCTUnwrap(ctx.makeImage(), "造不出 CGImage")

        let out = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil),
            "造不出 PNG 编码器")
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG 编码失败")
        return out as Data
    }

    @discardableResult
    private func writeImage(_ name: String, into dir: URL, tint: UInt8) throws -> Data {
        let data = try pngData(tint: tint)
        try data.write(to: dir.appendingPathComponent(name))
        return data
    }

    /// pages 张真图片;`extras` 放非图片文件(名字 → 文本)
    private func makeImageFolder(pages: Int, extras: [String: String] = [:]) throws -> URL {
        let dir = try makeTemporaryDirectory()
        // ⚠️ 必须 `0..<pages` 而不是 `1...pages`:后者在 pages == 0 时是个空区间,
        //    运行期直接 `Fatal error: Range requires lowerBound <= upperBound` ——
        //    崩掉的是**整个测试进程**,现象看起来像 App 崩了(本批真踩过一次)
        for i in 0..<pages {
            try writeImage("page-\(i + 1).png", into: dir, tint: UInt8(((i + 1) * 37) % 251))
        }
        for (name, text) in extras {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    // MARK: - 入口通路

    /// 打开一个散图目录 → 进入阅读态,页数 = 图片数。
    /// 这条是整批的**端到端证据**:open 的分流、顺序扫描器直通、页面装配都对上,
    /// 才有这个结果(漏改任一处,现象是「网格有图、翻页空白」那种半死状态)
    func testOpeningImageFolderEntersReading() async throws {
        let dir = try makeImageFolder(pages: 3)
        let vm = makeViewModel()

        await vm.open(url: dir).value

        XCTAssertEqual(vm.phase, .reading, "目录应能进入阅读态")
        XCTAssertEqual(vm.pageCount, 3)
        XCTAssertEqual(vm.pageIndex, 0)
    }

    /// 非图片文件不占页:`.DS_Store` 与 `note.txt` 都不该变成「一页」
    func testOpeningImageFolderSkipsNonImageFiles() async throws {
        let dir = try makeImageFolder(pages: 2,
                                     extras: [".DS_Store": "\u{0}\u{0}",
                                              "note.txt": "这不是图片"])
        let vm = makeViewModel()

        await vm.open(url: dir).value

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertEqual(vm.pageCount, 2, "只有两张图片该成为页")
    }

    // MARK: - 失败分支的目录文案(与归档措辞分开,§5.9)

    /// 空目录 → 「这个文件夹是空的」(不是归档那句「归档是空的」)
    func testOpeningEmptyFolderGivesFolderCopy() async throws {
        let dir = try makeTemporaryDirectory()
        let vm = makeViewModel()

        await vm.open(url: dir).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("空目录必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.empty.folder.title")
        XCTAssertEqual(failure.bodyKey, "archive.empty.folder.body")
        XCTAssertEqual(vm.pageCount, 0)
    }

    /// 有文件但没图片 → 文案要带 found 计数,并且**说清不递归**
    /// (用户选了按话分好子目录的漫画目录时,这是唯一能解释「为什么说没有图片」的地方)
    func testOpeningFolderWithoutImagesGivesFolderCopyWithFoundCount() async throws {
        let dir = try makeImageFolder(pages: 0, extras: ["a.txt": "x", "b.txt": "y"])
        let vm = makeViewModel()

        await vm.open(url: dir).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("无图目录必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.noImages.folder.title")
        XCTAssertEqual(failure.bodyKey, "archive.noImages.folder.body")
        XCTAssertEqual(failure.bodyArg, 2, "文案里的 %ld 是「读了多少个文件」")
    }

    /// 目录已被移走 / 没权限 → 目录版「无法打开这个文件夹」。
    ///
    /// ⚠️ 这条的来历要说清:v1 的判据是 `url.hasDirectoryPath`,而下面这个
    /// `isDirectory: true` 刚好能骗过它 —— 用例绿了,真实拖拽进来的目录(URL 不带
    /// 尾斜杠)却会被讲成"无法打开这个归档"。2026-09-28 判据换成
    /// `ArchiveDocument.isDirectory`(与"决定走哪条路"同源)后,这条用例的分量变了:
    /// 它现在锁的是**文案分流本身**,不再是那个判据的证词
    func testOpeningVanishedFolderGivesFolderCorruptedCopy() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-vanished-\(UUID().uuidString)", isDirectory: true)
        let vm = makeViewModel()

        await vm.open(url: url).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("不存在的目录必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.corrupted.folder.title")
        XCTAssertEqual(failure.bodyKey, "archive.corrupted.folder.body")
    }

    /// 整层都是子文件夹(解压出来的 / 网盘同步下来的目录树常态)→ 说"只有子文件夹",
    /// **不是**"这个文件夹是空的"(2026-09-30)。
    ///
    /// 差别不是措辞好不好听:说"空"会把人推去确认文件到底存没存下来,
    /// 而真正该做的是往回退一层、改选具体那一话
    func testOpeningFolderWithOnlySubfoldersNamesThemInsteadOfCallingItEmpty() async throws {
        let dir = try makeTemporaryDirectory()
        for name in ["第01话", "第02话"] {
            let nested = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try writeImage("001.png", into: nested, tint: 7)
        }
        let vm = makeViewModel()

        await vm.open(url: dir).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("只有子文件夹的目录必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertNotEqual(failure.titleKey, "archive.empty.folder.title",
                          "这一层一点都不空 —— 讲成「空的」是假话,会把用户推向错误的排查方向")
        XCTAssertEqual(failure.titleKey, "archive.subfolders.folder.title")
        XCTAssertEqual(failure.bodyKey, "archive.subfolders.folder.body")
        XCTAssertEqual(failure.bodyArg, 2, "文案里的 %ld 是子文件夹个数")
    }

    // MARK: - 边角口径

    /// 目录源要**灰掉**「检查归档完整性」:⌥⌘V 验的是归档条目的字节(CRC / 截断),
    /// 散图目录里每个文件由文件系统保证,点了只是白读一遍却给出「检查过了」的错觉
    func testIntegrityCheckIsDisabledForFolderSources() async throws {
        let dir = try makeImageFolder(pages: 2)
        let vm = makeViewModel()

        await vm.open(url: dir).value

        XCTAssertEqual(vm.phase, .reading, "先确认真的开着文档 —— 否则下面两条会因「没文档」而假通过")
        XCTAssertFalse(vm.canCheckIntegrity)
        XCTAssertNil(vm.checkIntegrity(), "不可用时不该产生任务(不留半启动状态)")
    }

    /// 续读键的身份量:目录取**页数**,归档取字节数。
    ///
    /// ⚠️ 这一条是本批**唯一**能钉住「目录别用文件大小」的断言,而且是刻意抽成
    /// 纯函数才测得到的:同一个目录上「目录 metadata 大小」与「页数」总是同向变化,
    /// 端到端跑「打开 → 翻页 → 重开 → 恢复」时,取哪一个都会通过 —— 又一个自洽的错值。
    /// 只有把 fileSize 与 pageCount 摆成两个**不同的数**,才看得出取了谁
    func testDocumentIdentityPrefersPageCountForFolders() {
        XCTAssertEqual(ReaderViewModel.documentIdentity(isFolderSource: true,
                                                       fileSize: 4096, pageCount: 7), 7)
        XCTAssertEqual(ReaderViewModel.documentIdentity(isFolderSource: true,
                                                       fileSize: 999, pageCount: 7), 7,
                       "目录身份量不许受 fileSize 影响 —— 误用它的话,往目录加一张图就会静默丢掉续读")
        XCTAssertEqual(ReaderViewModel.documentIdentity(isFolderSource: false,
                                                       fileSize: 4096, pageCount: 7), 4096,
                       "归档侧照旧用字节数")
    }

    /// 续读对目录一样有效:翻到第 3 页 → 重开同一个目录 → 回到第 3 页
    func testFolderReadingProgressIsRestoredOnReopen() async throws {
        let dir = try makeImageFolder(pages: 4)

        let first = makeViewModel()
        await first.open(url: dir).value
        XCTAssertEqual(first.pageCount, 4)
        first.goTo(2)

        let second = makeViewModel(reuseStores: true)
        await second.open(url: dir).value

        XCTAssertEqual(second.pageIndex, 2, "目录的续读也要能恢复")
    }

    /// 页数变了就是**另一本**:加了图之后从第 1 页开始,不套用旧进度。
    ///
    /// ⚠️ 分量要说准(2026-09-28 用反向注入**实测**过):这条**能**抓到「身份量
    /// 不再跟着内容变」—— 把 `documentIdentity` 改成一味返回 fileSize 后它确实红了
    /// (调用点对目录传的是 -1,身份量于是塌成常量,旧进度被当成同一本套了回来)。
    /// 但它**抓不到**「取了目录的 metadata 大小」那一档:加一个文件会让 size 与页数
    /// 同时变,两种实现都得红也得绿。真钉住「取页数」的是上面那条纯函数用例,
    /// 别把这两条的分量说反了
    func testFolderThatGainedAPageLooksLikeANewDocument() async throws {
        let dir = try makeImageFolder(pages: 4)

        let first = makeViewModel()
        await first.open(url: dir).value
        first.goTo(3)

        try writeImage("page-5.png", into: dir, tint: 200)

        let second = makeViewModel(reuseStores: true)
        await second.open(url: dir).value

        XCTAssertEqual(second.pageCount, 5)
        XCTAssertEqual(second.pageIndex, 0, "内容变了 → 视为另一本,从第 1 页开始")
    }

    // MARK: - 导出(与完整性检查**刻意相反**:有用 ≠ 有意义)

    /// 目录源**照旧**可以导出:把当前层这几张图按页序另存到别处。
    ///
    /// 与「完整性检查对目录灰掉」是刻意相反的决策 —— 两者问的不是同一件事:
    /// 导出问「这个命令对目录有没有**用**」(有:把这一层图片规整重命名搬走),
    /// 完整性检查问「对目录有没有**意义**」(没有:散图没有归档条目可验)。
    /// 这条用例锁的就是"别把两者一起顺手排除掉"
    ///
    /// ⚠️ 放在本文件而不是 `PageSequenceExportTests`:那边的装置没有"造真图片"
    /// 这一步,而导出必须真的解码落盘 —— 为一个用例复制一整套装置不如就近共用
    func testFolderSourceCanStillExportEveryPage() async throws {
        let src = try makeImageFolder(pages: 3)
        let dest = try makeTemporaryDirectory()
        let vm = makeViewModel()

        await vm.open(url: src).value
        XCTAssertEqual(vm.phase, .reading, "先确认真的开着文档 —— 否则下面会因「没文档」而假通过")
        XCTAssertTrue(vm.canExportPages, "目录不许被挡在导出之外")

        await vm.exportPages(to: dest)?.value

        guard case .ready(let report) = vm.exportState else {
            return XCTFail("导出应已收尾,实际 \(String(describing: vm.exportState))")
        }
        XCTAssertEqual(report.delivered, 3)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(report.stop, .finished)

        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        XCTAssertEqual(names.count, 3, "三页都要落盘,实际:\(names)")
        for name in names {
            let data = try Data(contentsOf: dest.appendingPathComponent(name))
            XCTAssertFalse(data.isEmpty, "\(name) 是空文件 —— 导出不许拿空文件占位")
        }
    }
}
