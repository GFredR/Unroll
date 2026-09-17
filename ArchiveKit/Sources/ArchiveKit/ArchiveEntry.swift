// AI-Generated | 可修改
// ArchiveEntry —— 归档条目模型(设计文档 §4.1)
// ----------------------------------------------------------------------------
// 纯值类型 struct,不含逻辑(AGENTS.md 三.3)。列目录时从 C 层提取一次,
// 之后 UI / 排序 / 缓存全部基于这个 Swift 模型,不再触碰 C API。
//
// ⚠️ 「这条是否加密」**刻意不在这里**(2026-09-17 澄清,旧注释曾写「从 _is_encrypted 填充」)。
// 加密标志住在 `ArchiveDocument.entryEncrypted: [Bool]`(按展示序对齐 entries),
// 原因是它只在两个地方被问:读页前置拦截、以及统计 encryptedImageCount —— 都是
// ArchiveDocument 的内部逻辑,不需要每个条目对象背一个 Bool(几百页的量级无谓膨胀)。
// 另一半原因更关键:`archive_entry_is_encrypted` 在**给了正确密码之后仍返回 1**
// (实测,见 ArchiveDocument 文件头①),它是一个「归档里怎么存的」事实,不是
// 「现在读不读得出」—— 混进入口模型最容易被误当后者。
public struct ArchiveEntry: Sendable, Equatable {

    /// 条目在归档内的相对路径,如 "vol01/p002.jpg"
    public let path: String

    /// 在 entries(自然排序后的图片列表)中的位置,0 起;data(at:) 以它定位。
    /// 原始遍历序号是 ArchiveDocument 内部实现细节(rawPositions),不外露
    public let index: Int

    /// 未压缩数据大小(字节);头部加密等场景可能拿不到 → nil 更诚实
    public let size: Int64?

    /// 是否为受支持的图片条目(过滤掉 __MACOSX/、隐藏文件、非图片)
    public let isImage: Bool

    public init(path: String, index: Int, size: Int64?, isImage: Bool) {
        self.path = path
        self.index = index
        self.size = size
        self.isImage = isImage
    }
}
