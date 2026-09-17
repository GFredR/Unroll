// AI-Generated | 可修改
// Breadcrumbs —— 崩溃面包屑(设计文档 §5.10.3-① / §5.10.4,M4 实现)
// ----------------------------------------------------------------------------
// L0 崩溃采集三件套之一:内存 ring buffer ≤20 条 + **每次事件实时落盘**
// (JSON Lines,≤4KB 超出截尾保留最新)—— 崩溃会丢掉内存,不落盘就等于没记。
//
// 隐私红线(§5.10.4,写进 code review 清单):
//   【绝对不采】文件名 / 路径 / 归档内容 / 精确文件大小。
//   落地方式不是「过滤敏感词」而是**结构上不给机会**:
//     · 事件走白名单枚举,数值只能是 Int,标签只能是枚举里写死的字符串;
//     · 唯一的自由参数(format / sizeBucket)必须过 `sanitize` —— 只允许
//       [A-Za-z0-9_-:] 与 24 字符以内,于是 `/Users/…`、`MyComic.cbz`、
//       任何带斜杠/点号/空格的路径与文件名**天然进不来**;
//     · 文件大小只记区间桶(`sz_lt50MB` / `sz_50_200MB` / `sz_gt200MB`)。
//   即使用户主动提交,我们也不主动收集 —— 这条违反直觉但必须写死:
//   格式 + 页数 + 面包屑足够定位问题,不需要知道是哪个文件(§5.10.4)。
//
// 稳定性约束(§5.10.5-②):本文件**不得成为新的崩溃源** ——
//   全链路 try? 静默降级,磁盘写失败、目录建不出来、JSON 编不出来一律吞掉。
import Foundation

// MARK: - 事件白名单

/// 面包屑事件 —— **白名单**。宁可少记,不可乱记。
///
/// 设计上刻意不给调用方传自由文本的机会:数值走 Int,标签走枚举字面量,
/// 仅有的两个 String 参数(format / sizeBucket)也要过 `Breadcrumbs.sanitize`。
enum BreadcrumbEvent: Equatable, Sendable {
    case appLaunched
    case appTerminated
    /// 打开归档:格式 + 大小区间桶(不含文件名,§5.10.4)
    case openArchive(format: String, sizeBucket: String)
    /// 索引建完:总页数(诊断「大包卡在哪」的关键量)
    case indexBuilt(pages: Int)
    /// 打开失败:只记错误**码**(不记 `archive_error_string()` 原文 ——
    /// 那串英文可能含完整路径,原文只进 os_log,见 §5.9.4 约束 6)
    case openFailed(code: String)
    /// 部分加密包:加密页数量(§5.9 四态里的 partial)
    case encryptedPages(count: Int)
    case pageDecode(index: Int)
    case pageFailed(index: Int)
    /// 全分辨率降为缩略图(Trimmed,§5.3 图 6)
    case cacheDemote(page: Int)
    /// 条目彻底释放(Evicted,§5.3 图 6)
    case cacheEvict(page: Int)
    case layoutChanged(String)      // single / dual
    case directionChanged(String)   // ltr / rtl
    case fitModeChanged(String)     // fit / width / height / 1to1
    /// 续读恢复:恢复到的页码(只记页索引,不记文件名,§5.10.4)
    case progressRestored(page: Int)
    /// 书签标记/取消:记页码 + on/off(同样只有页码,无文件名)
    case bookmarkToggled(page: Int, marked: Bool)
    /// 双页配对口径:封面是否单独一页(2026-09-16)。只记开关,无页码无文件名
    case coverAloneChanged(Bool)
    /// 加密归档需要密码(v2,2026-09-17)。只说明「流程走到这一步了」——
    /// **不带任何密码信息**,连「用户输了几位」都不记
    case passphraseRequired
    /// 密码尝试结果(v2)。只记成/败布尔。
    /// 密码本身**永远不进这里**:白名单只放行 on/off 这类布尔标签,
    /// 而真实密码含大小写数字之外的字符(中文密码、符号)必然被 sanitize 丢掉 ——
    /// 但这不构成安全保证,真正的保证是**调用方压根不传**(§5.10.4 的结构性红线)
    case passphraseAttempt(success: Bool)

    var name: String {
        switch self {
        case .appLaunched:       return "appLaunched"
        case .appTerminated:     return "appTerminated"
        case .openArchive:       return "openArchive"
        case .indexBuilt:        return "indexBuilt"
        case .openFailed:        return "openFailed"
        case .encryptedPages:    return "encryptedPages"
        case .pageDecode:        return "pageDecode"
        case .pageFailed:        return "pageFailed"
        case .cacheDemote:       return "cacheDemote"
        case .cacheEvict:        return "cacheEvict"
        case .layoutChanged:     return "layoutChanged"
        case .directionChanged:  return "directionChanged"
        case .fitModeChanged:    return "fitModeChanged"
        case .progressRestored:  return "progressRestored"
        case .bookmarkToggled:   return "bookmarkToggled"
        case .coverAloneChanged: return "coverAloneChanged"
        case .passphraseRequired: return "passphraseRequired"
        case .passphraseAttempt: return "passphraseAttempt"
        }
    }

