// AI-Generated | 可修改
// PageStore —— 预读调度 + 缓存协调(设计文档 §4.1 / §5.1 / §4.3 图 3,M2 实现)
// ----------------------------------------------------------------------------
// 为什么是 actor:预读任务与用户翻页请求并发竞争同一份归档句柄,
// actor 串行化访问,天然规避数据竞争(Swift 6 strict concurrency 下最省心)。
//
// §5.1 三对策的落点(全部在本文件):
//   · **单实例顺序扫描器**:持有一个 SequentialPageReader 顺序吐页,
//     绝不每页调 ArchiveDocument.data(at:)(那是实测 71× 慢的 O(n²) 模式,
//     见 docs/测试与验证.md §4)。扫描器非 Sendable 是故意的 —— 只能活在
//     本 actor 里,跨域传递直接编译报错;
//   · 顺序预读 +1/+2 页,低优先级、可随时取消(用户跳页时旧预读立刻作废);
//   · 大跨度跳页:扫描器内部按「后向/重置才重建实例」处理,前向大跳是
//     线性代价不重建 —— UI 层的进度条(§5.1 对策 1)在 M2 末做实测后定。
//
// 阻塞说明:扫描器的 C 调用在 actor 内同步执行(顺序读便宜,150 页 34ms),
// 换取「无锁 + 单一真源」;若未来实测遇到长尾卡顿,再把读段拆到专用串行队列。
import ArchiveKit
import CoreGraphics
import Foundation
import ImageIO

actor PageStore {

    private let document: ArchiveDocument

    /// 单实例顺序扫描器(§5.1 硬约束)。惰性创建:首个读请求才开 C 句柄
    private var scanner: SequentialPageReader?

    /// 页缓存(LRU + 像素预算 + 缩略图降级)。
    /// 淘汰事件转成面包屑(M4 §5.10.3-① 示例轨迹里的 cacheEvict/cacheDemote);
    /// 测试宿主内 Breadcrumbs 自动静默(UnrollRuntime),不会污染真实诊断文件
    private let cache = PageCache(onEviction: { page, kind in
        switch kind {
        case .demoted: Breadcrumbs.shared.record(.cacheDemote(page: page))
        case .evicted: Breadcrumbs.shared.record(.cacheEvict(page: page))
        }
    })

    /// 解码中的任务(按页去重:两个并发请求同一页只解码一次)
    private var inFlight: [Int: Task<CGImage, Error>] = [:]

    /// 后台预读任务(锚点变化时整批取消)
    private var prefetchTasks: [Task<Void, Never>] = []

    init(document: ArchiveDocument) {
        self.document = document
    }

    // MARK: - 观测

    var pageCount: Int { document.entries.count }
    var archiveProtection: ArchiveProtection { document.protection }

    // MARK: - 读页(图 5 REQ→NEW→DEC→PUT 主链)

    /// 取某页全分辨率 CGImage:缓存命中直接回;否则读原始字节(actor 内
    /// 顺序扫描)+ 后台解码 + 入缓存(超预算即 LRU 淘汰)。
    /// 同页并发请求只解码一次(in-flight 去重)。
    ///
    /// 抛错语义(§5.9.4 约束 4):单页失败(损坏页/加密页)只抛给调用方,
    /// 不影响其他页 —— PageStore 本身不因任何单页错误进入不可用态
    func image(at index: Int) async throws -> CGImage {
        guard document.entries.indices.contains(index) else {
            // 调用方 bug 兜底:绝不 trap(§5.9.4「绝不闪退」)
            throw ArchiveError.unknown(code: 0, message: "page \(index) out of range")
        }

        if let image = cache.fullImage(at: index) {
            return image
        }
        if let existing = inFlight[index] {
            // 同页并发请求:等待首次解码的结果(缓存登记由首个 awaiter 完成)
            return try await existing.value
        }

        // RAW 段:actor 内同步读(顺序前进;后向访问扫描器自动重开重建)。
        // Data 是 Sendable 值,可安全移交解码任务
        let data = try readRaw(index)

        // DEC 段:解码放后台(一张 4000×6000 扫描件解码 ≈ 百毫秒级,
        // 不能占着 actor 卡住后续翻页请求)
        let task = Task.detached(priority: .userInitiated) {
            try PageDecoder.decode(data)
        }
        inFlight[index] = task
        defer { inFlight[index] = nil }
        let image = try await task.value
        cache.insert(page: index, image: image)
        return image
    }

    // MARK: - 占位缩略图(图 5 PLACE 分支)

    /// Trimmed 态的缩略图(无则 nil,**不触发加载** —— 加载是 image(at:) 的职责)
    func cachedThumbnail(at index: Int) -> CGImage? {
        guard document.entries.indices.contains(index) else { return nil }
        return cache.thumbnail(at: index)
    }

    /// 观测(测试/诊断):该页是否已有全分辨率缓存(纯查询,不触碰 LRU)
    func hasCachedImage(_ index: Int) -> Bool {
        cache.hasFullImage(index)
    }

    // MARK: - 预读(图 5 PF 分支)

    /// 锚点更新:翻到新页后调用。取消全部旧预读,预读 +1/+2(图 5 只向后,
    /// 因为 solid 7z 后向 = 重开重建,预读方向必须是阅读主方向)
    func anchorDidChange(to index: Int) {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()

        for offset in [1, 2] {
            let target = index + offset
            guard document.entries.indices.contains(target) else { continue }
            guard cache.fullImage(at: target) == nil, inFlight[target] == nil else { continue }

            prefetchTasks.append(Task(priority: .utility) { [weak self] in
                // 预读失败静默吞掉:真请求到达时会在 image(at:) 里抛出正确错误,
                // 预读的职责只是「让大概率会来的那一页提前就位」
                _ = try? await self?.image(at: target)
            })
        }
    }

    // MARK: - 生命周期

    /// 换归档 / 窗口关闭:取消全部任务、释放扫描器与缓存。
    /// 调用后本对象应被丢弃(VM 置 nil)
    func teardown() {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        scanner?.close()
        scanner = nil
        cache.removeAll()
    }

    // MARK: - 内部

    /// 顺序扫描取原始字节(扫描器惰性创建,生命周期与 PageStore 同步)
    private func readRaw(_ index: Int) throws -> Data {
        let reader: SequentialPageReader
        if let existing = scanner {
            reader = existing
        } else {
            let created = SequentialPageReader(document: document)
            scanner = created
            reader = created
        }
        return try reader.data(at: index)
    }
}

// MARK: - 解码(图 4 DEC 段,ImageIO)

/// ImageIO 解码器:Data → CGImage。
/// 独立枚举而非 PageStore 方法:解码是纯函数(入参出参皆值语义),
/// 放 actor 外便于在 detached Task 里调用、也便于单测
enum PageDecoder {

    /// 解码一页。失败(非图片/损坏/加密内容)→ ArchiveError.corrupted:
    /// VM 据此切「单页失败」卡片(§5.9.4 约束 3:CGImage 可能为 nil,必须判空)。
    ///
    /// kCGImageSourceShouldCacheImmediately = true:强制在**本任务**完成整页
    /// 位图解码,而不是拖到主线程首次绘制时(否则翻页必掉帧 —— 图 8 的「每帧
    /// 重解码」就是这个坑的另一种形态)。kCGImageSourceShouldCache = false:
    /// 缓存由 PageCache 的像素预算统一管,ImageIO 不得再私存一份
    static func decode(_ data: Data) throws -> CGImage {
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw ArchiveError.corrupted
        }
        return image
    }
}
