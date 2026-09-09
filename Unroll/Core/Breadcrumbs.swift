// AI-Generated | 可修改
// Breadcrumbs —— 崩溃面包屑(设计文档 §4.1 / §5.10,M4 实现)
// ----------------------------------------------------------------------------
// L0 崩溃采集三件套之一:ring buffer ≤20 条,实时落盘(≤4KB JSON),
// 供下次启动「异常退出自检」生成 GitHub issue 草稿。
// 隐私红线(§5.10.4,写进 code review 清单):
//   【绝对不采】文件名 / 路径 / 归档内容 —— 只记「打开了归档」「翻到第 N 页」
//   这类动作级事件;写入与读取全链路 try? 静默降级,面包屑自身绝不能把 App 搞崩。
// M0 占位:空壳。
import Foundation

struct Breadcrumbs {
    // TODO(M4): record(event:) / snapshot() / persist() / clear()
}
