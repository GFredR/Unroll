// AI-Generated | 可修改
// ArchiveProtection —— 加密四态(设计文档 §5.9.3,M0 锁死枚举形状)
// ----------------------------------------------------------------------------
// 四态是整个加密设计的骨架(图 10),各态对应完全不同的 UI 响应:
//   .none            encryptedCount == 0            正常进入阅读
//   .partial         0 < encryptedCount < 总条目数   正常打开,加密页占位卡片
//   .full            encryptedCount == 总条目数      打开即错误态页面(按格式分文案)
//   .headerEncrypted 列目录 0 条 + 错误码 -30 且文案含 "header is encrypted"
//                                                  错误态页面,与「损坏」区分
// 判定原始信号:archive_entry_is_encrypted(逐条统计,禁用 has_encrypted_entries)。
// 头部加密判定用「错误码 + 文案」双信号,防系统库升级换措辞后误判为损坏(§5.9.3 表)。
// TODO(M1):实现 detect(...) 并以 5 个加密 fixture 进单测(§6.2)。
// Hashable:关联值全是 Int 可自动合成;UI 用 Set/字典按态索引时需要
public enum ArchiveProtection: Sendable, Equatable, Hashable {
    case none
    case partial(encryptedCount: Int)
    case full
    case headerEncrypted
}
