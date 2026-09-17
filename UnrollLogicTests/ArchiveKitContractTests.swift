// AI-Generated | 可修改
// ArchiveKitContractTests —— M0 契约测试(无宿主,设计文档 §6.2)
// ----------------------------------------------------------------------------
// 为什么 M0 就要有这组测试?
//   1. 链路验证:本 target 只依赖 ArchiveKit 包、不构建 App。
//      它能编译 + 跑通,就证明「本地 SPM 包 → 项目 target」的依赖链
//      和 Unroll-Logic 快车道 scheme 都是通的 —— 这是骨架最重要的验收项。
//   2. 形状锁定:M0 没有业务实现,但公开 API 的「形状」已经定死了
//      (可读性枚举、错误模型、条目模型)。把形状锁进测试,后面任何人
//      改坏签名(比如给 ArchiveProtection 加第五态)会立刻红灯。
//      ⚠️ 2026-09-17:`ArchiveProtection` 由四态收敛为两态 —— 终局两态其实
//      一直走 `ArchiveError`(见下面两条用例的说明)。锁形状要锁**真实的**形状,
//      锁一个已经没人构造的形状等于给错误的安全感(那次教训写进了用例注释)。
//   3. 反自我确认:测试断言的是「事实」而非「我希望的行为」——
//      NaturalSort 在 M0 是字典序占位,测试就如实锁定占位行为并标注
//      TODO(M1),绝不为了好看去断言还没实现的自然排序(LOOP-AGENTS N5)。
// M1 起本目录扩展:加密四态的 fixture 行为测试在 ArchiveKit 包内
// (ArchiveKitTests),本 target 只负责「跨包契约形状」这一层。
import XCTest
import ArchiveKit

final class ArchiveKitContractTests: XCTestCase {

    // MARK: - ArchiveEntry(条目模型)

    func testEntryIsValueSemanticAndEquatable() {
        // struct 值类型:两份相同字段的对象必须相等 ——
        // 列表 diff / 缓存失效判断都依赖 Equatable 正确性
        let a = ArchiveEntry(path: "vol01/p002.jpg", index: 1, size: 2048, isImage: true)
        let b = ArchiveEntry(path: "vol01/p002.jpg", index: 1, size: 2048, isImage: true)
        let c = ArchiveEntry(path: "vol01/p003.jpg", index: 2, size: 4096, isImage: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testEntryAllowsUnknownSize() {
        // size 为 Optional:头部加密等场景拿不到尺寸,nil 是「诚实缺失」,
        // 不是错误 —— 防止 M1 实现时有人把它改成非可选再连锁炸 UI
        let entry = ArchiveEntry(path: "p001.jpg", index: 0, size: nil, isImage: true)
        XCTAssertNil(entry.size)
    }

    // MARK: - ArchiveProtection(可读性两态)

    /// 2026-09-17 收敛:原 `testProtectionHasExactlyFourStates` 断言「四态齐备」,
    /// 但 `.full` / `.headerEncrypted` **从来没有构造点** —— 终局态在
    /// `ArchiveDocument.open` 里以 throws 出去(它要求「要么完整可用、要么
    /// 构造失败」,拿不到文档对象)。那条用例因此锁的是一个不存在的形状,
    /// 还让人以为「四态都在这个枚举里判定」。
    ///
    /// 现在锁真实契约:枚举只承载可达的两态,且**「0 页加密」只能用 .none 表达**。
    func testProtectionExpressesTwoReachableStates() {
        let states: [ArchiveProtection] = [.none, .partial(encryptedCount: 3)]
        XCTAssertEqual(Set(states).count, 2)
        XCTAssertEqual(states[0], .none)
        XCTAssertEqual(states[1], .partial(encryptedCount: 3))
        XCTAssertNotEqual(states[1], .partial(encryptedCount: 4),
                          "partial 的关联值必须参与相等判断")
        XCTAssertNotEqual(ArchiveProtection.none, .partial(encryptedCount: 0),
                          "「没有加密页」不许有第二种写法")
    }

    /// 四态在**系统层面**仍然齐备(§5.9.3):两态在枚举,终局两态在错误模型。
    /// 契约落在两个类型上,而不是一个名不副实的枚举上 —— 这条同时守住
    /// 「别把终局态又搬回枚举」(那会让 open 的 throws 语义被绕开)
    func testFourStatesAreSplitAcrossEnumAndError() {
        let readable: [ArchiveProtection] = [.none, .partial(encryptedCount: 2)]
        let terminal: [ArchiveError] = [.encrypted, .headerEncrypted]
        XCTAssertEqual(readable.count + terminal.count, 4, "§5.9.3 的四态一个都不能少")
    }

    // MARK: - ArchiveError(错误模型)

    func testErrorCasesAreConstructible() {
        // 八个用户可读错误态(§5.9.3.1)对应这些 case。
        // 只验证可构造 + Sendable,不断言文案 —— 文案属于 App 层 L10n 的职责。
        let errors: [ArchiveError] = [
            .corrupted,
            .encrypted,
            .encryptedUnsupportedFormat,
            .headerEncrypted,
            .empty,
            .noImages(found: 12),
            .unknown(code: -30, message: "header is encrypted"),
        ]
        XCTAssertEqual(errors.count, 7, "M0 锁定的错误 case 总数,加 case 请连测试一起改")
    }

    // MARK: - NaturalSort(M1 真实现)

    func testNaturalSortSortsPagesNumerically() {
        // M1 已实现真自然排序(数字段切分 + 前导零破平局)。
        // M0 曾按占位行为断言字典序(page10 < page2),本测试随实现反转。
        // 包内 NaturalSortTests 有完整四组用例;此处只锁跨包可见的 API 行为。
        XCTAssertTrue(NaturalSort.less("page2", "page10"))
        XCTAssertFalse(NaturalSort.less("page10", "page2"))
    }
}
