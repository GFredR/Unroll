// AI-Generated | 可修改
// RecentProgressIndex —— 续读记录按文件名建索引(2026-09-15)
// ----------------------------------------------------------------------------
// 「打开最近」菜单要标注每条记录读到第几页(P.3/200)。
// 续读存储的键是「文件名|大小」(隐私基线:不落路径),但菜单条目在 open 之前
// 拿不到文件大小(大小要 open 后才 stat),键对不上 —— 所以按**文件名**匹配。
//
// 同名多份(大小不同)时取 updatedAt 最新的一条:菜单只做提示,不存在正确性问题。
// 放在 Core 而非 App 结构体里,是为了可单测(菜单文案一半是纯逻辑)。
import Foundation

struct RecentProgressIndex: Equatable {

    /// 文件名 → 该名下的最新进度
    private let byName: [String: ReadingProgress.Entry]

    init(entries: [String: ReadingProgress.Entry]) {
        var out: [String: ReadingProgress.Entry] = [:]
        for (key, entry) in entries {
            let name = ReadingProgress.documentName(fromKey: key)
            if let existing = out[name], existing.updatedAt > entry.updatedAt { continue }
            out[name] = entry
        }
        byName = out
    }

    /// 该文件名对应的进度(无记录 → nil,菜单只显示文件名)
    func entry(forDocument name: String) -> ReadingProgress.Entry? {
        byName[name]
    }
}
