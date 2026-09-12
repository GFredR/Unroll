// AI-Generated | 可修改
// CrashReporter —— L0 崩溃采集与自愿上报(设计文档 §5.10.3-②③、图 11,M4 实现)
// ----------------------------------------------------------------------------
// 前提认知(§5.10.1):macOS **本来就在** `~/Library/Logs/DiagnosticReports/`
// 记崩溃报告,真正的问题不是「怎么捕获崩溃」而是「怎么让报告流到手上」。
// 所以这里不做 SDK、不做堆栈捕获,只做一条**用户自愿的回传路径**。
//
// L0 三件事:
//   ① 会话标记:启动写 `alive = true`,正常退出(⌘Q)写 false;
//   ② 异常退出自检:下次启动发现残留 `alive = true` 且系统没重启过 → 判定
//      「上次似乎异常退出」(文案要软,不断言"崩溃了"—— 也可能只是被强杀);
//   ③ 自愿上报:**App 自身零网络请求**,只拼一个预填好的 GitHub issue 链接
//      交 `NSWorkspace` 打开,内容用户看得见、发不发他自己定(§5.10.3-③)。
//
// 误报兜底:`kern.boottime` —— 系统重启过就不算崩溃(且此时面包屑也已过期)。
// 免打扰:用户拒绝后记 `suppressedVersion` + 清除标记,**同一版本不再询问**。
//
// 若 §7.3-B 最终选 L1(PLCrashReporter 抓真实堆栈),本文件是唯一改动点,
// UI 与 Breadcrumbs 均不动(异常类型字段已留位)。
import Darwin
import Foundation

final class CrashReporter: @unchecked Sendable {

    /// App 全局实例(草稿链接指向公开仓库的 issue 页;此处是唯一硬编码处)
    static let shared = CrashReporter(directory: UnrollSupport.directory,
                                      breadcrumbs: .shared,
                                      isSharedInstance: true)

    /// GitHub 仓库地址(发布前请与 README 中的地址核对一致)
    static let repositoryURL = "https://github.com/GFredR/Unroll"

    // MARK: - 会话标记

    /// `session.json`。字段刻意少:够判定「是否异常退出」即可
    struct SessionRecord: Codable, Equatable {
        var alive: Bool
        var version: String
        var build: String
        /// 系统启动时刻(kern.boottime,秒)—— 重启误报兜底的依据
        var bootTime: Double
        /// 用户拒绝上报的版本号(等于当前版本则不再询问)
        var suppressedVersion: String?
    }

    // MARK: - 上报内容

    /// 从面包屑里提炼的「上次会话摘要」。**全部是 §5.10.4 允许采集的字段**
    struct Summary: Equatable, Sendable {
        var format: String?
        var sizeBucket: String?
        var pages: Int?
        var lastPage: Int?
        var encryptedPages: Int?
    }

    /// 一份可提交的报告(用户可见内容 + 预填链接)
    struct Report: Equatable, Sendable {
        let appVersion: String
        let build: String
        let osVersion: String
        let arch: String
        let summary: Summary
        let breadcrumbs: [Breadcrumb]
        let title: String
        let body: String
        /// 预填好的 issue 新建链接(拼不出来时为 nil —— 静默降级,绝不二次弹窗)
        let issueURL: URL?
    }

    // MARK: - 依赖

    private let sessionURL: URL
    private let directory: URL
    private let breadcrumbs: Breadcrumbs
    private let version: String
    private let build: String
    private let isSharedInstance: Bool
    private let lock = NSLock()
    /// beginSession 检出的待上报报告(UI 延迟 1.5s 后才来取,§5.10.5-①)
    private var pending: Report?

    init(directory: URL,
         breadcrumbs: Breadcrumbs,
         version: String = CrashReporter.bundleVersion,
         build: String = CrashReporter.bundleBuild,
         isSharedInstance: Bool = false) {
        self.directory = directory
        self.sessionURL = directory.appendingPathComponent("session.json")
        self.breadcrumbs = breadcrumbs
        self.version = version
        self.build = build
        self.isSharedInstance = isSharedInstance
    }

    // MARK: - 生命周期

    /// 会话开始。返回是否检出「上次异常退出」。
    /// 调用点:`applicationDidFinishLaunching`(诊断失败一律静默,不阻断启动)
    @discardableResult
    func beginSession() -> Bool {
        guard isEnabled else { return false }

        let previous = readRecord()
        let boot = Self.bootTime()
        var crashed = false

        if let previous,
           previous.alive,
           // 系统没重启过,才谈得上「上次异常退出」
           abs(previous.bootTime - boot) < 1,
           previous.suppressedVersion != version {
            crashed = true
            // 面包屑要在 clear 之前读 —— 读的是上次会话留下的尾巴
            setPending(makeReport(for: previous, breadcrumbs: Breadcrumbs.read(from: directory)))
        }

        writeRecord(SessionRecord(alive: true,
                                  version: version,
                                  build: build,
                                  bootTime: boot,
                                  suppressedVersion: previous?.suppressedVersion))
        breadcrumbs.clear()
        breadcrumbs.record(.appLaunched)
        return crashed
    }

    /// 正常退出(⌘Q / 关窗口)。写 false = 下次启动不会误报
    func endSession() {
        guard isEnabled else { return }
        let current = readRecord()
        writeRecord(SessionRecord(alive: false,
                                  version: version,
                                  build: build,
                                  bootTime: current?.bootTime ?? Self.bootTime(),
                                  suppressedVersion: current?.suppressedVersion))
    }

