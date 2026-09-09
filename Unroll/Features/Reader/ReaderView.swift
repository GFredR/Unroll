// AI-Generated | 可修改
// ReaderView —— 阅读画布(设计文档 §4.1 / §5.2-5.5,M2 实现)
// ----------------------------------------------------------------------------
// 职责:单页 / 双页画布、缩放、平移手势、翻页动画。
// 注意(§5.4 的 Plan B):若 SwiftUI 大图实测掉帧,画布层整体换 AppKit
// NSScrollView 实现 —— 但这属于 M2 末的决策,View 接口形状先按 SwiftUI 设计。
// M0 占位:空实现,保证工程结构与 §4.1 目录约定一致。
import SwiftUI

struct ReaderView: View {

    var body: some View {
        EmptyView()   // TODO(M2): 接 ReaderViewModel,按页面状态机切换画布/加载/错误态
    }
}
