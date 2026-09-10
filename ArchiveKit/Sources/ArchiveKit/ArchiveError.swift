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
    /// 7z / RAR 加密:系统库 libarchive 确认不支持解密(7z 已实测,RAR 待 M1 验证)
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
