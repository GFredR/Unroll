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
    /// 全部图片加密,**且尚未提供密码**(zip / rar)。
    /// v2(2026-09-17)起这不是终局错误:UI 收到它就弹密码输入,
    /// 用户输对即进入阅读(v1 时无密码框,它是终局态)。
    case encrypted
    /// 提供了密码但**不对**:libarchive 报 "Incorrect passphrase"(实测)。
    /// 与 `.encrypted` 分开是为了 UI 能说准话 —— 「密码不对,再试一次」
    /// 和「这个文件需要密码」是两件事,合并会让用户不知该做什么。
    case wrongPassphrase
    /// 加密但本版本读不了。两个来源,措辞必须区分:
    ///   · **7z** —— 实测确认库不支持(`currently not supported`),故**不给密码入口**;
    ///   · **RAR** —— v2 给密码入口,但若库确实解不了,会经 passphraseFailure
    ///     落到这里 → 用户看到「这个归档解不开」(而不是对着密码框一直试)。
    ///     证据强度与 7z 完全不同,见 `encryptionError(for:)` 的说明。
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
