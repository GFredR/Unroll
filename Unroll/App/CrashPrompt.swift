// AI-Generated | 可修改
// CrashPrompt —— 崩溃自愿上报弹窗(设计文档 §5.10.3-③、§5.10.5)
// ----------------------------------------------------------------------------
// 两条硬约束在这里落地:
//   · §5.10.5-① **不得拖慢冷启动** —— 检查放后台、弹窗延迟到启动后 1.5s,
//     「秒开」先发生,问不问用户是之后的事;
//   · §5.10.5-② **绝不二次弹窗** —— 取不到报告就什么都不发生(静默降级)。
//
// 上报动作本身只做一件事:把预填好的 GitHub issue 链接交给浏览器。
// App **不发任何网络请求**(沙盒下也没有网络权限),内容用户看得见、发不发他定。
import AppKit
import SwiftUI

struct CrashPromptModifier: ViewModifier {

    @State private var report: CrashReporter.Report?
    @State private var checked = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !checked else { return }
                checked = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                report = CrashReporter.shared.pendingReport()
            }
            .alert(L10n.tr("crash.prompt.title"),
                   isPresented: Binding(get: { report != nil },
                                        set: { if !$0 { report = nil } }),
                   presenting: report) { pending in
                Button(L10n.tr("crash.prompt.report")) { open(pending) }
                Button(L10n.tr("crash.prompt.dismiss"), role: .cancel) {
                    // 拒绝 = 清除标记 + 同版本不再询问(§5.10.3-③ 表末行)
                    CrashReporter.shared.clearPending(suppress: true)
                }
            } message: { _ in
                Text(L10n.tr("crash.prompt.body"))
            }
    }

    /// 打开预填好的 issue 页。链接拼不出来时静默跳过 —— 绝不弹第二个窗
    private func open(_ pending: CrashReporter.Report) {
        if let url = pending.issueURL {
            NSWorkspace.shared.open(url)
        }
        CrashReporter.shared.clearPending(suppress: false)
        report = nil
    }
}

extension View {
    /// 挂在窗口根视图上:启动 1.5s 后自检「上次是否异常退出」,是则问一次
    func crashPrompt() -> some View { modifier(CrashPromptModifier()) }
}
