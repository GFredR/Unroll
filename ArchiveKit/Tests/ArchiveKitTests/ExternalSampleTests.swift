// AI-Generated | 可修改
// ExternalSampleTests —— 外部真实样本验证(设计文档 §5.8)
// ----------------------------------------------------------------------------
// 为什么需要这个文件:
//   fixture 只覆盖 zip / 7z / tar —— 这些本机造得出(make_fixtures.sh)。
//   但 **RAR 是私有格式**:7z / py7zr / libarchive 均只能读不能写,本机造不出样本;
//   `brew install rar` 已于 2026-09-01 因**未通过 macOS Gatekeeper 检查**被禁用,
//   按 §11 安全红线不绕过。所以 RAR4 / 加密 RAR 的验证只能靠「使用者提供的真实文件」。
//
// 为什么样本不入库:
//   真实 .cbr/.rar 来自使用者本机,文件名与内容本身即隐私(设计文档 §5.10 同款红线)。
//   因此本测试**不携带任何样本**,只提供「喂路径进来就能验」的脚手架。
//
// 用法(默认 skip,CI 安全):
//   UNROLL_EXTERNAL_SAMPLES="/path/a.cbr:/path/b.rar" swift test
//   或 Xcode:Unroll-Logic scheme → Run → 环境变量同上
//
// 2026-09-10 首次实测记录(5 个真实 RAR5 样本,条目数 1 / 444 / 568):
//   format=rar · protection=none · data(at:) 字节数与声明大小一致
//   → **RAR5 明文读取确认通过**;RAR4 与加密 RAR 仍无样本,见 §5.8。
import XCTest
@testable import ArchiveKit

final class ExternalSampleTests: XCTestCase {

    /// 冒号分隔的绝对路径列表。未设置 → 整组 skip(默认行为,保证 CI 稳定可复现)
    private var samplePaths: [String] {
        ProcessInfo.processInfo.environment["UNROLL_EXTERNAL_SAMPLES"]?
            .split(separator: ":").map(String.init) ?? []
    }

    /// 只断言「能开 + 首条目能完整读出」,**不断言具体格式** —— 样本由使用者提供,格式不定。
    /// 断言集刻意保守:外部样本形态未知,宁可少断言也不要误报。
    func testExternalSamplesOpenAndReadFirstEntry() throws {
        let paths = samplePaths
        try XCTSkipUnless(!paths.isEmpty, "未设置 UNROLL_EXTERNAL_SAMPLES —— 跳过外部样本验证(这是默认行为)")

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                XCTFail("样本不存在: \(path)")
                continue
            }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent

            let doc = try ArchiveDocument.open(url: url)
            XCTAssertFalse(doc.entries.isEmpty, "列为 0 条目: \(name)")

            // 读首条目:字节数应等于声明大小 —— 同时验证「能解开」与「未截断」
            if let declared = doc.entries.first?.size, declared > 0 {
                let data = try doc.data(at: 0)
                XCTAssertEqual(Int64(data.count), declared, "读取字节数与声明不符: \(name)")
            }

            // 仅本地诊断用;只打文件名,不打完整路径(隐私最小化)
            print("[external] \(name) format=\(doc.format) entries=\(doc.entries.count) protection=\(doc.protection)")
        }
    }
}
