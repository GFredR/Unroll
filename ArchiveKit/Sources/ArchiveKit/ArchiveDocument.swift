// AI-Generated | 可修改
// ArchiveDocument —— 打开归档的门面(设计文档 §4.1 / §4.3 图 3)
// ----------------------------------------------------------------------------
// 生命周期:open(url) → 列目录建索引(含四态检测)→ data(at:) 按页取字节
//          → ImageIO 解码 → close()。
// M1 关键实现点(全部来自实测结论,详见设计文档 §3.2 / §5.9):
//   · 每个归档一个独立实例,Task 并发读靠「一档一实例」绕开 Sendable 难题(§3.2)
//   · C 返回码全部翻译成 ArchiveError,禁止 try!(§5.9.4 工程约束)
//   · 读页循环设迭代上限,防 data_block 签名错误回归导致死循环(§5.9.2)
//   · close 幂等:deinit 兜底释放,防止快速切换归档时句柄泄漏
// TODO(M1):实现上述全部行为 + 5 个加密 fixture 单测(§6.2)。
public final class ArchiveDocument {

    // M0 占位:空壳保证工程结构与 §4.1 一致,M1 填充真实 API
    // public init() / func open(url: URL) throws / func entries() -> [ArchiveEntry]
    // func data(at index: Int) throws -> Data / func close()
    public init() {}
}
