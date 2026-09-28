// AI-Generated | 可修改
// BigSampleBenchTests —— 大包无头基准(M2/M3 手工验收的内存指标自动化替代)
// ----------------------------------------------------------------------------
// 目的:把设计验收线「200 页连翻内存 < 1.5GB」变成可重复的实测。
// 两条基准,覆盖面**互补**(2026-09-28 补第二条):
//   ① SequentialWalk —— 纯阅读路径:走真实管线 PageStore.image(at:) 顺序翻完全部页
//      (含 anchorDidChange 预读),逐页采样 phys_footprint;
//   ② Combined —— 真实**打开**路径:网格全卷扫描 与 首屏全分辨率解码**并发**
//      (结构照抄 ReaderViewModel.openDocument → showGrid() + loadPage(startPage))。
//      它单独存在,是因为网格自 2026-09-23 起是打开后的**默认层** ——
//      「打开 → 全卷扫描到顶」每次打开都会走,而 ① 完全不覆盖它。
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
import Foundation
import XCTest
@testable import Unroll

/// 内存验收线的**单一真源**(测试目标内)。
///
/// 为什么抽成独立类型:这条线有两个消费者 —— 本文件的基准断言实测峰值不越过它,
/// `AppSkeletonTests` 断言三池之和吃不掉它的大半。两处各写一个 `1.5` 的话,
/// 有人调线时很容易只改到看得见的那处,另一处**静默**留在旧值上;
/// 而「线往下调、旧值仍偏大」这个方向等于守卫偷偷放松了 —— 没有任何征兆
enum MemoryAcceptanceLine {
    /// 1.5 GiB —— 设计文档 §5.3「200 页连翻内存 < 1.5GB」验收线。
    /// 写成「1 GiB × 3/2」是为了与 `phys_footprint` / 活动监视器同口径
    static let bytes: Int64 = 1_073_741_824 * 3 / 2
}

/// phys_footprint(mach task_vm_info)—— 与活动监视器「内存」列同口径的峰值依据。
///
/// **刻意放在文件作用域而不是 `XCTestCase` 的实例方法**:联合基准要在
/// `Task.detached`(网格扫描)与 `@Sendable` 回调里采样,实例方法会把 `self`
/// 捕获进非隔离闭包 —— `XCTestCase` 不是 `Sendable`,严格并发下直接编不过。
/// 它本来也不读任何实例状态
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

