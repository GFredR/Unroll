// AI-Generated | 可修改
// ArchiveEntry —— 归档条目模型(设计文档 §4.1)
// ----------------------------------------------------------------------------
// 纯值类型 struct,不含逻辑(AGENTS.md 三.3)。列目录时从 C 层提取一次,
// 之后 UI / 排序 / 缓存全部基于这个 Swift 模型,不再触碰 C API。
// TODO(M1):从 archive_entry_pathname / _size / _is_encrypted 填充,
//           并按扩展名(jpg/png/gif/webp/heic/tiff/avif)判定 isImage。
public struct ArchiveEntry: Sendable, Equatable {

    /// 条目在归档内的相对路径,如 "vol01/p002.jpg"
    public let path: String

    /// 在归档内的序号(next_header 遍历顺序,0 起)
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
