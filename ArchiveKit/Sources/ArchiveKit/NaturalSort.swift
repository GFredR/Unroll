// AI-Generated | 可修改
// NaturalSort —— 自然排序(设计文档 §2.1 P0 第 8 条)
// ----------------------------------------------------------------------------
// 漫画页序必须是 page2 < page10(自然排序),字典序会得到 page10 < page2,
// 这是看图器最经典的翻页事故之一。M1 实现:按「数字段 / 非数字段」切分比较,
// 数字段按数值、前导零按长度打破平局(p001 与 p1 语义不同)。
// TODO(M1):实现 + 单测(含 page2<page10、page10<page2 反例、混合大小写、空串)。
public enum NaturalSort {

    /// a 是否应排在 b 之前
    public static func less(_ lhs: String, _ rhs: String) -> Bool {
        // M0 占位:普通字典序,仅保证骨架可编译,勿依赖此行为
        // TODO(M1): 替换为真正的自然排序实现(§2.1 P0-8)
        lhs < rhs
    }
}
