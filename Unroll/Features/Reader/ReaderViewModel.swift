// AI-Generated | 可修改
// ReaderViewModel —— 页面状态机(设计文档 §4.1 / §4.3 图 3,M2 实现)
// ----------------------------------------------------------------------------
// 规范(AGENTS.md 三):@MainActor + ObservableObject,View 通过 @StateObject 监听;
// 状态枚举 idle / loading / success / error 驱动 UI 切换,View 不含业务逻辑。
// M2 的核心交互(全部走 async/await,PageStore 为 actor):
//   open(url) → 加密四态预检(§5.9)→ 建索引 → 读首页;
//   翻页命令 → PageStore.read(page:),回调 pageDidLoad;
//   错误一律转页面状态,绝不闪退(§5.9.4)。
// M0 占位:空壳。
import Foundation

@MainActor
final class ReaderViewModel: ObservableObject {
    // TODO(M2): state / archive / page / open(url:) / nextPage() / previousPage()
}
