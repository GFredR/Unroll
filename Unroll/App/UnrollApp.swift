// AI-Generated | 可修改
// UnrollApp —— App 入口与生命周期(设计文档 §4.1 App/ 职责)
// ----------------------------------------------------------------------------
// M2:窗口根视图换成 ReaderView(空态/打开中/错误态/画布四态由 VM 驱动);
//     Finder 双击经 onOpenURL 进来(Info.plist 已声明四种漫画归档的 Default 关联),
//     拖拽由 ReaderView 根部的 dropDestination 承接(全阶段可用)。
// M3 接入: 全屏 HUD、右开本、双页模式;菜单栏命令(⌘W 关闭等)。
import SwiftUI

@main
struct UnrollApp: App {

    @StateObject private var reader = ReaderViewModel()

    var body: some Scene {
        // 标题直接用 Localizable key,SwiftUI 会自动按系统语言解析(en / zh-Hans)
        WindowGroup("app.name") {
            ReaderView(viewModel: reader)
                .frame(minWidth: 720, minHeight: 480)
                // Finder 双击 / 系统打开方式:文件访问权由系统自动授予(沙盒下同理)
                .onOpenURL { url in
                    reader.open(url: url)
                }
        }
        .windowStyle(.automatic)
    }
}
