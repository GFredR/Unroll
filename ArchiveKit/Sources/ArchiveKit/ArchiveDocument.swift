// AI-Generated | 可修改
// ArchiveDocument —— 打开归档的门面(设计文档 §4.1 / §4.3 图 3 / §5.9 图 10)
// ----------------------------------------------------------------------------
// 生命周期:open(url) 列目录建索引(含四态检测)→ data(at:) 按页取原始字节
//          → (上层 PageStore 交 ImageIO 解码)。
//
// 与 M0 占位签名的两处有意偏离(均为 §4.4「每 Task 独立实例」的直接推论):
//   · open 是静态工厂:对象要么完整可用、要么构造失败,不存在半初始化态
//   · 没有 close():data(at:) 每次自建 libarchive 实例、用完即释,
//     对象本身不持有任何 C 句柄(全 let 不可变 → Sendable 免锁线程安全,
//     并发读天然安全,§4.4 规则 1)
//
// M1 关键实现点(全部来自实测结论 §3.2 / §5.9):
//   · C 返回码全部翻译成 ArchiveError,禁止 try!/强制解包(§5.9.4 约束 1)
//   · archive_error_string() 判空后再用(§5.9.4 约束 2)
//   · 头部加密用「错误码 -30 + 文案含 header is encrypted」双信号判定,
//     文案仅辅助信号(§5.9.3 表:库升级换措辞最多降级为「损坏」,不误报)
//   · 读页循环有迭代上限(§5.9.4 约束 5,防 §5.9.2 挂起坑复现)
//   · 四态终局态(全部/头部加密)在 open 即抛错,partial 才返回文档
//     ——「单页失败 ≠ 整个归档失败」(§5.9.4 约束 4)
import CArchiveShim
import Foundation    // Data / URL

public final class ArchiveDocument: Sendable {

    /// 图片条目(已过滤非图片/隐藏文件/__MACOSX,自然排序)。
    /// index 即在本数组中的位置,data(at:) 以它定位。
    public let entries: [ArchiveEntry]

    /// 加密四态扫描结果。终局态(全部/头部加密)已在 open 抛错,
    /// 这里只会是 .none 或 .partial —— 加密页留给 data(at:) 逐页报错。
    public let protection: ArchiveProtection

    /// libarchive 识别的归档格式(错误文案分流依据,§5.9.3 图 10 FMT 分支)
    public let format: ArchiveFormat

    /// 归档源文件;data(at:) 每次重新打开它(文件被移走/删除 → 抛 .corrupted)。
    /// internal(非 private):SequentialPageReader 复用同一打开逻辑(§5.1 顺序扫描器)
    let url: URL

    /// entries[i] 对应的原始条目序号(next_header 遍历顺序)。
    /// internal:SequentialPageReader 靠它做前向推进定位
    let rawPositions: [Int]

    /// entries[i] 是否加密(open 扫描时记录,读页时免二次探测)。
    /// internal:SequentialPageReader 前置拦截加密页,不消耗流位置
    let entryEncrypted: [Bool]

    private init(url: URL, entries: [ArchiveEntry], protection: ArchiveProtection,
                 format: ArchiveFormat, rawPositions: [Int], entryEncrypted: [Bool]) {
        self.url = url
        self.entries = entries
        self.protection = protection
        self.format = format
        self.rawPositions = rawPositions
        self.entryEncrypted = entryEncrypted
    }

    // MARK: - 打开 + 列目录 + 四态检测(图 10 主流程)

