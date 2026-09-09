// AI-Generated | 可修改
// ArchiveKitContractTests —— M0 契约测试(无宿主,设计文档 §6.2)
// ----------------------------------------------------------------------------
// 为什么 M0 就要有这组测试?
//   1. 链路验证:本 target 只依赖 ArchiveKit 包、不构建 App。
//      它能编译 + 跑通,就证明「本地 SPM 包 → 项目 target」的依赖链
//      和 Unroll-Logic 快车道 scheme 都是通的 —— 这是骨架最重要的验收项。
//   2. 形状锁定:M0 没有业务实现,但公开 API 的「形状」已经定死了
//      (四态枚举、错误模型、条目模型)。把形状锁进测试,后面任何人
//      改坏签名(比如给 ArchiveProtection 加第五态)会立刻红灯。
//   3. 反自我确认:测试断言的是「事实」而非「我希望的行为」——
//      NaturalSort 在 M0 是字典序占位,测试就如实锁定占位行为并标注
//      TODO(M1),绝不为了好看去断言还没实现的自然排序(LOOP-AGENTS N5)。
// M1 起本目录扩展:detect(...) 的 5 个加密 fixture 行为测试(§6.2)。
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

    // MARK: - ArchiveProtection(加密四态)

    func testProtectionHasExactlyFourStates() {
        // 四态是 §5.9.3 图 10 的骨架,对应四种完全不同的 UI 响应。
        // 全部 case 能构造 + 能判等,锁死枚举形状。
        let states: [ArchiveProtection] = [
            .none,
            .partial(encryptedCount: 3),
            .full,
            .headerEncrypted,
        ]
        XCTAssertEqual(Set(states).count, 4, "四态两两不等 —— 加重名态会静默吞掉一态")
        XCTAssertEqual(states[0], .none)
        XCTAssertEqual(states[1], .partial(encryptedCount: 3))
        XCTAssertNotEqual(states[1], .partial(encryptedCount: 4),
                          "partial 的关联值必须参与相等判断")
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

    // MARK: - NaturalSort(M0 占位行为,如实锁定)

    func testNaturalSortPlaceholderIsLexicographic() {
        // ⚠️ 本测试锁定的是 M0 占位行为(字典序),不是最终需求!
        // page10 < page2 在字典序下成立、在自然排序下不成立。
        // M1 实现真正的自然排序后,本测试必须反转断言并改名
        // (TODO(M1): 见 NaturalSort.swift 头注释的 4 组用例)。
        XCTAssertTrue(NaturalSort.less("page10", "page2"))
    }
}
