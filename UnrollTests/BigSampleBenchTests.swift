// AI-Generated | 可修改
// BigSampleBenchTests —— 大包无头基准(M2/M3 手工验收的内存指标自动化替代)
// ----------------------------------------------------------------------------
// 目的:把设计验收线「200 页连翻内存 < 1.5GB」变成可重复的实测:
//   走真实管线 PageStore.image(at:) 顺序翻完全部页(含 anchorDidChange 预读),
//   逐页采样 phys_footprint,断言峰值 < 1.5GB。
//   掉帧 / HUD 手感 / 右开方向仍需人眼(自动化替代不了的部分见 §9)。
//
// 用法(默认 skip,CI 安全;样本不入库,由 Scripts/gen_big_sample.swift 现造):
//   TEST_RUNNER_UNROLL_BENCH_FIXTURE=/path/to/big.cbz \
//   xcodebuild test -project Unroll.xcodeproj -scheme Unroll \
//     -destination 'platform=macOS' -only-testing:UnrollTests/BigSampleBenchTests
// (xcodebuild 会把 TEST_RUNNER_ 前缀变量剥前缀后透传给测试进程)
//
// 测完铁律:样本同一回合内删除(§9 用户约定)。
import ArchiveKit
import XCTest
@testable import Unroll

final class BigSampleBenchTests: XCTestCase {

    /// phys_footprint(mach task_vm_info)—— 与活动监视器「内存」列同口径的峰值依据
    private func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    func testSequentialWalkStaysUnderMemoryBudget() async throws {
        let path = ProcessInfo.processInfo.environment["UNROLL_BENCH_FIXTURE"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "未设置 UNROLL_BENCH_FIXTURE —— 跳过大包基准(默认行为)")

        let url = URL(fileURLWithPath: path)
        let doc = try ArchiveDocument.open(url: url)
        let store = PageStore(document: doc)
        let total = await store.pageCount
        XCTAssertGreaterThan(total, 100, "基准样本应 ≥ 100 页,否则不构成「连翻」压力")

        var peak: Int64 = currentFootprint()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for index in 0..<total {
                _ = try await store.image(at: index)
                await store.anchorDidChange(to: index)     // 触发 +1/+2 预读,与真实翻页一致
                peak = max(peak, currentFootprint())
            }
            // 等预读尾巴落地,避免漏计最后几页的峰值
            try await Task.sleep(for: .seconds(1))
            peak = max(peak, currentFootprint())
        }

        let gb = Double(peak) / 1_073_741_824
        let msPerPage = Double(elapsed.components.attoseconds) / 1e15 / Double(total)
        print("📊 BENCH \(url.lastPathComponent): pages=\(total) peak=\(String(format: "%.2f", gb))GB elapsed=\(Int(elapsed.components.seconds))s ms/page=\(String(format: "%.1f", msPerPage))")

        await store.teardown()
        XCTAssertLessThan(gb, 1.5, "峰值内存超验收线 <1.5GB(设计文档 §5.3 预算)")
    }
}
