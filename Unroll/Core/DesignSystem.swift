// AI-Generated | 可修改
// DesignSystem —— 设计 Token 唯一来源(AGENTS.md 六.8 / 十三.2)
// ----------------------------------------------------------------------------
// 规则:颜色 / 字号 / 间距 / 圆角只允许在这里定义,业务代码禁止散落字面值。
// 本项目未声明「支持暗黑模式」→ 仅浅色单一样式(系统语义色除外,自动适配)。
// M2/M3 若需要更多 Token(双页间距、HUD 底色等),继续往这里加,不要另起炉灶。
import SwiftUI

enum DesignSystem {

    /// 间距(4pt 网格)
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 32
        static let xl: CGFloat = 64
    }

    /// 字号(pt)—— 用 system size 保证跟随系统动态字重的基准值
    enum Typography {
        /// 空态欢迎页主标题(2026-09-14 UI 重做)
        static let display: CGFloat = 28
        static let title: CGFloat = 24
        static let body: CGFloat = 14
        static let footnote: CGFloat = 11
        /// HUD 页码等场景(M3)
        static let hud: CGFloat = 13
    }

    /// 圆角
    enum Radius {
        /// 空态虚线拖放框(2026-09-14 UI 重做)
        static let dropZone: CGFloat = 20
        static let card: CGFloat = 8
        static let control: CGFloat = 6
    }

    /// 颜色:语义色优先(自动支持深浅);品牌色 brand 与 AppIcon 主色锁定 teal 600。
    /// 设计决策:保留 `accent = Color.accentColor` 给系统语义控件跟随(系统色随系统更新);
    /// 产品级品牌色用 `brand` —— AppIcon、Logo、空状态插图、链接等需与图标一致的地方。
    /// M0 拍板:teal 600 #0F6E56(用户 2026-09-10 在 AppIcon 候选中确认,对应设计文档 §0)。
    enum Palette {
        static let accent  = Color.accentColor                                   // 系统语义控件色(随系统更新)
        static let brand   = Color(red: 0x0F/255, green: 0x6E/255, blue: 0x56/255) // teal 600 · 与 AppIcon 主色一致
        static let background = Color(nsColor: .windowBackgroundColor)            // 系统语义背景色(M0 占位页用)
        /// AppIcon squircle 底色(米白,作卡片/插图背景备用)
        static let surface = Color(red: 0xF1/255, green: 0xEF/255, blue: 0xE8/255)
        /// M2:阅读画布底色(纯黑最常见,漫画阅读器惯例)
        static let canvas  = Color.black
    }

    /// 页面缓存预算(§5.3:LRU 淘汰阈值,M2 由 PageStore 使用)
    enum PageBudget {
        static let maxCachedPages = 8       // 最多同时保留 8 页全分辨率
        static let maxPixels: Int = 200_000_000   // ≤ 2 亿像素(≈ 8 页 × 5000×5000)
        /// Trimmed 缩略图(§5.3:被淘汰页降 1600px 缩略图,不直接丢弃)的上限。
        /// 设计文档未定值:缩略图 ≈7MB/页,200 页全留会吃掉 GB 级内存,
        /// 24 张已远超「翻回来不白屏」的窗口(M2 拍板,超限按 LRU 彻底释放)
        static let maxThumbnails = 24
        /// 缩略图的**像素**预算(2026-09-17 新增)。
        ///
        /// 为什么必须另有这一条:`maxThumbnails` 只管**个数**,而单张缩略图的
        /// 像素随页面长宽比浮动 —— `thumbnailLongEdge` 卡的是**长边**,一张
        /// 1000×2000 的长条页缩完仍是 800×1600 ≈ 128 万像素;最坏情形
        /// (正方形页)1600×1600 = 256 万像素。24 张按最坏算是 **6100 万像素
        /// ≈ 244 MB**,而它**完全不在 `maxPixels` 的统计里**(那只算全分辨率页)。
        /// 结论:页数一多、「翻回去不白屏」的窗口一铺开,这一池子能悄悄涨到
        /// 全分辨率池子的三分之一 —— 个数上限挡不住内存,像素才挡得住。
        ///
        /// 20 Mpx ≈ 80 MB:按典型 2:3 页(≈170 万像素/张)折合约 **11 张**,
        /// 足够覆盖「翻回来」的那几页;超出即按 LRU 释放,与全分辨率池同一套语义
        static let maxThumbnailPixels: Int = 20_000_000
        /// 缩略图长边像素(§5.3 图 6 Trimmed 态定义)
        static let thumbnailLongEdge: CGFloat = 1600
    }
}
