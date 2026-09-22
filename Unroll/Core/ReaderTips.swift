// AI-Generated | 可修改
// ReaderTips —— 一次性提示的「已经出现过」标记(2026-09-22)
// ----------------------------------------------------------------------------
// 只存**布尔**:存的是"这条提示出现过没有",不存任何文档信息、不存路径、不存时间。
// 隐私基线与 §5.10.4 一致 —— PageExportPanel 里记过同款判断:宁可每次重问,
// 也不往 UserDefaults 里写一条用户目录路径。一个布尔同样没有可反查的东西。
//
// 为什么单开一个存储:ReadingProgress / Bookmarks / RecentDocuments 各管一件事,
// 把提示标志塞进其中任何一个,都会让那个文件回答"我到底存什么"时说不清。
//
// ⚠️ 标记写在**出现的那一刻**,不是写在"点了 ×"上。差别在退出场景:
//   用户看了提示条但直接 ⌘Q,关掉的是 App 而不是提示条 ——
//   若把标记押在「点了 ×」上,他下次启动还会看到同一条提示,
//   而一个只在被主动关掉后才消失的提示,对不关它的人来说是永久浮层。
import Foundation

struct ReaderTips {

    private let defaults: UserDefaults
    private let hintKey: String

    /// defaults 可注入(单测用隔离 suite);生产用 standard
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hintKey = "reader.tips.hintShown"
    }

    /// 阅读提示条是否**已经出现过**。false = 还没见过(下次打开文档时该出现)。
    /// key 缺失时 `bool(forKey:)` 返回 false —— 正好就是"没见过",不必另设初值
    var hasShownHintBar: Bool { defaults.bool(forKey: hintKey) }

    /// 记下"已经出现过"。已经记过就直接返回 ——
    /// 每打开一本就写一遍同一个 true 没有意义,还平白多一次磁盘同步
    func markHintBarShown() {
        guard !hasShownHintBar else { return }
        defaults.set(true, forKey: hintKey)
    }
}
