// AI-Generated | 可修改
// CArchiveShim 烟囱测试 —— M0 的核心验收点之一
// ----------------------------------------------------------------------------
// 目的:在写任何业务代码之前,先证明整条 C 桥接链路是通的:
//       module.modulemap 声明 → import → clang 编译 → 链接 -larchive → ABI 可调
// 只要这两条测试绿,设计文档 §3.2 的 POC 结论就在正式工程里复现了。
import XCTest
import CArchiveShim

final class CArchiveShimTests: XCTestCase {

    /// 验证「声明 + 链接 + 简单函数 ABI」整条链路。
    /// 本机(macOS 15.7.4)应返回 "libarchive 3.7.4…";macOS 14 更旧属预期
    /// (设计文档 §3.2 版本漂移警示,M1 验收⑥会在 14 上复测)。
    func testVersionStringLinksAndReturnsNonEmpty() throws {
        let raw = try XCTUnwrap(archive_version_string(), "链接失败或返回 NULL")
        let version = String(cString: raw)
        XCTAssertTrue(
            version.hasPrefix("libarchive"),
            "意外的版本串:\(version)"
        )
        print("📦 链接到的系统库版本:\(version)")
    }

    /// 锁死 archive_read_data_block 的返回类型为 int(4 字节)。
    /// 设计文档 §5.9.2 实测血泪:曾被声明成 8 字节,读到 4294967271 死循环。
    /// 手法:把 C 函数直接绑定到「返回 Int32」的 @convention(c) 函数指针 ——
    /// 若有人把 shim.h 的返回类型改坏,类型对不上,这里【编译失败】,
    /// 错误在编译期就被拦住,根本轮不到运行期死循环。
    /// (注意:只做绑定,不调用 —— 传 nil 真调会崩)
    func testDataBlockSignatureIsLockedToInt32() {
        let _: @convention(c) (
            OpaquePointer?, UnsafeMutablePointer<UnsafeRawPointer?>?,
            UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int64>?
        ) -> Int32 = archive_read_data_block
    }
}
