// AI-Generated | 可修改
// ArchiveProtection —— 归档**可读性**两态(设计文档 §5.9.3「加密四态」的落地形态)
// ----------------------------------------------------------------------------
// ⚠️ 别再往里加 `.full` / `.headerEncrypted`(2026-09-17 删除,它们从未被构造过)。
// 设计文档 §5.9.3 讲的「四态」在**系统层面**仍然成立,但落地时裂成了两处:
//
//   态                    表达者                        UI 响应
//   ---------------------------------------------------------------------------
//   none                  本枚举 .none                  正常进入阅读
//   partial               本枚举 .partial(encryptedCount:)  正常打开,加密页占位卡片
//   full(全部图片加密)    抛 ArchiveError.encrypted         打开阶段弹密码框
//   headerEncrypted       抛 ArchiveError.headerEncrypted  错误态页面(与「损坏」区分)
//
// 为什么终局态不住了这里:`ArchiveDocument.open` 是「要么完整可用、要么构造失败」
// 的静态工厂(§4.4 每 Task 独立实例),终局态根本拿不到文档对象 —— 它必须以 throws
// 的形式出去。枚举里再留两个永远为假的 case,只会让读代码的人以为
// 「full 也是这里判断的」,然后去 `if case .full` 却找不到任何构造点。
//
// 判定原始信号:archive_entry_is_encrypted(逐条统计,禁用 has_encrypted_entries)。
// 头部加密判定用「错误码 + 文案」双信号,防系统库升级换措辞后误判为损坏(§5.9.3 表)。
// 加密能力矩阵(zip 实测可解 / 7z 实测死限 / RAR 未实测)见 `ArchiveDocument.encryptionError(for:)`。
// Hashable:关联值全是 Int 可自动合成;UI 用 Set/字典按态索引时需要
public enum ArchiveProtection: Sendable, Equatable, Hashable {
    /// 没有读不出的页
    case none
    /// 有 N 页加密(未给密码时读不出);阅读器照常打开,这些页显示占位卡片
    case partial(encryptedCount: Int)
}
