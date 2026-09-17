// AI-Generated | 可修改
// ArchiveOpenCancellationTests —— 「打开能被叫停」的单测(2026-09-17)
// ----------------------------------------------------------------------------
// 背景(设计文档 §5.12):列目录是**同步阻塞**的 C 循环。VM 把它丢到后台线程后,
// 还需要一条「用户已经换文件了,别接着啃」的通道 —— 于是 open 收一个
// `isCancelled` 回调,每 256 个条目问一次,命中即抛 CancellationError。
//
// 这组用例守的**不是**「能不能取消」,而是**取消检查的位置**:
//
//   只测「一开始就已取消 → 立刻抛」是不够的 —— 把检查整个挪到 while 之前
//   (只查一次)那条用例**照样全绿**,而实际后果是:一个在取消之后才开始的
//   大包照样从头啃到尾,用户点「换书」没有任何效果。要区分这两种实现,
//   必须让归档**先列够一批条目**,再看检查会不会**再问一次**。
//
// 所以本组必须用 many-entries.cbz(303 个条目)—— 其余 fixture 只有个位数条目,
// 观察不到第二次检查。fixture 造法见 Tests/Fixtures/make_fixtures.sh §8c。
import XCTest
@testable import ArchiveKit

final class ArchiveOpenCancellationTests: XCTestCase {

    private enum Fixtures {
        static let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")

        static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    }

    /// 记录被问了几次、第几次起回答「已取消」。
    /// 回调是 `@Sendable`,而 Swift 6 不允许闭包捕获可变的局部变量 → 自己带一把锁。
    ///
    /// - Parameter cancelAfter: 第几次被问时回答 true(nil = 永远回答 false)
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let cancelAfter: Int?

        init(cancelAfter: Int? = nil) { self.cancelAfter = cancelAfter }

        /// 传给 `open(isCancelled:)` 的回调
        func makeCallback() -> @Sendable () -> Bool {
            { [self] in
                lock.lock()
                count += 1
                let nth = count
                lock.unlock()
                guard let cancelAfter else { return false }
                return nth >= cancelAfter
            }
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    // MARK: - 基线:这个包本来就该能开

    /// many-entries.cbz 是个**探针样本**,先证明它自己是合法的:
    /// 303 个条目(3 张真页 + 300 个零字节填充)里,3 张图被正常留下,
    /// 循环能正常走到 EOF。没有这条,下面两条用例失败时分不清
    /// 是「取消坏了」还是「样本坏了」。
    func testManyEntriesFixtureOpensWhenNeverCancelled() throws {
        let rec = Recorder()
        let doc = try ArchiveDocument.open(url: Fixtures.url("many-entries.cbz"),
                                           isCancelled: rec.makeCallback())

        XCTAssertEqual(doc.entries.map(\.path), ["page1.png", "page2.png", "page10.png"])
        // 303 个条目、每 256 个问一次 → 查询点落在条目 0 与条目 256 上,共 2 次。
        // 这个数字变了只有两种可能:检查间隔被改,或样本条目数被改 —— 两种都该被人看一眼
        XCTAssertEqual(rec.callCount, 2,
                       "查询次数 \(rec.callCount) ≠ 2:检查间隔或样本条目数被改过(cancellationCheckEvery=256 / 样本 303 条)")
    }

    // MARK: - 取消

    /// 进来就已取消 → 一次 `next_header` 都不做就退出。
    /// 这条只证明「最前面那道闸门有效」,**不**证明它在循环里。
    func testOpenAbortsImmediatelyWhenAlreadyCancelled() throws {
        let rec = Recorder(cancelAfter: 1)
        XCTAssertThrowsError(
            try ArchiveDocument.open(url: Fixtures.url("plain.cbz"), isCancelled: rec.makeCallback())
        ) { error in
            XCTAssertTrue(error is CancellationError,
                          "取消必须抛 CancellationError(VM 有专门分支,不能与「文件损坏」混为一谈),实际:\(error)")
        }
    }

    /// ★ 本组的核心:**列目录的中途**能被叫停。
    /// 前 256 个条目照列,第二次被问到时叫停 → 立刻抛,不把剩下 47 个条目啃完。
    /// 若有人把检查挪到 while 之外,这里会因为「只问过一次」而失败。
    func testCancellationIsRecheckedMidwayThroughListing() throws {
        let rec = Recorder(cancelAfter: 2)
        XCTAssertThrowsError(
            try ArchiveDocument.open(url: Fixtures.url("many-entries.cbz"),
                                     isCancelled: rec.makeCallback())
        ) { error in
            XCTAssertTrue(error is CancellationError, "中途叫停同样要抛 CancellationError,实际:\(error)")
        }

        XCTAssertGreaterThanOrEqual(rec.callCount, 2,
                                    "只问了 \(rec.callCount) 次 → 检查不在循环里(挪到循环外也能过),取消对大包等于失效")
    }
}
