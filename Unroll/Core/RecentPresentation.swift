// AI-Generated | 可修改
// RecentPresentation —— 「最近打开」的展示层(2026-09-22)
// ----------------------------------------------------------------------------
// 「打开最近」菜单与空态欢迎页要显示**同一种**条目(文件名 + 续读进度 + 失效标记)。
// 原先这段拼装是 UnrollApp 的私有方法,空态要用就只能再抄一份 —— 抄出来的第二份
// 迟早与第一份分叉(出现「菜单标了 P.12/48、空态没标」这类不一致)。
// 与 ArchivePicker 同一条纪律:**共用一份口径,不复制**。
//
// 放 Core 的另一个理由是它一半是纯逻辑(进度拼装 / 失效后缀),可单测;
// 菜单文案原本只有 App 层能触到,测不到。
//
// 隐私:展示模型只带**文件名**,绝不带路径(同 §5.10.4 红线)。
import Foundation

/// 一条可直接渲染的最近打开条目
struct RecentItem: Identifiable, Equatable {

    let entry: RecentDocuments.Entry
    /// 已拼好进度 / 失效后缀的标题
    let title: String
    /// 书签探测判定为「文件已不在」—— 点之前就能看出来(§5.7 两段式)
    let isMissing: Bool

    var id: UUID { entry.id }
}

enum RecentPresentation {

    /// 空态列表的展示上限。它是**欢迎页不是管理器**:
    /// 列满 10 条会把「打开文件…」这个主入口挤出视觉重心(菜单那边仍然列全)。
    ///
    /// 取 4 的依据是**窗口最小高度**(`minWidth: 720, minHeight: 480`):
    /// 空态改成「图标 96 + 标题块 82 + 按钮 32 + 小抄 16 + 最近 N 条」之后,
    /// 按 4 条算是 465pt,5 条是 481pt —— 后者**刚好越界 1pt**,窗口收到最小时
    /// 底部会被裁掉半行。留 15pt 余量,不做"刚好放得下"的设计
    static let visibleLimit = 4

    /// 把存储条目 + 进度索引 + 失效集合拼成可渲染列表(菜单与空态共用)
    static func items(from entries: [RecentDocuments.Entry],
                      progress: RecentProgressIndex,
                      staleIDs: Set<UUID>) -> [RecentItem] {
        entries.map { entry in
            RecentItem(entry: entry,
                       title: title(for: entry, progress: progress, staleIDs: staleIDs),
                       isMissing: staleIDs.contains(entry.id))
        }
    }

    /// 条目标题:有续读记录则带上进度(缺总页数的老记录只显示页码);
    /// 探测出文件已不在的补一句「找不到文件」。
    /// 菜单与空态共用 —— 口径只有这一处。
    static func title(for entry: RecentDocuments.Entry,
                      progress: RecentProgressIndex,
                      staleIDs: Set<UUID>) -> String {
        let base: String
        if let saved = progress.entry(forDocument: entry.displayName) {
            if let total = saved.total, total > 0 {
                base = L10n.tr("app.menu.recentProgress", entry.displayName, saved.page + 1, total)
            } else {
                base = L10n.tr("app.menu.recentProgressUnknownTotal", entry.displayName, saved.page + 1)
            }
        } else {
            base = entry.displayName
        }
        return staleIDs.contains(entry.id)
            ? base + L10n.tr("app.menu.recentMissingSuffix")
            : base
    }
}
