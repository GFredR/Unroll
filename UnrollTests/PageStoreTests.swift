// AI-Generated | 可修改
// PageStoreTests —— actor 读页/去重/预读单测(M2 核心)
// ----------------------------------------------------------------------------
// ⚠️ 沙盒说明:宿主 App 开启 App Sandbox(§7.1-5),测试进程继承宿主沙盒,
// 仓库 fixture 路径(ArchiveKit/Tests/Fixtures)是否可读取决于运行环境:
// 若本文件用例被 skip 且输出含沙盒拒绝,即 fixture 不可达 —— 数据路径的
// 正确性已由 ArchiveKit 的 SequentialPageReaderTests(swift test,无沙盒)覆盖,
// 此处只补「actor 粘合层」(去重/预读/锚点)的验证,环境不允许时自动跳过不装绿。
import ArchiveKit
import XCTest
@testable import Unroll

@MainActor
final class PageStoreTests: XCTestCase {

    /// 仓库内 fixture 目录(相对本测试源文件:UnrollTests/ → 仓库根 → ArchiveKit/Tests/Fixtures)
    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // …/Unroll/UnrollTests
        .deletingLastPathComponent()      // …/Unroll(仓库根)
        .appendingPathComponent("ArchiveKit/Tests/Fixtures")

    /// fixture 不可达(沙盒拒绝/文件缺失)→ 用例 skip,不伪造结论
    private func makeStoreOrSkip() throws -> (PageStore, ArchiveDocument) {
        let url = Self.fixturesDir.appendingPathComponent("plain.cbz")
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("fixture 不可达(疑似测试宿主沙盒限制)—— 数据路径由 ArchiveKit 包内单测覆盖")
        }
        let document = try ArchiveDocument.open(url: url)
        return (PageStore(document: document), document)
    }

    // MARK: - 基本读页

    func testPageCountAndImageDecode() async throws {
        let (store, document) = try makeStoreOrSkip()
        defer { Task { await store.teardown() } }

        let count = await store.pageCount
        XCTAssertEqual(count, document.entries.count)

        let image = try await store.image(at: 0)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    /// 二次请求同一页应命中缓存(解码只发生一次 —— 无法直接观测解码次数,
    /// 但可观测:结果可再次取得且不抛错,管线稳定)
    func testRepeatedReadIsStable() async throws {
        let (store, _) = try makeStoreOrSkip()
        defer { Task { await store.teardown() } }

        let first = try await store.image(at: 1)
        let second = try await store.image(at: 1)
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
    }

    // MARK: - 并发去重

    /// 同页并发请求:两路都必须成功返回等价结果(不应有任务逃逸或崩溃)
    func testConcurrentSamePageRequestsBothSucceed() async throws {
        let (store, _) = try makeStoreOrSkip()
        defer { Task { await store.teardown() } }

        async let a = store.image(at: 0)
        async let b = store.image(at: 0)
        let (ia, ib) = try await (a, b)
        XCTAssertEqual(ia.width, ib.width)
        XCTAssertEqual(ia.height, ib.height)
    }

    // MARK: - 锚点与预读(图 5 PF 分支)

    /// 锚点更新后,+1 页应由预读任务拉进缓存(hasCachedImage 轮询观测)
    func testAnchorTriggersPrefetchIntoCache() async throws {
        let (store, _) = try makeStoreOrSkip()
        defer { Task { await store.teardown() } }

        _ = try await store.image(at: 0)
        let beforePrefetch = await store.hasCachedImage(1)
        XCTAssertFalse(beforePrefetch, "预读前 +1 页不应在缓存")

        await store.anchorDidChange(to: 0)
        var prefetched = false
        for _ in 0..<200 {                       // 上限 2s,超时即失败
            if await store.hasCachedImage(1) {
                prefetched = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(prefetched, "锚点更新后预读任务应把 +1 页拉进缓存")
    }

    // MARK: - 越界(绝不闪退)

    func testOutOfRangeThrowsInsteadOfCrashing() async throws {
        let (store, document) = try makeStoreOrSkip()
        defer { Task { await store.teardown() } }

        do {
            _ = try await store.image(at: -1)
            XCTFail("负索引必须抛错")
        } catch { /* 预期路径 */ }
        do {
            _ = try await store.image(at: document.entries.count)
            XCTFail("越界索引必须抛错")
        } catch { /* 预期路径 */ }
    }
}
