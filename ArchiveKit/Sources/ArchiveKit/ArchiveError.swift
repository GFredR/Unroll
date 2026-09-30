// AI-Generated | 可修改
// ArchiveError —— 统一错误模型(设计文档 §4.1 / §5.9.3.1)
// ----------------------------------------------------------------------------
// 原则:所有失败走 throws / Result,UI 层据此切错误态页面(AGENTS.md 八)。
// 每个错误对应用户可读的双语文案(§5.9.3.1 的 8 组 key),绝不含英文技术原文。
//
// 关联值已定稿(2026-09-17 撤掉旧 TODO,它写于 M1 设计期,早已完成):
//   · `.unknown(code:message:)` —— code 是 libarchive 状态码;message **仅进日志**,
//     绝不进 UI(也绝不进面包屑:可能含完整路径,§5.9.4 约束 6);
//   · `.noImages(found:)` —— 条目总数,填进「已读取 N 个条目」那句文案;
//   · `.subfoldersOnly(count:)` —— 子文件夹个数。与 `.empty` 分开是**事实**问题
//     而不是措辞问题:一个是"这层什么都没有",一个是"这层只有文件夹"。
//     说错会把用户推向错误的排查方向(见下面 case 注释);
//   · `.wrongPassphrase` 与 `.encrypted` 刻意分开 —— 「密码不对,再试一次」和
//     「这个文件需要密码」是两件事,合并会让用户不知该做什么(见下面 case 注释)。
// UI 映射(错误 → 文案 key)在 `ReaderViewModel.openFailure` / `pageFailure` /
// `passwordFailure` 三处;本文件的注释只负责说清「语义边界」,不重复那三张表 ——
// 两边都写会漂移,而漂移出的文案错误用户第一个看到。
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
    /// 目录里**只有子文件夹**(或其它非普通文件),没有一个是页。
    /// 与 `.empty` 必须分开 —— 差的是一个事实判断:
    ///   · `.empty`           这一层**什么都没有** → 下一步是"换一个目录";
    ///   · `.subfoldersOnly`  这一层**有 N 个子文件夹** → 下一步是"改选具体那一话"。
    /// 说错不是措辞难看:用户被告知"文件夹是空的"之后,会去确认文件到底
    /// 存没存下来 / 下载完没完 —— 全是白费功夫(2026-09-30)。
    /// 只由目录源抛(`ArchiveDocument.openFolder`);归档侧 `.empty` 语义不变,
    /// 因为归档格式里没有"子目录"这个概念(它只有条目路径,递归与否由 Reader 定)
    case subfoldersOnly(count: Int)
    /// 其余未知错误。code 为 libarchive 状态码,message 仅进日志,不进 UI
    case unknown(code: Int32, message: String?)
}
