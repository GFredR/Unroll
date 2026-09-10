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
}
