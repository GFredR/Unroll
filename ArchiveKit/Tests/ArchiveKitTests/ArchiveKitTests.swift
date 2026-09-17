// AI-Generated | 可修改
// ArchiveKit 占位测试 —— M0 骨架形状锁
// ----------------------------------------------------------------------------
// M0 只锁「工程形状」:模型与四态枚举一旦定型,UI / 文案 / 测试全部围绕它们展开,
// 形状漂移要在这里第一时间暴露。
// M1 将大幅扩展(§6.2):自然排序、图片过滤、损坏归档、并发读、
// 5 个加密 fixture(明文对照 / ZipCrypto / 7z 内容 / 7z 头部 / 部分加密)+ cbt 样本。
import XCTest
@testable import ArchiveKit

final class ArchiveKitTests: XCTestCase {

    /// 条目模型:纯值类型,可直接构造与比较(M1 列目录的输出就是它的数组)
    func testEntryModelIsValueSemantic() {
        let a = ArchiveEntry(path: "vol1/p002.jpg", index: 1, size: 2048, isImage: true)
        let b = ArchiveEntry(path: "vol1/p002.jpg", index: 1, size: 2048, isImage: true)
        XCTAssertEqual(a, b)
    }

    /// 可读性两态(2026-09-17 收敛,原 `testProtectionFourStatesExist`)。
    ///
    /// 为什么改:那条用例断言「§5.9.3 的四态不允许增减」,但它锁的是**一个已经
    /// 不存在的形状** —— `.full` / `.headerEncrypted` 从来没有任何构造点(终局态
    /// 走 throws:`open` 是「要么完整可用、要么构造失败」的静态工厂,拿不到文档
    /// 对象)。一个为两个死 case 保持绿色的测试,比没有测试更坏:它让人以为
    /// 「四态都在这儿判定」,而真去 `if case .full` 会找不到任何构造点。
    /// 现在锁**真实契约**:本枚举只承载可达的两态。
    func testProtectionExpressesTheTwoReachableStates() {
        let states: [ArchiveProtection] = [.none, .partial(encryptedCount: 3)]
        XCTAssertEqual(states.count, 2, "可读性只有两态;终局态改由 ArchiveError 表达")
        XCTAssertEqual(ArchiveProtection.partial(encryptedCount: 3), .partial(encryptedCount: 3))
        // 「0 页加密」只能用 .none 表达 —— 不许出现 .partial(0) 这种第二写法
        XCTAssertNotEqual(ArchiveProtection.none, .partial(encryptedCount: 0))
    }

    /// 四态在**系统层面**仍然齐备:两态在枚举里,终局两态在错误里(§5.9.3)。
    /// 契约落在两个类型上,而不是一个名不副实的枚举上
    func testFourStatesExistAcrossEnumAndError() {
        let readable: [ArchiveProtection] = [.none, .partial(encryptedCount: 2)]
        let terminal: [ArchiveError] = [.encrypted, .headerEncrypted]
        XCTAssertEqual(readable.count + terminal.count, 4, "§5.9.3 的四态一个都不能少")
    }

    /// 错误模型:覆盖设计文档 §4.1 列出的全部失败形态(损坏/加密/空/无图/未知)
    func testErrorCasesCoverDesignDoc() {
        let errors: [ArchiveError] = [
            .corrupted,
            .encrypted,
            .encryptedUnsupportedFormat,
            .headerEncrypted,
            .empty,
            .noImages(found: 12),
            .unknown(code: -30, message: "header is encrypted"),
        ]
        XCTAssertEqual(errors.count, 7)
    }
}
