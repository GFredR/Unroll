// AI-Generated | 可修改
// PasswordPromptView —— 解压密码输入(v2,2026-09-17)
// ----------------------------------------------------------------------------
// 同一组件、两种容器(见 ReaderView):
//   · 全屏(phase == .needsPassword):整个包都加密,打开阶段就停在这里;
//   · sheet(阅读中「输入解压密码…」):只解开部分加密包里的加密页 ——
//     阅读上下文(读到第几页、单/双页、缩放档位)一概不动。
//
// 四条约束(改之前先读,每条都对应一个具体的糟糕后果):
//   ① **密码只住在 @State**。VM 只把它当参数透传给 ArchiveKit,不缓存副本;
//      提交后立刻清空输入框。归档若要读后续页,密码由 ArchiveDocument 自己带着
//      (它确实必须持有到读完)——本视图与 VM 都不是密码的长期居所。
//      绝不落盘、不进面包屑、不进崩溃报告(与 §5.10.4 同一条结构性红线)。
//   ② 输错**不关闭面板**:让用户就地重打。清空输入框是跟随系统解锁对话框的
//      惯例(错密码留着没用,还要先全选删掉),但把面板关掉就变成惩罚了。
//   ③ 默认遮点 + 显隐切换:漫画密码常是十几位随机串,看不见没法核对 ——
//      对着键盘一位一位数是最容易让人放弃的体验。
//   ④ 提交前**不 trim**:密码首尾的空格可能是有意义的字符。替用户"顺手修正"
//      输入是密码框最经典的 bug(改了之后用户永远也输不对)。
import SwiftUI

struct PasswordPromptView: View {

    /// 使用场合 —— 只影响标题与说明文案,不影响任何行为
    enum Context {
        /// 打开时就撞上加密包
        case opening
        /// 阅读中解锁部分加密包的加密页
        case unlocking
    }

    let context: Context
    /// 上一次尝试失败时的提示(nil = 首次输入,不显示红字)
    let failure: ReaderViewModel.Failure?
    /// 提交(空串不会触发:按钮禁用,VM 再兜一层)
    let onSubmit: (String) -> Void
    /// 取消
    let onCancel: () -> Void

    @State private var password = ""
    @State private var isRevealed = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            heading
            HStack(spacing: DesignSystem.Spacing.sm) {
                field
                revealToggle
            }
            if let failure {
                wrongHint(failure)
            }
            actions
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 340)
        .onAppear { isFieldFocused = true }
    }

    // MARK: - 分块

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(L10n.tr(titleKey))
                .font(.system(size: DesignSystem.Typography.title, weight: .semibold))
            Text(L10n.tr(bodyKey))
                .font(.system(size: DesignSystem.Typography.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 遮点输入框 ↔ 明文输入框。两者由**同一个 `password` 绑定**驱动,
    /// 切换不丢已输入的内容(`focused` 要重新给,因为视图被重建了)
    @ViewBuilder
    private var field: some View {
        Group {
            if isRevealed {
                TextField(L10n.tr("archive.password.placeholder"), text: $password)
            } else {
                SecureField(L10n.tr("archive.password.placeholder"), text: $password)
            }
        }
        .textFieldStyle(.roundedBorder)
        .focused($isFieldFocused)
        .onSubmit(submit)
    }

    private var revealToggle: some View {
        Button {
            isRevealed.toggle()
            isFieldFocused = true
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .help(L10n.tr(revealKey))
        .accessibilityLabel(L10n.tr(revealKey))
    }

    private func wrongHint(_ failure: ReaderViewModel.Failure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(failure.titleKey))
                    .font(.system(size: DesignSystem.Typography.footnote, weight: .medium))
                if let key = failure.bodyKey {
                    Text(L10n.tr(key))
                        .font(.system(size: DesignSystem.Typography.footnote))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(DesignSystem.Palette.brand)
    }

    private var actions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            Button(L10n.tr("archive.password.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)          // Esc
            Button(L10n.tr("archive.password.submit"), action: submit)
                .keyboardShortcut(.defaultAction)         // Return
                .disabled(password.isEmpty)
        }
    }

    // MARK: - 文案与提交

    private var titleKey: String {
        context == .opening ? "archive.password.title" : "archive.password.unlock.title"
    }

    private var bodyKey: String {
        context == .opening ? "archive.password.body" : "archive.password.unlock.body"
    }

    private var revealKey: String {
        isRevealed ? "archive.password.hide" : "archive.password.reveal"
    }

    /// 提交后清空输入框(系统解锁对话框的惯例)。面板留着 —— 见文件头约束②
    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password)
        password = ""
        isFieldFocused = true
    }
}