    /// 打开归档:列目录 → 过滤图片 → 自然排序 → 加密四态判定。
    ///
    /// 抛错与四态的对应(全部映射 §5.9.3.1 的错误态页面文案):
    ///   .corrupted               损坏 / 非归档 / 中途 FATAL / 文件消失
    ///   .empty                   0 条目
    ///   .noImages(found:)        有条目但无图片
    ///   .headerEncrypted         列目录即 FATAL 且双信号命中(头部加密)
    ///   .encrypted               全部图片加密 + zip(v1 无密码框,§7.3-A)
    ///   .encryptedUnsupportedFormat  全部图片加密 + 7z/rar(库不支持,§5.9.1)
    public static func open(url: URL) throws -> ArchiveDocument {
        let a = try openRawHandle(url: url)
        defer { dispose(a) }

        // 原始条目快照:path / size / 加密标志,按 next_header 顺序
        var rawPaths: [String] = []
        var rawSizes: [Int64?] = []
        var rawEncrypted: [Bool] = []
        var format: ArchiveFormat = .other(name: "")

        while true {
            var entry: OpaquePointer? = nil
            let r = archive_read_next_header(a, &entry)

            if r == C.EOF { break }                              // 正常遍历完毕
            if r < 0, r != C.WARN {                              // FAILED / FATAL
                throw listingFailure(code: r, handle: a, listedCount: rawPaths.count)
            }
            // r == OK 或 WARN(-20,警告但条目有效):继续处理本条
            guard let entry else { continue }

            if rawPaths.isEmpty, let name = archive_format_name(a) {
                format = ArchiveFormat(name: String(cString: name))
            }
            rawPaths.append(String(cString: archive_entry_pathname(entry)))
            let size = archive_entry_size(entry)
            rawSizes.append(size >= 0 ? size : nil)
            rawEncrypted.append(archive_entry_is_encrypted(entry) == 1)
        }

        // ---- 列目录后的终局判定(图 10) ----
        guard !rawPaths.isEmpty else { throw ArchiveError.empty }

        // 过滤出图片条目并记录原始序号
        var imageIdx: [Int] = []
        for (i, path) in rawPaths.enumerated() where isListedImage(path) {
            imageIdx.append(i)
        }
        guard !imageIdx.isEmpty else { throw ArchiveError.noImages(found: rawPaths.count) }

        // 自然排序:page2 < page10(§2.1 P0-8)。raw 顺序与排序结果解耦,
        // 排序只动展示顺序,data(at:) 靠 rawPositions 回到物理位置
        let sorted = imageIdx.sorted { NaturalSort.less(rawPaths[$0], rawPaths[$1]) }

        var entries: [ArchiveEntry] = []
        var rawPositions: [Int] = []
        var entryEncrypted: [Bool] = []
        var encryptedImageCount = 0
        for (newIndex, raw) in sorted.enumerated() {
            entries.append(ArchiveEntry(path: rawPaths[raw], index: newIndex,
                                        size: rawSizes[raw], isImage: true))
            rawPositions.append(raw)
            entryEncrypted.append(rawEncrypted[raw])
            if rawEncrypted[raw] { encryptedImageCount += 1 }
        }

        // 加密统计只看图片条目:非图片条目(note.txt)是否加密不影响阅读体验
        // ——「全部图片加密」即全不可读,按终局态处理
        if encryptedImageCount == entries.count {
            throw encryptionError(for: format)
        }
        let protection: ArchiveProtection = encryptedImageCount == 0
            ? .none
            : .partial(encryptedCount: encryptedImageCount)

        return ArchiveDocument(url: url, entries: entries, protection: protection,
                               format: format, rawPositions: rawPositions,
                               entryEncrypted: entryEncrypted)
    }

    // MARK: - 按页读取(图 4 RAW 段)

    /// 取第 index 页的原始字节。每次调用自建 libarchive 实例:
    /// 无共享可变状态 → 多 Task 并发调用安全(§4.4 规则 1);
    /// 代价是 O(index) 次 header 跳走,zip 可接受,solid 7z 本就 O(n)(§5.1)。
    ///
    /// 加密页抛错(不冒泡成整档失败,§5.9.4 约束 4):
    ///   zip → .encrypted;7z/rar → .encryptedUnsupportedFormat
    public func data(at index: Int) throws -> Data {
        guard entries.indices.contains(index) else {
            // 调用方 bug 兜底:绝不 trap(§5.9.4「绝不闪退」)
            throw ArchiveError.unknown(code: 0, message: "page index \(index) out of range 0..\(entries.count)")
        }
        if entryEncrypted[index] {
            throw Self.encryptionError(for: format)
        }

        let a = try Self.openRawHandle(url: url)
        defer { Self.dispose(a) }

        // 逐 header 走到目标原始位置;next_header 自动跳过前一_entry 未读数据
        var entry: OpaquePointer? = nil
        var pos = -1
        let target = rawPositions[index]
        while pos < target {
            let r = archive_read_next_header(a, &entry)
            if r == C.EOF {
                // open 后文件被替换/截断:物理条目数变了
                throw ArchiveError.corrupted
            }
            if r < 0, r != C.WARN {
                throw ArchiveError.corrupted
            }
            pos += 1
        }

        return try readCurrentEntryData(a)
    }

