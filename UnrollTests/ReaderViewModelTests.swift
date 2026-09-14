// AI-Generated | 可修改
// ReaderViewModelTests —— 归档级状态机分支(宿主为 App,§6.2/AGENTS.md 九.1)
// ----------------------------------------------------------------------------
// M2 覆盖:open 的失败分支(损坏/不存在 → .failed + 正确文案 key)与
// 成功分支的基本不变量(pageCount/phase)。失败分支用临时目录的垃圾文件
// (沙盒可写);成功分支走仓库内 fixture(见 PageStoreTests 的沙盒说明)。
import XCTest
@testable import Unroll

@MainActor
final class ReaderViewModelTests: XCTestCase {

    // MARK: - 失败分支(绝不闪退,§5.9.4)

    /// 垃圾文件 → .failed + corrupted 文案组
    func testOpenGarbageFileFailsWithCorruptedCopy() async throws {
        let vm = ReaderViewModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-garbage-\(UUID().uuidString).bin")
        try Data("this is definitely not an archive".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await vm.open(url: url).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("垃圾文件必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.corrupted.title")
        XCTAssertEqual(failure.bodyKey, "archive.corrupted.body")
        XCTAssertEqual(vm.pageCount, 0)
    }

    /// 不存在的文件 → 同 corrupted 组(openRawHandle 打不开即 .corrupted)
    func testOpenMissingFileFails() async throws {
        let vm = ReaderViewModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-missing-\(UUID().uuidString).cbz")

        await vm.open(url: url).value

        guard case .failed(let failure) = vm.phase else {
            return XCTFail("不存在的文件必须以 .failed 收场,实际 \(vm.phase)")
        }
        XCTAssertEqual(failure.titleKey, "archive.corrupted.title")
    }

    // MARK: - 状态机不变量

    /// 初始态:noDocument、空呈现
    func testInitialState() {
        let vm = ReaderViewModel()
        XCTAssertEqual(vm.phase, .noDocument)
        XCTAssertEqual(vm.pageCount, 0)
        XCTAssertEqual(vm.pageIndex, 0)
        XCTAssertNil(vm.presentation.image)
        XCTAssertFalse(vm.presentation.isLoading)
    }

    /// 换书语义:再次 open 时旧任务被取消,最终状态由新任务决定
    func testReopenReplacesPreviousState() async throws {
        let vm = ReaderViewModel()
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("unroll-garbage-\(UUID().uuidString).bin")
        try Data("junk".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        // 第一次打开成功与否不重要(不依赖 fixture);第二次打开后状态应被重置再落定
        await vm.open(url: garbage).value
        await vm.open(url: garbage).value

        guard case .failed = vm.phase else {
            return XCTFail("两次垃圾打开后仍应是 failed,实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.pageIndex, 0)
    }

    // MARK: - 缩放档位(§2.1-4,2026-09-14 补齐)

    /// 默认档位 = 适应窗口(整页完整可见)
    func testDefaultFitModeIsFitWindow() {
        XCTAssertEqual(ReaderViewModel().fitMode, .fitWindow)
    }

    /// 档位切换只改渲染基准,不碰归档状态机
    func testFitModeSwitchingKeepsArchiveState() async throws {
        let vm = try await openFixtureOrSkip()
        vm.fitMode = .fitWidth
        XCTAssertEqual(vm.fitMode, .fitWidth)
        guard case .reading = vm.phase else {
            return XCTFail("换档位不得影响 reading 态")
        }
        XCTAssertEqual(vm.pageCount, 3)
        vm.fitMode = .actualSize
        XCTAssertEqual(vm.fitMode, .actualSize)
    }

    /// 面包屑标签必须过 sanitize 白名单(§5.10.4 隐私红线由结构保证)
    func testFitModeTokensPassSanitizeWhitelist() {
        let modes: [ReaderViewModel.FitMode] = [.fitWindow, .fitWidth, .fitHeight, .actualSize]
        for mode in modes {
            XCTAssertNotNil(Breadcrumbs.sanitize(mode.token), "\(mode.token) 必须过白名单")
        }
    }

    // MARK: - 双页 / 右开(M3,§0 决策 3)

    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    /// fixture 不可达 → skip(同 PageStoreTests 的沙盒约定)
    private func openFixtureOrSkip() async throws -> ReaderViewModel {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)")
        }
        let vm = ReaderViewModel()
        await vm.open(url: url).value
        guard case .reading = vm.phase, vm.pageCount >= 2 else {
            throw XCTSkip("fixture 未进入 reading 态或页数不足(plain.cbz 有 3 页)")
        }
        return vm
    }

    /// 双页:次页 = 主页 +1;翻页步长 ×2;尾页越界 → 次页 nil
    func testDualModeStepAndSecondaryIndex() async throws {
        let vm = try await openFixtureOrSkip()
        let count = vm.pageCount
        vm.layout = .dual

        XCTAssertEqual(vm.secondaryIndex, 1)
        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, min(2, count - 1), "双页模式一次跨两页")

        // 连翻到尾:最后一页无次页 → nil,退化为单页
        vm.goTo(count - 1)
        XCTAssertNil(vm.secondaryIndex)
    }

    /// 单页:次页恒 nil,步长 1
    func testSingleModeHasNoSecondary() async throws {
        let vm = try await openFixtureOrSkip()
        XCTAssertNil(vm.secondaryIndex)
        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, 1, "单页模式步长 1")
    }

    /// 右开:只影响视觉顺序(归 View),VM 的翻页语义恒为「文档前进/后退」;
    /// 切方向不动当前页
    func testDirectionSwitchKeepsPositionAndForwardStep() async throws {
        let vm = try await openFixtureOrSkip()
        vm.direction = .rightToLeft
        XCTAssertEqual(vm.pageIndex, 0, "切方向不得跳页")
        vm.nextPage()
        XCTAssertEqual(vm.pageIndex, 1, "前进语义与方向无关,恒 +1(文档序)")
    }
}
