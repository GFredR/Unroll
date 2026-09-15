// AI-Generated | 可修改
// RecentDocuments —— 最近打开(设计文档 §0 决策 13 / §5.7,M3 实现)
// ----------------------------------------------------------------------------
// 沙盒下不能记住裸路径:App 退出后文件访问权即失效,
// 必须存 security-scoped bookmark(应用域),重开时 startAccessing 后才能读。
// entitlements 已声明 bookmarks.app-scope(见 Unroll/Unroll.entitlements)。
// 上限 10 条,不含任何缩略图(隐私:不落盘文件内容,只存 URL 书签)。
//
// 存储格式:UserDefaults 里一个 Data 数组,每项是 [书签数据 + name] 的 JSON。
// 旧书签文件被移动/删除 → 解析或 startAccess 失败 → 不打致命错(§5.9.4
// 「坏条目不致命」原则)。全链路 try?,面包屑级容错:任何失败都不影响打开主流程。
//
// 失效条目处理(2026-09-15 修订):原先只在点击时静默剔除,用户视角是
// 「菜单项无声消失,不知道发生了什么」。现改为两段式:
//   ① `unresolvableIDs()` 探测标记 —— 低频时机(启动/打开文件)调用,
//      菜单项带「找不到文件」后缀,点之前就能看出;
//   ② 点击仍失败才真剔除,并由 App 层弹一句说明。
// 探测与清理分离:`unresolvableIDs()` 是只读的,删不删由调用方决定。
import Foundation

struct RecentDocuments {

    static let maxEntries = 10

    /// 最近打开条目(展示用)。Codable:整体编码进 UserDefaults
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let name: String
        let bookmark: Data

        /// 展示名:仅文件名,绝不存/显示完整路径(隐私红线同 §5.10.4)
        var displayName: String { name }
    }

    private let defaults: UserDefaults
    private let key: String

    /// defaults 可注入(单测用 suite);生产用 standard
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "recent.archives.v1"
    }

    // MARK: - 读

    func entries() -> [Entry] {
        guard let raw = defaults.array(forKey: key) as? [Data] else { return [] }
        return raw.compactMap {
            try? JSONDecoder().decode(Entry.self, from: $0)
        }
    }

    // MARK: - 写

    /// 记录一次打开:同名同文件去重(按书签数据不可比,按名字+大小近似不可靠,
    /// 直接用「解码后同 path 存在则置顶」;书签不可逆解,这里存一份冗余 path 不可取 ——
    /// 折中:名字相同即视为同一文件,置顶不重复)
    func add(url: URL) {
        var list = entries()
        let entry = Entry(id: UUID(),
                          name: url.lastPathComponent,
                          bookmark: (try? url.bookmarkData(options: .withSecurityScope)) ?? Data())
        // 书签造不出来(理论上少见于用户选中的文件):仍记名字,重开时剔除即可
        list.removeAll { $0.name == entry.name }
        list.insert(entry, at: 0)
        if list.count > Self.maxEntries {
            list.removeLast(list.count - Self.maxEntries)
        }
        persist(list)
    }

    /// 清空(菜单「清除菜单」用;失败静默)
    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func persist(_ list: [Entry]) {
        let raw = list.compactMap { try? JSONEncoder().encode($0) }
        defaults.set(raw, forKey: key)
    }

    // MARK: - 沙盒作用域

    /// 重开书签:返回可访问 URL 并 startAccessing(调用方负责配对 stopAccess)。
    /// 失败(文件被移走/书签失效)→ nil,调用方从列表剔除
    func resolve(_ entry: Entry) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else {
            return nil
        }
        // stale 书签也能解析但数据可能过期:重新落一份(尽力而为,失败不影响本次打开)
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            var list = entries()
            if let idx = list.firstIndex(where: { $0.id == entry.id }) {
                list[idx] = Entry(id: entry.id, name: entry.name, bookmark: fresh)
                persist(list)
            }
        }
        return url
    }

    /// 与 resolve 配对(没有对应 startAccess 时调用也无害)
    func stopAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// 探测失效条目:书签解析不出可访问 URL(文件被移走/删除)。
    ///
    /// **只读**:不改动已存列表(连 stale 书签的刷新都不做);删不删由调用方决定
    /// (UI 要先让用户看见标记)。成本:每条解析一次书签并 startAccess/stopAccess
    /// 配对(净计数不变,不影响正在阅读的文件的访问权)。故意不做缓存 —— 调用点
    /// 只有「启动」这类低频时机;翻页刷新走 `entries()` 不探测。
    func unresolvableIDs() -> Set<UUID> {
        var stale: Set<UUID> = []
        for entry in entries() {
            if let url = resolveQuietly(entry) {
                stopAccess(url)
            } else {
                stale.insert(entry.id)
            }
        }
        return stale
    }

    /// 探测专用解析:**不产生任何副作用** —— 不挂载网络卷、不弹授权 UI。
    /// 与 `resolve`(用户主动点击时的重开,允许挂载/允许系统 UI)分开:
    /// 启动时替用户去挂载网络卷或弹认证框是不能接受的。
    private func resolveQuietly(_ entry: Entry) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark,
                                 options: [.withSecurityScope, .withoutMounting, .withoutUI],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else {
            return nil
        }
        return url
    }

    /// 剔除单条(书签失效时菜单点击后清理)
    func remove(_ entry: Entry) {
        var list = entries()
        list.removeAll { $0.id == entry.id }
        persist(list)
    }
}