    /// 读当前 header 指向条目的全部数据(带迭代上限,§5.9.4 约束 5)。
    /// internal:SequentialPageReader 的前向读取复用同一实现(单一真源,防两处分叉)
    func readCurrentEntryData(_ a: OpaquePointer) throws -> Data {
        var out = Data()
        var blocks = 0
        while blocks < C.maxDataBlocks {
            var buff: UnsafeRawPointer? = nil
            var len = 0
            var offset: Int64 = 0
            let r = archive_read_data_block(a, &buff, &len, &offset)
            if r == C.EOF { return out }                        // 本条目读完
            if r < 0, r != C.WARN {
                // 加密页无密码到达这里(zip -25);格式分流已由 entryEncrypted
                // 前置拦截,走到这说明是真实读损坏 → .corrupted
                throw ArchiveError.corrupted
            }
            if let buff, len > 0 {
                out.append(contentsOf: UnsafeRawBufferPointer(start: buff, count: len))
            }
            blocks += 1
        }
        // 上限兜底:正常图片远到不了;命中即疑似 §5.9.2 式挂起,宁可报错不挂死
        throw ArchiveError.unknown(code: 0, message: "data block iteration cap (\(C.maxDataBlocks)) exceeded")
    }

    // MARK: - C 句柄与错误翻译

    /// 新建读取句柄:filter/format 全开 + 按 §3.2 显式注册 rar/7zip。
    /// 打不开(文件不存在/无权限)→ .corrupted,文案对应「无法打开这个文件」。
    /// internal:SequentialPageReader 重开实例(后向跳页)复用同一逻辑
    static func openRawHandle(url: URL) throws -> OpaquePointer {
        guard let a = archive_read_new() else {
            throw ArchiveError.unknown(code: 0, message: "archive_read_new returned NULL")
        }
        var failed = false
        // 失败也要走 archive_read_free 释放,避免半初始化句柄泄漏
        // ⚠️ 实测(macOS 15.7.4 / libarchive 3.7.4):archive_read_support_format_rar
        // 返回 ARCHIVE_WARN(-20) 而非 OK —— WARN 表示「已注册但有告警」,格式
        // 仍在 bidder 里。所以 support_* 系列只把 FAILED/FATAL(< WARN)当失败,
        // 否则所有 zip 都会被误判「打不开」(M1 实测踩坑)。
        if archive_read_support_filter_all(a) < C.WARN { failed = true }
        if archive_read_support_format_all(a) < C.WARN { failed = true }
        // §3.2:format_all 已含 rar/7zip,显式注册可拿到更早的格式报错
        if archive_read_support_format_rar(a) < C.WARN { failed = true }
        if archive_read_support_format_7zip(a) < C.WARN { failed = true }
        if !failed {
            // archive_read_open_filename 内部自行复制路径串,传值生命周期安全
            failed = url.path.withCString {
                archive_read_open_filename(a, $0, C.blockSize) < C.OK
            }
        }
        if failed {
            archive_read_free(a)
            throw ArchiveError.corrupted
        }
        return a
    }

    /// 关闭并释放(幂等;archive_read_close 对未打开句柄也安全返回)
    static func dispose(_ a: OpaquePointer) {
        archive_read_close(a)
        archive_read_free(a)
    }

    /// 列目录阶段失败的翻译:
    /// 双信号(码 -30 + 文案含 "header is encrypted")→ .headerEncrypted;
    /// 其余(含中途 FATAL 的截断包)→ .corrupted。
    /// listedCount 仅作注释语义:头部加密必然 0 条,>0 条的 FATAL 是截断。
    private static func listingFailure(code: Int32, handle: OpaquePointer,
                                       listedCount: Int) -> ArchiveError {
        if listedCount == 0, code == C.FATAL,
           let raw = archive_error_string(handle) {
            let message = String(cString: raw)
            // 文案匹配是辅助信号:库升级换措辞 → 落到 .corrupted,不误报
            if message.contains("header is encrypted") {
                return .headerEncrypted
            }
        }
        return .corrupted
    }

    /// 全部图片加密时按格式分流错误类型。
    ///
    /// ⚠️ **勿把 `.rar` 与 `.sevenZip` 等同看待 —— 两者证据强度完全不同:**
    /// - `.sevenZip`:**实测确认**库不支持。libarchive 3.7.4 报错原文本就是
    ///   `currently not supported`,有正确密码也读不出(§5.9.1,2026-09-09 实测)。
    /// - `.rar`:**未实测**,此处只是保守推断。官方 README 写 "RAR and RAR 5.0",
    ///   WASM 移植(libarchivejs)提供 `usePassword()` 且标注支持 RAR v4/v5 →
    ///   **RAR5 加密很可能实际可解**。若属实,则本分支对 RAR 是「过早放弃」。
    ///
    /// v1 不做密码框(§7.3-A),所以二者当前 UI 结果一致,**但文案依据不同**:
    /// 7z 可如实说「系统库不支持」,RAR 只能说「当前版本暂不支持」。
    /// 拿到加密 RAR 样本后必须复测并据实改写(设计文档 §5.8、§5.9.3.1 注 3)。
    /// internal:SequentialPageReader 加密页前置拦截复用同一分流(§5.9.3 图 10 FMT 分支)
    static func encryptionError(for format: ArchiveFormat) -> ArchiveError {
        switch format {
        case .zip: return .encrypted
        case .sevenZip, .rar: return .encryptedUnsupportedFormat
        case .tar, .other: return .encryptedUnsupportedFormat   // tar 无加密语义,此分支实际不可达
        }
    }

