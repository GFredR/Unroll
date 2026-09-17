// AI-Generated | 可修改
// IntegrityCheckTests —— 完整性检查在 VM 层的粘合(2026-09-17 新功能)
// ----------------------------------------------------------------------------
// 检查算法本身(坏页定位、加密页跳过、取消语义)在 ArchiveKit 包里单测,
// 跑在无沙盒的 swift test 下 —— 那里有 fixture 与真实字节级断言。
// 本文件只补**VM 粘合层**三件事:
//   · 菜单可用性随阶段变化(没打开文档时不许点);
//   · 结果确实落到 `integrity` 上、面板开关跟着走;
//   · **换书必须停掉旧检查** —— 否则旧包的结论会显示在新包界面上。
//
// ⚠️ 与 PageStoreTests 同款沙盒说明:宿主 App 开着 App Sandbox,测试进程继承,
// 仓库 fixture 可能不可读。不可读时 skip,不伪造结论。
import ArchiveKit
import XCTest
@testable import Unroll

@MainActor
final class IntegrityCheckTests: XCTestCase {

    private static let suiteName = "test.integrity.progress"

    /// 仓库内 fixture 目录(与 PageStoreTests 同一口径)
    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    private func fixture(_ name: String) throws -> URL {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)—— 算法层由 ArchiveKit 包内单测覆盖")
        }
        return url
    }

    private func makeViewModel() -> ReaderViewModel {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        defaults.removePersistentDomain(forName: Self.suiteName)
        return ReaderViewModel(progressStore: ReadingProgress(defaults: defaults),
                               bookmarkStore: Bookmarks(defaults: defaults))
    }

    // MARK: - 可用性

    /// 没打开文档时不许点「检查归档完整性」——没有文档就没有可检查的对象
    func testMenuIsUnavailableBeforeOpening() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .noDocument)
        XCTAssertFalse(vm.canCheckIntegrity)
        XCTAssertNil(vm.checkIntegrity(), "不可用时不该产生任务(返回 nil,不留半启动状态)")
    }

    func testMenuBecomesAvailableAfterOpening() async throws {
        let vm = makeViewModel()
        let url = try fixture("plain.cbz")
        await vm.open(url: url).value

        XCTAssertEqual(vm.phase, .reading)
        XCTAssertTrue(vm.canCheckIntegrity)
    }

    // MARK: - 结论落地

    /// 明文包:跑完 → `.finished`,报告是干净的;面板开关同时打开
    func testCheckOnIntactArchiveFinishesWithCleanReport() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value

        let task = try XCTUnwrap(vm.checkIntegrity())
        XCTAssertTrue(vm.isIntegritySheetPresented, "开始检查要顺带把面板打开")
        await task.value

        guard case .finished(let report) = vm.integrity else {
            return XCTFail("检查结束后必须是 .finished,实际:\(String(describing: vm.integrity))")
        }
        XCTAssertTrue(report.isIntact)
        XCTAssertEqual(report.pages, 3)
        XCTAssertEqual(report.damagedCount, 0)
    }

    /// 单页损坏的包 → 结论必须指名道姓(第 2 页),而不是笼统说"有问题"
    func testCheckOnDamagedArchiveNamesTheBrokenPage() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("damaged-page.cbz")).value

        await vm.checkIntegrity()?.value

        guard case .finished(let report) = vm.integrity else {
            return XCTFail("检查结束后必须是 .finished")
        }
        XCTAssertEqual(report.damagedPages, [1])
        XCTAssertFalse(report.isIntact)
    }

    /// 关掉面板 = 清掉结论。于是「点菜单」的语义永远是「现在跑一遍」,
    /// 不会出现「这次点开看到的是上次的结论」
    func testDismissClearsResultSoMenuAlwaysMeansRunNow() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("plain.cbz")).value
        await vm.checkIntegrity()?.value
        XCTAssertNotNil(vm.integrity)

        vm.dismissIntegrity()
        XCTAssertNil(vm.integrity)
        XCTAssertFalse(vm.isIntegritySheetPresented)
    }

    // MARK: - 换书必须停掉旧检查

    /// 旧包的检查结论**绝不能**落到新包的界面上。
    /// 结论本身没错,错的是归属 —— 用户会以为刚打开的这个包有问题
    func testOpeningAnotherArchiveDiscardsPreviousCheck() async throws {
        let vm = makeViewModel()
        await vm.open(url: try fixture("damaged-page.cbz")).value

        let stale = vm.checkIntegrity()          // 针对"有坏页"的那本
        await vm.open(url: try fixture("plain.cbz")).value

        XCTAssertNil(vm.integrity, "换书后旧结论必须立即清掉,不能等它自己跑完")
        XCTAssertFalse(vm.isIntegritySheetPresented, "面板也要一起关掉")
        await stale?.value                        // 旧任务收尾(被取消 → 报告带 stoppedEarly)
        XCTAssertNil(vm.integrity, "旧任务收尾时也不许把结论写回来")
    }
}
