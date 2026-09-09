// AI-Generated | 可修改
// UnrollApp —— App 入口与生命周期(设计文档 §4.1 App/ 职责)
// ----------------------------------------------------------------------------
// M0:只提供可编译运行的最小窗口 + 占位页。
// M2 起:Finder 双击 / 拖拽的文件经 onOpenURL 进来,交给 ReaderViewModel.open(url)
//       (完整调用链见设计文档 §4.3 图 3 时序图)。
import SwiftUI

@main
struct UnrollApp: App {

    var body: some Scene {
        // 标题直接用 Localizable key,SwiftUI 会自动按系统语言解析(en / zh-Hans)
        WindowGroup("app.name") {
            M0PlaceholderView()
                .frame(minWidth: 720, minHeight: 480)
                // M2 接入: .onOpenURL { url in readerViewModel.open(url) }
        }
        .windowStyle(.automatic)
        // M3 接入: 全屏 HUD、右开本、双页模式;菜单栏命令(⌘O 打开、⌘W 关闭等)
    }
}
