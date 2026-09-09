// AI-Generated | 可修改
// PageStore —— 预读调度 + 缓存协调(设计文档 §4.1 / §5.1 / §4.3 图 3,M2 实现)
// ----------------------------------------------------------------------------
// 为什么是 actor:预读任务与用户翻页请求并发竞争同一份归档句柄,
// actor 串行化访问,天然规避数据竞争(Swift 6 strict concurrency 下最省心)。
// M2 关键行为(§5.1 三对策全上):
//   · 顺序预读 ±2 页,低优先级、可随时取消(用户跳页时旧预读立刻作废);
//   · 大跨度跳页(>50 页)显示进度条,后台顺序扫描,不阻塞 UI;
//   · solid 7z / >500MB 归档:询问是否落盘临时目录(默认关),
//     落盘目录 NSTemporaryDirectory() 下按归档建,App 退出无条件清理(§5.1)。
// M0 占位:空壳。
actor PageStore {
    // TODO(M2): read(page:) / prefetch(around:) / cancelPrefetch() / teardown()
}