    // MARK: - 图片条目判定

    /// 可入阅读列表的条目:非目录、非隐藏文件、不在 __MACOSX/、扩展名受支持。
    /// 扩展名集对齐 M0 ArchiveEntry 注释(jpg/png/gif/webp/heic/tiff/avif 及常见变体)。
    /// internal 而非 private:过滤规则本身要进单测(§6.2「非图片过滤」),
    /// __MACOSX/ 目录场景无法用 fixture 复现(见 make_fixtures.sh 实测注记:
    /// 非法 AppleDouble 内容会让 libarchive 整档 FATAL,合法内容则被其自行消化),
    /// 因此该分支靠直接调用单测覆盖。
    static func isListedImage(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasSuffix("/") else { return false }   // 目录条目
        let components = path.split(separator: "/")
        guard let name = components.last, !components.isEmpty else { return false }
        if name.hasPrefix(".") { return false }                          // .DS_Store 等隐藏文件
        if components.first == "__MACOSX" { return false }               // macOS 打包垃圾目录
        if components.dropLast().contains(where: { $0.hasPrefix(".") }) { return false }  // 隐藏目录内
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return C.imageExtensions.contains(ext)
    }
}

// MARK: - 归档格式

/// libarchive 识别的格式(archive_format_name 的分类)。
/// 加密文案分流的依据:zip / 7z / rar 各对应 §5.9.3.1 不同文案组。
public enum ArchiveFormat: Sendable, Equatable {
    case zip          // .cbz / .zip —— 加密时「理论可解,v1 无密码框」
    case sevenZip     // .cb7 / .7z  —— 加密时库不支持(**实测确认**,§5.9.1)
    /// .cbr / .rar
    /// ✅ **明文读取已实测通过**(2026-09-10):5 个真实 RAR5 样本(1 / 444 / 568 条目)
    ///    format 识别、protection=none 判定、data(at:) 取字节全部正确。
    /// ⚠️ 仍无样本:RAR4(老格式)、加密 RAR。
    /// ⚠️ 加密分支当前归入 encryptedUnsupportedFormat,但那是**保守推断,不是实测结论** ——
    ///    libarchive 官方 README 与 WASM 移植(libarchivejs 的 usePassword)均提示 RAR5
    ///    支持密码解密,与 sevenZip 的「实测确认不支持」证据强度**完全不同**,勿等同看待。
    ///    拿到加密样本后必须复测,见设计文档 §5.8。
    case rar
    case tar          // .cbt / .tar —— 无加密语义
    case other(name: String)

    init(name: String) {
        // 实测 archive_format_name 的形态:"ZIP" / "ZIP 2.0 (deflation)" /
        // "ZIP 2.0 (aes)" / "POSIX ustar format" —— 大小写不定,统一小写比较
        let n = name.lowercased()
        switch true {
        case n.contains("7-zip"): self = .sevenZip
        case n.contains("zip"):   self = .zip
        case n.contains("rar"):   self = .rar
        case n.contains("tar"):   self = .tar
        default:                  self = .other(name: name)
        }
    }
}

// MARK: - libarchive 常量(archive.h 定义,不透明 shim 不含头文件,此处收编)

/// libarchive 通用返回码(§5.9 shim 铁律 3:只判断这五个)。
/// internal(非 private):SequentialPageReader 跨文件复用,单一真源防两处漂移
enum C {
    static let OK: Int32 = 0
    static let EOF: Int32 = 1
    static let WARN: Int32 = -20
    static let FAILED: Int32 = -25
    static let FATAL: Int32 = -30

    /// open_filename 的读取块大小:libarchive 文档推荐 10240(10KB)
    static let blockSize: Int = 10_240

    /// 单条目 data_block 迭代上限(§5.9.4 约束 5)。
    /// 10KB/块 × 100 万块 = 10GB,远超任何单页图片,正常流程永远到不了。
    static let maxDataBlocks: Int = 1_000_000

    /// 受支持的图片扩展名(小写;isListedImage 已做 lowercased)
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
        "heic", "heif", "avif", "tiff", "tif",
    ]
}
