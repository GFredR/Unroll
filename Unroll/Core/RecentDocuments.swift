// AI-Generated | 可修改
// RecentDocuments —— 最近打开(设计文档 §0 决策 13 / §4.1,M3 实现)
// ----------------------------------------------------------------------------
// 沙盒下不能记住裸路径:App 退出后文件访问权即失效,
// 必须存 security-scoped bookmark(应用域),重开时 startAccessing 后才能读。
// entitlements 已声明 bookmarks.app-scope(见 Unroll/Unroll.entitlements)。
// 上限 10 条,不含任何缩略图(隐私:不落盘文件内容,只存 URL 书签)。
// M0 占位:空壳。
import Foundation

struct RecentDocuments {
    // TODO(M3): add(url:) / entries() / startAccess(at:) / stopAccess(_:)
}
