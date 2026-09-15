// AI-Generated | 可修改
// ReadingProgress —— 续读记忆(v2 候选池「进度记忆」提前落地,2026-09-15)
// ----------------------------------------------------------------------------
// 每本文档记住:页码 + 双页/单页 + 左开/右开 + 缩放档位,重开同一文件自动恢复。
// 文档身份 = 文件名 + 文件大小(与最近打开同款隐私基线:只落文件名,不落路径;
// 同名不同文件靠大小区分,极端碰撞只是恢复错位,不致命)。
//
// 存储:UserDefaults 一个 JSON 字典,LRU 上限 64 条(超限剔除最旧)。
// 全链路 try? 静默容错:续读失败绝不影响打开主流程(§5.9.4 同款原则)。
import Foundation

struct ReadingProgress {

    static let maxEntries = 64

    /// 单条进度(Codable:整体编码进 UserDefaults;字段存 rawValue 字符串,
    /// 与 ReaderViewModel 的枚举解耦 —— Core 层不依赖 Features 层)
    struct Entry: Codable, Equatable {
        var page: Int
        var layout: String
        var direction: String
        var fitMode: String
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let key: String

    /// defaults 可注入(单测用 suite);生产用 standard
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "reading.progress.v1"
    }

    /// 文档身份键:文件名 + 文件大小
    static func key(name: String, size: Int) -> String { "\(name)|\(size)" }

    // MARK: - 读

    func entry(forKey key: String) -> Entry? {
        map()[key]
    }

    // MARK: - 写

    /// 记录一次进度(每次翻页/换模式都会调;UserDefaults 写入足够廉价)
    func save(key: String, page: Int, layout: String, direction: String, fitMode: String) {
        var dict = map()
        dict[key] = Entry(page: page, layout: layout, direction: direction,
                          fitMode: fitMode, updatedAt: Date())
        // LRU 上限:超限剔除最旧的条目
        if dict.count > Self.maxEntries {
            let oldest = dict.sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(dict.count - Self.maxEntries)
            for (k, _) in oldest { dict.removeValue(forKey: k) }
        }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: self.key)
        }
    }

    /// 清空(「清空最近打开」连带清,避免留下无主的进度)
    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func map() -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
