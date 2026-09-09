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
        static let title: CGFloat = 24
        static let body: CGFloat = 14
        static let footnote: CGFloat = 11
        /// HUD 页码等场景(M3)
        static let hud: CGFloat = 13
    }

    /// 圆角
    enum Radius {
        static let card: CGFloat = 8
        static let control: CGFloat = 6
    }

    /// 颜色:语义色优先(自动支持深浅);品牌 accent 未来对齐 AppIcon 主色(M3)
    enum Palette {
        static let accent = Color.accentColor
        static let background = Color(nsColor: .windowBackgroundColor)
        /// M2:阅读画布底色(纯黑最常见,漫画阅读器惯例)
        static let canvas = Color.black
    }

    /// 页面缓存预算(§5.3:LRU 淘汰阈值,M2 由 PageStore 使用)
    enum PageBudget {
        static let maxCachedPages = 8       // 最多同时保留 8 页全分辨率
        static let maxPixels: Int = 200_000_000   // ≤ 2 亿像素(≈ 8 页 × 5000×5000)
    }
}
