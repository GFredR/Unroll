// AI-Generated | 可修改
// PageCache —— LRU + 像素预算页缓存(设计文档 §4.1 / §5.3 图 6,M2 实现)
// ----------------------------------------------------------------------------
// 两条设计要点(§5.3,写死在验收里):
//   · Trimmed ≠ 释放:被淘汰的页先降为 1600px 缩略图,不直接丢弃,
//     保证用户翻回来不至于白屏;
//   · 双阈值任一超出即触发 LRU 淘汰:≤8 页全分辨率 且 ≤2 亿像素
//     (阈值常量已放 DesignSystem.PageBudget,改预算只动那一个地方)。
// 底层用 NSCache(内存压力自动联动),自管 LRU 顺序与像素记账。
// M0 占位:空壳。
import Foundation

final class PageCache {
    // TODO(M2): put(page:image:) / image(at:) / trim() / totalPixels
}