    /// 落盘的值。多字段事件用冒号拼接(`zip:sz_50_200MB`)——
    /// 冒号是 sanitize 白名单里唯一的「组合符」,不含路径特征
    var value: String? {
        switch self {
        case .appLaunched, .appTerminated:
            return nil
        case .openArchive(let format, let bucket):
            return "\(format):\(bucket)"
        case .indexBuilt(let pages):
            return String(pages)
        case .openFailed(let code):
            return code
        case .encryptedPages(let count):
            return String(count)
        case .pageDecode(let index):
            return String(index)
        case .pageFailed(let index):
            return String(index)
        case .cacheDemote(let page):
            return String(page)
        case .cacheEvict(let page):
            return String(page)
        case .layoutChanged(let layout):
            return layout
        case .directionChanged(let direction):
            return direction
        case .fitModeChanged(let mode):
            return mode
        case .progressRestored(let page):
            return String(page)
        case .bookmarkToggled(let page, let marked):
            return "\(page):\(marked ? "on" : "off")"
        case .coverAloneChanged(let on):
            return on ? "on" : "off"
        case .passphraseRequired:
            return nil
        case .passphraseAttempt(let success):
            return success ? "ok" : "fail"
        }
    }
}

// MARK: - 单条面包屑

/// 一条面包屑。字段刻意压到最短(JSON Lines 每行一条,省字节)
struct Breadcrumb: Codable, Equatable, Sendable {
    /// 相对本进程启动的毫秒数 —— 不落绝对时间戳,少一样可关联的外部信息
    let t: Int
    let e: String
    let v: String?

    /// 人类可读行(上报草稿里用):`+00:12.345  pageDecode  97`
    var line: String {
        let seconds = Double(t) / 1000
        let text = String(format: "+%02d:%06.3f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        return v.map { "\(text)  \(e)  \($0)" } ?? "\(text)  \(e)"
    }
}

// MARK: - 落盘

final class Breadcrumbs: @unchecked Sendable {

    /// App 全局实例(写 App Support;宿主测试进程内自动静默,见 UnrollRuntime)
    static let shared = Breadcrumbs(directory: UnrollSupport.directory, isSharedInstance: true)

    private let fileURL: URL
    /// ring buffer 容量(§5.10.3-①:最近 20 条)
    private let limit: Int
    /// 落盘字节上限(§5.10.3-①:4KB)
    private let maxBytes: Int
    /// 全局实例 + 测试进程 = 不落盘(否则测试宿主被强杀会留下假崩溃痕迹)
    private let isSharedInstance: Bool

    private let lock = NSLock()
    private var entries: [Breadcrumb] = []
    private let startedAt = Date()

    init(directory: URL,
         limit: Int = 20,
         maxBytes: Int = 4096,
         isSharedInstance: Bool = false) {
        self.fileURL = directory.appendingPathComponent("breadcrumbs.log")
        self.limit = limit
        self.maxBytes = maxBytes
        self.isSharedInstance = isSharedInstance
    }

    // MARK: 写

    /// 记录一条事件并**立即落盘**。
    /// 同步写盘是刻意的:4KB 量级、翻页级频率,代价可忽略;而崩溃恰恰发生在
    /// 「最后一条事件之后」——异步写会把最值钱的那条丢掉(§5.10.3-① 明确要求实时)
    func record(_ event: BreadcrumbEvent) {
        guard !(isSharedInstance && UnrollRuntime.isTesting) else { return }

        let crumb = Breadcrumb(t: Int(Date().timeIntervalSince(startedAt) * 1000),
                               e: event.name,
                               v: event.value.flatMap(Self.sanitize))

        lock.lock()
        defer { lock.unlock() }
        // 连续重复事件(反复重试同一页等)折叠掉,别把 20 条额度刷光
        if let last = entries.last, last.e == crumb.e, last.v == crumb.v { return }
        entries.append(crumb)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        persistLocked()
    }

    /// 清空(新会话开始 / 上报完成)。内存与磁盘一起清
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 读

    /// 内存快照(最旧 → 最新)
    func snapshot() -> [Breadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// 从磁盘读(上报用:读的是**已崩溃会话**留下的尾巴,不是当前内存)
    static func read(from directory: URL) -> [Breadcrumb] {
        let url = directory.appendingPathComponent("breadcrumbs.log")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Breadcrumb.self, from: data)
        }
    }

    // MARK: 隐私闸门

    /// 值白名单:**数字 / 短标签 / 两者的冒号组合**。
    /// 出现斜杠、点号、空格等路径文件名特征一律丢弃(宁缺勿错,§5.10.4)
    static func sanitize(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24 else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-:")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    /// 文件大小 → 区间桶(§5.10.4:只记桶,绝不记精确大小)
    static func sizeBucket(bytes: Int) -> String {
        switch bytes {
        case ..<0:              return "sz_unknown"
        case ..<50_000_000:     return "sz_lt50MB"
        case ..<200_000_000:    return "sz_50_200MB"
        default:                return "sz_gt200MB"
        }
    }

    // MARK: 内部

    /// 序列化为 JSON Lines 并原子写;超出字节上限则丢最旧的,直到装得下
    private func persistLocked() {
        guard let data = Self.encode(entries, maxBytes: maxBytes) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func encode(_ items: [Breadcrumb], maxBytes: Int) -> Data? {
        let encoder = JSONEncoder()
        var kept = items
        while true {
            let lines = kept.compactMap { try? encoder.encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            if data.count <= maxBytes || kept.count <= 1 { return data }
            kept.removeFirst()
        }
    }
}

// MARK: - 落盘位置与运行时环境

/// App 的私有数据目录(Sandbox 下自动落在容器内,无需额外权限)
enum UnrollSupport {

    /// `~/Library/Application Support/Unroll`
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Unroll", isDirectory: true)
    }
}

/// 运行时环境判定
enum UnrollRuntime {

    /// 是否跑在宿主测试进程里。
    ///
    /// 为什么必须判:单元测试宿主(App)会走一遍 `applicationDidFinishLaunching`
    /// 并写下 `alive = true` 的会话标记,而测试结束时宿主常被直接杀掉 ——
    /// 于是下一次真人启动就会看到一条**假**的「上次异常退出」。
    /// 同理测试也会往面包屑文件里灌垃圾。诊断模块的副作用在测试下一律关闭。
    static let isTesting = ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
