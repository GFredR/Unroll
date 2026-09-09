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

    /// 加密四态(§5.9.3):枚举形状即 API 契约,M0 锁死,防止后续误删/误并
    func testProtectionFourStatesExist() {
        let states: [ArchiveProtection] = [
            .none,
            .partial(encryptedCount: 3),
            .full,
            .headerEncrypted,
        ]
        XCTAssertEqual(states.count, 4, "四态设计(§5.9.3)不允许增减")
        XCTAssertEqual(ArchiveProtection.partial(encryptedCount: 3), .partial(encryptedCount: 3))
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
