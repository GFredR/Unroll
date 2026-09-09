// AI-Generated | 可修改
// CrashReporter —— L0 崩溃采集与自愿上报(设计文档 §5.10 图 11,M4 实现)
// ----------------------------------------------------------------------------
// L0 方案(§7.3-B 倾向项):零依赖、零后端、零自动上传。
//   1. 会话标记:启动写标记文件,正常退出(⌘Q)清除;
//   2. 异常退出自检:下次启动发现残留标记 → 弹「是否上报」;
//   3. 自愿上报:面包屑 + 版本 + 系统 → 生成 GitHub issue 草稿文本,
//      用户可见内容、用户自己点发送 —— 内容红线同 Breadcrumbs(§5.10.4)。
// 若 §7.3-B 最终选 L1(PLCrashReporter 堆栈),本文件是唯一改动点,UI 不动。
// M0 占位:空壳。
import Foundation

enum CrashReporter {
    // TODO(M4): beginSession() / endSession() / checkPreviousCrashAndPrompt()
}
