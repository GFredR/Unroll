// AI-Generated | 可修改
// Bookmarks —— 书签页(2026-09-15,v2 候选池「书签」)
// ----------------------------------------------------------------------------
// 每本文档记住一组「被标记的页」,菜单里可直接跳转。
// 文档身份与续读共用同一键:文件名 + 文件大小(不落路径,隐私基线一致)。
//
// 存储:UserDefaults 一个 JSON 字典 [文档键: 条目],LRU 上限 64 本文档;
// 每本上限 200 个书签(超过丢最早的页码 —— 正常阅读不可能触及)。
// 全链路 try? 静默容错:书签读写失败绝不影响阅读主流程。
import Foundation

struct Bookmarks {

    static let maxDocuments = 64
    static let maxPagesPerDocument = 200

    /// 单本文档的书签集合(Codable:整体编码进 UserDefaults)
    struct Entry: Codable, Equatable {
        /// 页码升序(便于「下一书签」二分/顺序查找)
        var pages: [Int]
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let key: String

    /// defaults 可注入(单测用隔离 suite)
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "bookmarks.v1"
    }

    // MARK: - 读

    /// 该文档的书签页(升序);无记录 → 空数组
    func pages(forKey key: String) -> [Int] {
        map()[key]?.pages ?? []
    }

    // MARK: - 写

    /// 切换某一页的书签状态,返回切换后是否处于「已标记」
    @discardableResult
    func toggle(page: Int, key: String) -> Bool {
        var dict = map()
        var pages = dict[key]?.pages ?? []
        let marked: Bool
        if let idx = pages.firstIndex(of: page) {
            pages.remove(at: idx)
            marked = false
        } else {
            pages.append(page)
            pages.sort()
            if pages.count > Self.maxPagesPerDocument {
                pages.removeFirst(pages.count - Self.maxPagesPerDocument)
            }
            marked = true
        }
        dict[key] = Entry(pages: pages, updatedAt: Date())
        pruneIfNeeded(&dict)
        persist(dict)
        return marked
    }

    /// 清空某本文档的书签
    func clearDocument(key: String) {
        var dict = map()
        dict.removeValue(forKey: key)
        persist(dict)
    }

    /// 清空全部书签(「清空最近打开」连带清,不留无主数据)
    func clear() {
        defaults.removeObject(forKey: key)
    }

    // MARK: - 内部

    /// 文档数超限:剔除最久未更新的
    private func pruneIfNeeded(_ dict: inout [String: Entry]) {
        guard dict.count > Self.maxDocuments else { return }
        let oldest = dict.sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(dict.count - Self.maxDocuments)
        for (k, _) in oldest { dict.removeValue(forKey: k) }
    }

    private func persist(_ dict: [String: Entry]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: key)
        }
    }

    private func map() -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
