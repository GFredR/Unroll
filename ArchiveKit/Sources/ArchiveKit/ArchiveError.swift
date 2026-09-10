// AI-Generated | 可修改
// ArchiveError —— 统一错误模型(设计文档 §4.1 / §5.9.3.1)
// ----------------------------------------------------------------------------
// 原则:所有失败走 throws / Result,UI 层据此切错误态页面(AGENTS.md 八)。
// 每个错误对应用户可读的双语文案(§5.9.3.1 的 8 组 key),绝不含英文技术原文。
// TODO(M1):定稿各 case 的关联值(如 C 状态码、错误串仅留日志用途),
//           并保证与 Localizable 的 key 一一对应。
// Equatable:单测断言「抛出的错误 == 预期 case」;关联值全是基础类型可自动合成
public enum ArchiveError: Error, Sendable, Equatable {
    /// 文件损坏 / 不是支持的归档格式
    case corrupted
    /// 全部条目加密(zip:理论上可解但 v1 未做密码框 → §7.3-A)
    case encrypted
    /// 加密但本版本读不了。证据强度按格式**不同**,勿一概而论:
    ///   · 7z  —— **实测确认** libarchive 不支持解密(报错 `currently not supported`)
    ///   · RAR —— **未实测**,属保守推断;第三方证据倾向"RAR5 实际可解"(§5.8)
    /// 二者当前共用本 case(v1 均无密码框,UI 结果一致),但**文案措辞必须区分**:
    /// 7z 可说「系统库不支持」,RAR 只能说「当前版本暂不支持」。
    case encryptedUnsupportedFormat
    /// 头部加密:连文件名列表都拿不到(四态之一)
    case headerEncrypted
    /// 归档为空(0 条目)
    case empty
    /// 列出了 N 条但没有一个图片
    case noImages(found: Int)
    /// 其余未知错误。code 为 libarchive 状态码,message 仅进日志,不进 UI
    case unknown(code: Int32, message: String?)
}