    // MARK: - 上报

    /// 取待上报报告(UI 侧延迟 1.5s 后调用,不在冷启动关键路径上,§5.10.5-①)
    func pendingReport() -> Report? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// 用户处理完毕:清除标记;`suppress = true` 时记下「同版本不再询问」
    func clearPending(suppress: Bool) {
        lock.lock()
        pending = nil
        lock.unlock()

        var record = readRecord() ?? SessionRecord(alive: true,
                                                   version: version,
                                                   build: build,
                                                   bootTime: Self.bootTime(),
                                                   suppressedVersion: nil)
        record.suppressedVersion = suppress ? version : record.suppressedVersion
        writeRecord(record)
    }

    // MARK: - 内部:报告拼装

    private func makeReport(for session: SessionRecord, breadcrumbs crumbs: [Breadcrumb]) -> Report {
        let summary = Self.summarize(crumbs)
        let env = """
        - App: 开卷 Unroll \(session.version) (build \(session.build))
        - macOS: \(Self.osVersion)
        - Arch: \(Self.arch)
        """

        var facts: [String] = []
        if let format = summary.format { facts.append("- Archive format: \(format)") }
        if let bucket = summary.sizeBucket { facts.append("- Size bucket: \(Self.humanBucket(bucket))") }
        if let pages = summary.pages { facts.append("- Pages: \(pages)") }
        if let last = summary.lastPage { facts.append("- Last page index: \(last)") }
        if let encrypted = summary.encryptedPages { facts.append("- Encrypted pages: \(encrypted)") }
        if facts.isEmpty { facts.append("- (no session events recorded)") }

        let trail = crumbs.isEmpty
            ? "(no breadcrumbs — the session left nothing behind)"
            : crumbs.map(\.line).joined(separator: "\n")

        let body = """
        ### What happened
        The app reported an **unclean exit** — the previous session never shut down normally.
        It may be a crash, or it may have been force-quit / killed; the breadcrumbs below are the best clue.

        ### Environment
        \(env)

        ### Last session
        \(facts.joined(separator: "\n"))

        ### Breadcrumbs (oldest → newest, time relative to session start)
        ```
        \(trail)
        ```

        ### What were you doing at the time?
        <!-- e.g. "flipping quickly through a ~200-page cbz", "opening a solid 7z" -->

        ### Optional: the system crash report
        macOS already wrote one — it lives in `~/Library/Logs/DiagnosticReports/`
        (a file named `Unroll_<date>.ips`). If you can find it, **drag the file into this
        issue** — an attachment is much easier to inspect than pasted text.

        ---
        *Filed through 开卷's voluntary crash prompt. The app itself sends nothing —
        this draft is only opened in your browser, and you decide whether to submit it.
        No file names, paths, archive contents or precise file sizes are collected, by design.*
        """

        return Report(appVersion: session.version,
                      build: session.build,
                      osVersion: Self.osVersion,
                      arch: Self.arch,
                      summary: summary,
                      breadcrumbs: crumbs,
                      title: "[crash] Unexpected exit — v\(session.version) (build \(session.build))",
                      body: body,
                      issueURL: Self.issueURL(title: "[crash] Unexpected exit — v\(session.version) (build \(session.build))",
                                              body: body))
    }

    /// 预填 issue 链接(标签 crash)。拼不出来返回 nil → 调用方静默跳过
    static func issueURL(title: String, body: String) -> URL? {
        guard var components = URLComponents(string: repositoryURL + "/issues/new") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "crash"),
        ]
        return components.url
    }

    /// 面包屑 → 摘要(只取最后一个同类事件,全部为允许字段)
    static func summarize(_ crumbs: [Breadcrumb]) -> Summary {
        var summary = Summary()
        for crumb in crumbs {
            switch crumb.e {
            case "openArchive":
                let parts = (crumb.v ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                summary.format = parts.first
                if parts.count > 1 { summary.sizeBucket = parts[1] }
            case "indexBuilt":
                summary.pages = crumb.v.flatMap(Int.init)
            case "pageDecode", "pageFailed":
                if let index = crumb.v.flatMap(Int.init) { summary.lastPage = index }
            case "encryptedPages":
                summary.encryptedPages = crumb.v.flatMap(Int.init)
            default:
                break
            }
        }
        return summary
    }

    // MARK: - 内部:磁盘

    private var isEnabled: Bool { !(isSharedInstance && UnrollRuntime.isTesting) }

    private func readRecord() -> SessionRecord? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    private func writeRecord(_ record: SessionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: sessionURL, options: .atomic)
    }

    private func setPending(_ report: Report?) {
        lock.lock()
        defer { lock.unlock() }
        pending = report
    }

    // MARK: - 内部:环境量(§5.10.4 允许采集)

    /// 系统启动时刻(kern.boottime)。取不到返回 0 —— 此时 `abs(0 - boot) < 1`
    /// 不成立,即「宁可漏报也不误报」
    static func bootTime() -> Double {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return 0 }
        return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// 桶标记 → 人话(只有草稿正文用,不进面包屑)
    private static func humanBucket(_ token: String) -> String {
        switch token {
        case "sz_lt50MB":   return "< 50 MB"
        case "sz_50_200MB": return "50–200 MB"
        case "sz_gt200MB":  return "> 200 MB"
        default:            return "unknown"
        }
    }
}