/// 跨隔离域累加峰值。采样点在扫描线程(`onThumbnail` / `onProgress`)与等待方两处,
/// 所以必须有锁。`@unchecked Sendable` 是诚实声明:安全性来自下面那把 `NSLock`,
/// **不是**编译器能证明的隔离(与 `ThumbnailStore` 同一句话)
private final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) { value = start }

    func observe(_ sample: Int64) {
        lock.lock(); defer { lock.unlock() }
        value = max(value, sample)
    }

    var peak: Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class BigSampleBenchTests: XCTestCase {

    /// 把字节格式化成 GiB 字符串(报告用;断言一律比字节,不用浮点)
    private static func gib(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
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

        let msPerPage = Double(elapsed.components.attoseconds) / 1e15 / Double(total)
        print("📊 BENCH \(url.lastPathComponent): pages=\(total) peak=\(Self.gib(peak))GB elapsed=\(Int(elapsed.components.seconds))s ms/page=\(String(format: "%.1f", msPerPage))")

        await store.teardown()
        XCTAssertLessThan(peak, MemoryAcceptanceLine.bytes,
                          "峰值 \(Self.gib(peak))GB 超验收线(设计文档 §5.3:200 页连翻 < 1.5GB)")
    }

    /// 联合基准:打开 → **网格全卷扫描** → 进阅读层连翻(2026-09-28)。
    ///
    /// ## 为什么必须另开一条
    /// 上面那条走的是纯阅读路径,**完全不覆盖网格扫描**。而网格自 2026-09-23 起是
    /// 打开后的**默认层** —— 「打开 → 全卷扫描到顶」是每次打开都会走的路径,
    /// 此前一个数字都没有。老待办里「200 页连翻内存/掉帧」也一直没验,现在等于
    /// 又多了一条同样没数字的常态路径。
    ///
    /// ## 峰值为什么按**叠加**测,而不是取两者的大者
    /// `ReaderViewModel.openDocument` 里 `showGrid()`(起 detached 全档扫描)之后
    /// 紧接着就是 `loadPage(startPage)`(首屏全分辨率解码)+ `anchorDidChange`
    /// (预读),中间只隔几个同步语句 —— 两条路径**确实同时在跑**。源码注释自己也
    /// 写着「此刻磁盘上确实有两件事同时在跑」(那句说的是扫描器实例不共享,与内存
    /// 无关)。所以本基准照抄这个结构:扫描放 `Task.detached`,等待方同时起首屏解码。
    ///
    /// ## 分段采样
    /// 只报一个总数说不清峰值归属于哪一段,也就无从判断该调哪个旋钮。这里分开记
    /// `baseline` / `grid`(扫描期间 **+ 扫描收尾池子最满那一刻**)/
    /// `walk`(连翻期间)。网格池在**整段里都不释放** —— 真实路径正是如此
    /// (`gridThumbs` 常驻,换池子只发生在 open / rebuildGrid / 解锁)。
    ///
    /// ## ⚠️ 这条基准测的是**常态**,不是**最坏**
    /// 网格池的两个上限(600 张 / 2400 万像素)需要 ≥548 张典型 2:3 页才会到顶,
    /// 而验收样本是 200 页 —— 所以池子在这条路径上**永远到不了顶**,测出来的是
    /// 「常见包」的真实占用。**最坏情形由 `AppSkeletonTests` 的三池之和守卫用
    /// 常量算出来**(那条不需要造样本,任何页数都成立)。两条合起来才算完整:
    /// 基准管「真实路径有多高」,不变量管「上限能到哪」
    func testOpenGridThenWalkKeepsCombinedPeakUnderBudget() async throws {
        let path = ProcessInfo.processInfo.environment["UNROLL_BENCH_FIXTURE"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "未设置 UNROLL_BENCH_FIXTURE —— 跳过大包基准(默认行为)")

        let url = URL(fileURLWithPath: path)
        let doc = try ArchiveDocument.open(url: url)
        let store = PageStore(document: doc)
        let total = await store.pageCount
        XCTAssertGreaterThan(total, 100, "基准样本应 ≥ 100 页,否则不构成「连翻」压力")

        let baseline = currentFootprint()
        let clock = ContinuousClock()

        // ---- 阶段 1:网格全卷扫描(结构照抄 ReaderViewModel.buildGrid)----
        // 池子与扫描同寿命:`Task.detached` 同步写它(`ThumbnailStore` 自带锁),
        // 所以 `await scan.value` 返回时它已经填满,不存在「生成完了图还没到」的窗口
        let pool = ThumbnailStore()
        let gridPeak = PeakBox(baseline)

        let gridStart = clock.now
        let scan = Task.detached(priority: .utility) {
            PageGridBuilder.build(
                document: doc,
                maxPixel: DesignSystem.PageBudget.gridThumbnailLongEdge,
                budget: .default,
                // 在这里读到的是**本 detached 任务**的取消状态(闭包在它的线程上
                // 被同步调用)—— 与 App 里那条链路同一语义
                isCancelled: { Task.isCancelled },
                onThumbnail: { page, image in
                    pool.store(image, at: page)
                    // 采样点贴着真正分配像素的那一步(写完池子立刻采)
                    gridPeak.observe(currentFootprint())
                },
                // onProgress 每 progressStride 页也采一次:它在「跳过加密页 / 解码
                // 失败」时同样会触发,于是采样覆盖到纯 onThumbnail 覆盖不到的分支
                onProgress: { _ in gridPeak.observe(currentFootprint()) })
        }
        let report = await scan.value
        gridPeak.observe(currentFootprint())   // 扫描收尾、池子最满的一刻
        let gridDuration = clock.now - gridStart

        // ---- 阶段 2:进阅读层连翻(网格池**仍然驻留** —— 真实路径不释放它)----
        let walkPeak = PeakBox(currentFootprint())
        let walkStart = clock.now
        for index in 0..<total {
            _ = try await store.image(at: index)
            await store.anchorDidChange(to: index)     // 触发 +1/+2 预读,与真实翻页一致
            walkPeak.observe(currentFootprint())
        }
        try await Task.sleep(for: .seconds(1))         // 等预读尾巴落地
        walkPeak.observe(currentFootprint())
        let walkDuration = clock.now - walkStart

        print("📊 BENCH-COMBINED \(url.lastPathComponent): "
              + "pages=\(total) base=\(Self.gib(baseline))GB "
              + "grid=\(Self.gib(gridPeak.peak))GB walk=\(Self.gib(walkPeak.peak))GB "
              + "elapsed=\(Int(gridDuration.components.seconds))s+\(Int(walkDuration.components.seconds))s "
              + "thumbs=\(pool.count)张/\(pool.pixels)px "
              + "scan=\(report.generated)/\(report.pages) stop=\(report.stop.token)")

        await store.teardown()

        // 先判**测量有效性**,再判内存:扫描被取消或卡住时,那个峰值不代表完整路径,
        // 拿它去比验收线等于用一个无效样本得出一个看似有效的结论
        XCTAssertNotEqual(report.stop, .cancelled, "扫描被取消 —— 这一轮的峰值不代表完整路径")
        XCTAssertNotEqual(report.stop, .scannerStalled, "扫描器卡住 —— 内存数字不可比")

        let overall = max(gridPeak.peak, walkPeak.peak)
        XCTAssertLessThan(overall, MemoryAcceptanceLine.bytes,
                          "联合峰值 \(Self.gib(overall))GB 超验收线(设计文档 §5.3)。"
                          + "分段:网格扫描 \(Self.gib(gridPeak.peak))GB / 连翻 \(Self.gib(walkPeak.peak))GB"
                          + " —— 先看是哪一段顶上去的,再决定调哪个旋钮")
    }
}
