// AI-Generated | 可修改
// ArchiveDocument —— 打开归档的门面(设计文档 §4.1 / §4.3 图 3 / §5.9 图 10)
// ----------------------------------------------------------------------------
// 生命周期:open(url:passphrase:) 列目录建索引(含四态检测)→ data(at:) 按页取原始字节
//          → (上层 PageStore 交 ImageIO 解码)。
//
// v2 密码(2026-09-17):open 接受可选 passphrase,在 archive_read_open **之前**
// 注入(库的要求,见 shim.h)。自此加密归档可解 —— 但**只有 ZIP 真能解**:
// ZipCrypto 与 AES-256 实测都能读出正确字节;7z 加密是库的能力死限,
// 给了正确密码仍报 "currently not supported"(2026-09-17 实测确认)。
//
// 两个来自实测的设计后果(改这段代码前务必先读):
//   ① `archive_entry_is_encrypted` 在**给了正确密码之后仍然返回 1** ——
//      它描述的是「条目在归档里是加密存储的」,不是「现在读不出来」。
//      所以前置拦截的判据是 `entryEncrypted[i] && passphrase == nil`,
//      漏掉后半句会让密码解开的包每页都被误拦(2026-09-17 探针实测)。
//   ② 密码必须在 open 时就验证一次:否则用户输错密码会「成功」进入阅读器,
//      然后看到满屏加密占位卡片 —— 那比直接说「密码不对」糟得多。
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

    /// 加密四态扫描结果。终局态(全部/头部加密且**无密码可用**)已在 open 抛错,
    /// 这里只会是 .none 或 .partial。
    ///
    /// 密码语义(2026-09-17):带对密码打开时,原本加密的页已可读,故返回 .none ——
    /// 「这本包是加密的」这件事改由 `encryptedEntryCount` 表达(两者正交:
    /// 一个说「现在读得出来吗」,一个说「归档里有多少条是加密存储的」)
    public let protection: ArchiveProtection

    /// **图片条目**中加密存储的条数(open 扫描所得,与是否解锁无关)。
    /// 只算图片:一个加密的 note.txt 不影响阅读体验(与 protection 的口径一致)。
    /// 用途:UI 判断要不要给「输入解压密码」入口、解锁后提示「已解开 N 页」
    public let encryptedImageCount: Int

    /// libarchive 识别的归档格式(错误文案分流依据,§5.9.3 图 10 FMT 分支)
    public let format: ArchiveFormat

    /// 归档源文件;data(at:) 每次重新打开它(文件被移走/删除 → 抛 .corrupted)。
    /// internal(非 private):SequentialPageReader 复用同一打开逻辑(§5.1 顺序扫描器)
    let url: URL

    /// 打开时提供的解压密码(nil = 未提供 / 归档未加密)。
    ///
    /// **安全约束(改动前必读)**:只活在内存里 —— 不落盘、不进面包屑、不进崩溃
    /// 报告、不进 UserDefaults。它必须每次重开实例时原样带上(data(at:) 与
    /// SequentialPageReader 都要),否则会出现「第一页解开了、第二页又报需要密码」
    /// 这种看不懂的故障。刻意**不做「记住密码」**:那需要写 Keychain,
    /// 是一个关于「替用户保管秘密」的独立决策,不顺手做掉。
    let passphrase: String?

    /// entries[i] 对应的原始条目序号(next_header 遍历顺序)。
    /// internal:SequentialPageReader 靠它做前向推进定位
    let rawPositions: [Int]

    /// entries[i] 是否加密存储(open 扫描时记录,读页时免二次探测)。
    /// internal:SequentialPageReader 前置拦截加密页,不消耗流位置。
    /// ⚠️ 给了正确密码后仍为 true(见文件头实测①),故拦截必须同时看 passphrase
    let entryEncrypted: [Bool]

    private init(url: URL, entries: [ArchiveEntry], protection: ArchiveProtection,
                 encryptedImageCount: Int, format: ArchiveFormat, passphrase: String?,
                 rawPositions: [Int], entryEncrypted: [Bool]) {
        self.url = url
        self.entries = entries
        self.protection = protection
        self.encryptedImageCount = encryptedImageCount
        self.format = format
        self.passphrase = passphrase
        self.rawPositions = rawPositions
        self.entryEncrypted = entryEncrypted
    }

    // MARK: - 打开 + 列目录 + 四态检测(图 10 主流程)

    /// 打开归档:列目录 → 过滤图片 → 自然排序 → 加密四态判定。
    ///
    /// passphrase(v2,2026-09-17):解压密码。nil = 未提供 —— 全加密的 zip 会抛
    /// `.encrypted`,UI 据此弹密码框、带密码重开。对明文归档传密码无害
    /// (库直接忽略,有单测锁死,防「加了密码反而打不开」)。
    ///
    /// 抛错与四态的对应(全部映射 §5.9.3.1 的错误态页面文案):
    ///   .corrupted               损坏 / 非归档 / 中途 FATAL / 文件消失
    ///   .empty                   0 条目
    ///   .noImages(found:)        有条目但无图片
    ///   .headerEncrypted         列目录即 FATAL 且双信号命中(头部加密)
    ///   .encrypted               全部图片加密 + zip + **未给密码** → UI 弹密码框
    ///   .wrongPassphrase         给了密码但不对 → UI 提示重输(非终局)
    ///   .encryptedUnsupportedFormat  加密且库解不了(7z 实测死限;RAR 未实测)
    ///   CancellationError        调用方通过 isCancelled 叫停(换文件 / 关窗)
    ///
    /// isCancelled(2026-09-17):列目录是**同步阻塞**的 I/O 循环 —— 一个几万条目
    /// 的大包(或在网络卷上)能跑好几秒。调用方把它丢到后台线程后,还需要一条
    /// 「用户已经换文件了,别接着啃」的通道,否则前一个包会一路跑完,
    /// 白占 CPU 与磁盘。回调每 `C.cancellationCheckEvery` 个条目问一次,
    /// 开销可忽略;命中即抛 `CancellationError`(VM 已有专门分支,不写成失败态)。
    public static func open(url: URL, passphrase: String? = nil,
                           isCancelled: (@Sendable () -> Bool)? = nil) throws -> ArchiveDocument {
        let a = try openRawHandle(url: url, passphrase: passphrase)
        defer { dispose(a) }

        // 原始条目快照:path / size / 加密标志,按 next_header 顺序
        var rawPaths: [String] = []
        var rawSizes: [Int64?] = []
        var rawEncrypted: [Bool] = []
        var format: ArchiveFormat = .other(name: "")
        /// 密码是否已验证可用。多页加密包只需验第一条 —— 同一个包里
        /// 各条目的密码是同一个,重复验证纯属浪费(大包里每条都是整个解压)
        var passwordVerified = false
        /// 「连续多少轮没有产出新条目」。见下方停滞守卫
        var stagnantTurns = 0

        while true {
            // 取消检查放在最前:一旦用户换了文件,连一次多余的 next_header 都不做
            if let isCancelled, rawPaths.count % C.cancellationCheckEvery == 0,
               isCancelled() {
                throw CancellationError()
            }

            var entry: OpaquePointer? = nil
            let r = archive_read_next_header(a, &entry)

            if r == C.EOF { break }                              // 正常遍历完毕
            if r < 0, r != C.WARN {                              // FAILED / FATAL
                throw listingFailure(code: r, handle: a, listedCount: rawPaths.count)
            }
            // r == OK 或 WARN(-20,警告但条目有效):继续处理本条
            //
            // 停滞守卫(2026-09-17):正常路径每轮要么 +1 条、要么 EOF、要么抛错 ——
            // 三者必居其一。但 `guard let entry else { continue }` 这条防御分支
            // 在「库持续返回 OK/WARN 却给不出条目」时会**原地空转**,而原来的
            // `while true` 没有任何上限:那是本节唯一可能挂死的地方(§5.9.2 挂起坑
            // 在**列目录**这一侧的对应物,§5.9.4 约束 5 只盖住了读数据那侧)。
            // 判据用「连续无产出轮数」而不是「总轮数」,这样几万页的合法大包
            // 永远不会被误伤 —— 它每一轮都在产出
            guard let entry else {
                stagnantTurns += 1
                if stagnantTurns > C.maxStagnantHeaders {
                    throw ArchiveError.unknown(
                        code: 0,
                        message: "listing made no progress for \(stagnantTurns) headers")
                }
                continue
            }
            stagnantTurns = 0

            if rawPaths.isEmpty, let name = archive_format_name(a) {
                format = ArchiveFormat(name: String(cString: name))
            }
            rawPaths.append(String(cString: archive_entry_pathname(entry)))
            let size = archive_entry_size(entry)
            rawSizes.append(size >= 0 ? size : nil)
            let isEncrypted = archive_entry_is_encrypted(entry) == 1
            rawEncrypted.append(isEncrypted)

            // 密码就地预验证:刚好证明密码对不对的时刻,流正停在第一条加密
            // 条目上,这里试读零额外开销(读剩的数据由下一次 next_header
            // 自动跳过 —— libarchive 语义)。不这么做的话,输错密码会「成功」
            // 进入阅读器再满屏占位卡片,比直接说「密码不对」糟得多。
            if isEncrypted, passphrase != nil, !passwordVerified {
                try verifyPassphrase(a)
                passwordVerified = true
            }
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
        // (带对了密码则不抛:那些页现在读得出来,密码验证已在上面就地完成)
        if encryptedImageCount == entries.count, !passwordVerified {
            throw encryptionError(for: format)
        }
        // 密码验证通过 → 加密页已可读,protection 归 .none。
        // 「这本包是加密的」这件事改由 encryptedImageCount 单独表达 —— 两者正交:
        // protection 回答「现在读得出来吗」,encryptedImageCount 回答「原本有多少页加密」
        let protection: ArchiveProtection = (encryptedImageCount == 0 || passwordVerified)
            ? .none
            : .partial(encryptedCount: encryptedImageCount)

        return ArchiveDocument(url: url, entries: entries, protection: protection,
                               encryptedImageCount: encryptedImageCount,
                               format: format, passphrase: passphrase,
                               rawPositions: rawPositions, entryEncrypted: entryEncrypted)
    }

    // MARK: - 按页读取(图 4 RAW 段)

    /// 取第 index 页的原始字节。每次调用自建 libarchive 实例:
    /// 无共享可变状态 → 多 Task 并发调用安全(§4.4 规则 1);
    /// 代价是 O(index) 次 header 跳走,zip 可接受,solid 7z 本就 O(n)(§5.1)。
    ///
    /// 加密页抛错(不冒泡成整档失败,§5.9.4 约束 4):
    ///   · **未提供密码** → zip:`.encrypted`;7z/rar:`.encryptedUnsupportedFormat`
    ///     (提前拦截省一次读,也给得准话:这些页不是坏了,是要密码)
    ///   · **提供了密码** → 不拦截,真读。读不动才是真的读不动
    ///     ⚠️ 必须带 `passphrase == nil` 这半句:给对密码后
    ///     `archive_entry_is_encrypted` 仍返回 1(2026-09-17 探针实测),
    ///     只看标志位会把已解开的页全误拦成「需要密码」
    public func data(at index: Int) throws -> Data {
        guard entries.indices.contains(index) else {
            // 调用方 bug 兜底:绝不 trap(§5.9.4「绝不闪退」)
            throw ArchiveError.unknown(code: 0, message: "page index \(index) out of range 0..\(entries.count)")
        }
        if entryEncrypted[index], passphrase == nil {
            throw Self.encryptionError(for: format)
        }

        let a = try Self.openRawHandle(url: url, passphrase: passphrase)
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
                // 负值有两个来源:
                //   · **真实读损坏** —— 常态,翻译成 .corrupted
                //   · **密码没带上** —— 前置拦截(`entryEncrypted && passphrase == nil`)
                //     本该拦住,但 `SequentialPageReader` 重建句柄时若漏传密码就会漏网。
                //     2026-09-17 用注入验证过那种情形:错误串是 "Passphrase required"。
                //     若这里一律报 .corrupted,用户看到的是「文件损坏」——
                //     一个查不出原因的误导性结论。所以分流一次,让症状指向真实原因
                throw Self.passphraseFailure(code: r, handle: a)
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

    /// 试读当前条目,验证密码是否可用(仅 open 阶段调用:流正好停在第一条加密条目)。
    ///
    /// 判据是**真读**,不是任何标志位 —— `archive_entry_is_encrypted` 在给对
    /// 密码后仍然返回 1(实测),问不出有用信息;而 libarchive 的密码错是在
    /// read 时报 -25 + "Incorrect passphrase"(ZipCrypto 与 AES 皆然,实测)。
    ///
    /// **为什么尽量读完整个条目**:ZipCrypto 的校验字节在条目**末尾**
    /// (PKWARE 传统加密把 CRC 高位藏在最后一字节),只读开头有 1/256 的概率
    /// 放过错误密码 —— 那会让用户「成功」进入阅读器,然后翻一页失败一页。
    /// 超大条目不为这个付全额代价:读到 `passphraseProbeBytes` 即算通过,
    /// 真读时若有问题由 `readCurrentEntryData` 照常报错兜底。
    private static func verifyPassphrase(_ a: OpaquePointer) throws {
        var total = 0
        while total < C.passphraseProbeBytes {
            var buff: UnsafeRawPointer? = nil
            var len = 0
            var offset: Int64 = 0
            let r = archive_read_data_block(a, &buff, &len, &offset)
            if r == C.EOF { return }                  // 读完 → 密码确定无误
            if r < 0, r != C.WARN {
                throw passphraseFailure(code: r, handle: a)
            }
            total += len
        }
    }

    /// 读取失败的错误翻译,按 libarchive 的错误串分流。
    /// **错误串只做内部分流,绝不进 UI**(§5.9.4 约束 6:那串英文可能含完整路径)。
    ///
    /// 分流表(错误串取自 2026-09-17 实测;库若换了措辞会全部落到 .corrupted,
    /// 即「最坏降级为损坏」,不会把损坏误报成密码问题):
    ///   "Incorrect passphrase" / "Passphrase required" → .wrongPassphrase
    ///   "not supported"                                 → .encryptedUnsupportedFormat
    ///   (其余)                                          → .corrupted
    ///
    /// 两个调用点,职责不同:
    ///   · `verifyPassphrase` —— open 阶段确认密码对不对;
    ///   · `readCurrentEntryData` —— 兜住「密码没带上」这类漏网(见那里的注释)
    private static func passphraseFailure(code: Int32, handle: OpaquePointer) -> ArchiveError {
        if let raw = archive_error_string(handle) {
            let message = String(cString: raw)
            if message.contains("Incorrect passphrase") || message.contains("Passphrase required") {
                return .wrongPassphrase
            }
            if message.contains("not supported") {
                return .encryptedUnsupportedFormat
            }
        }
        return .corrupted
    }

    /// 新建读取句柄:filter/format 全开 + 按 §3.2 显式注册 rar/7zip
    /// + (v2)在 open 之前注入解压密码。
    /// 打不开(文件不存在/无权限)→ .corrupted,文案对应「无法打开这个文件」。
    /// internal:SequentialPageReader 重开实例(后向跳页)复用同一逻辑
    static func openRawHandle(url: URL, passphrase: String? = nil) throws -> OpaquePointer {
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
        // 密码必须在 open_filename **之前**注入(shim.h:libarchive 在 open 时
        // 初始化各格式的解密上下文,之后再设就来不及了)。
        // 返回值刻意不参与 failed 判定:若库拒绝这个密码,后续读到加密条目时
        // 会报 "Passphrase required" → 翻译成 .wrongPassphrase,用户看到的是
        // 「密码不对」而不是莫名其妙的「文件损坏」—— 让真实错误暴露在它该出现的地方
        if let passphrase, !failed {
            _ = passphrase.withCString { archive_read_add_passphrase(a, $0) }
        }
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

    /// 加密页无法读取时的错误分流 —— 决定 UI 给不给密码入口。
    ///
    /// 判据是**证据强度**,不是格式名好不好听(2026-09-17 实测校准):
    /// - `.zip`:**实测可解** —— ZipCrypto 与 AES-256 都能用
    ///   `archive_read_add_passphrase` 解开,解出的字节与源图逐字节一致。
    /// - `.rar`:**未实测,但给入口** —— 本机既无 RAR 压缩工具也无加密样本,
    ///   但官方 README 写 "RAR and RAR 5.0",WASM 移植(libarchivejs)提供
    ///   `usePassword()` 且标注支持 RAR v4/v5,**证据倾向可解**。
    ///   给了才有机会;不给就是替用户提前放弃。真遇到解不了的,
    ///   库会报 "not supported" → 经 `passphraseFailure` 落到
    ///   `.encryptedUnsupportedFormat` → UI 说「这个归档解不开」(而不是让人
    ///   对着密码框一直试)。**这是「先给机会、再如实说不行」,不是乐观假设。**
    /// - `.sevenZip`:**实测死限,不给入口** —— 报错原文 `currently not supported`,
    ///   **给对正确密码也一样**(2026-09-17 用 py7zr 样本复测确认)。
    ///   已确认无解还让用户输密码是欺骗,不是功能。
    /// - `.tar` / `.other`:tar 无加密语义,此分支实际不可达。
    ///
    /// 拿到加密 RAR 样本后必须复测并据实改写(设计文档 §5.8、测试文档 §6)。
    /// internal:SequentialPageReader 加密页前置拦截复用同一分流(§5.9.3 图 10 FMT 分支)
    static func encryptionError(for format: ArchiveFormat) -> ArchiveError {
        switch format {
        case .zip, .rar: return .encrypted      // 给密码入口:zip 实测可解,rar 证据倾向可解
        case .sevenZip: return .encryptedUnsupportedFormat
        case .tar, .other: return .encryptedUnsupportedFormat
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

    /// 密码验证的试读上限(8MB,2026-09-17)。
    /// 普通漫画页远小于它,所以实际等价于「读完整个条目」——
    /// ZipCrypto 的校验字节藏在条目末尾,读完整条才能确定密码对错
    /// (细节见 `verifyPassphrase`)。留这个上限只拦住「加密包里塞了个
    /// 200MB 的 PDF」这类极端情形:那时读满 8MB 就放行,真读时再报错兜底
    static let passphraseProbeBytes: Int = 8 * 1024 * 1024

    /// 受支持的图片扩展名(小写;isListedImage 已做 lowercased)
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
        "heic", "heif", "avif", "tiff", "tif",
    ]

    /// 列目录时每多少个条目问一次 `isCancelled`(2026-09-17)。
    /// 256 是「调用方等待粒度」与「调用开销」的折中:一个条目对应一次
    /// next_header(微秒级),256 条一次回调等于零可感延迟,而用户换文件后
    /// 最多再啃 256 个条目就停 —— 体验上就是立刻停
    static let cancellationCheckEvery: Int = 256

    /// 列目录「连续无产出」轮数上限(2026-09-17,防挂起)。
    /// 正常路径每轮必产出一条;连续 1000 轮拿不到条目只可能是库在空转,
    /// 此时宁可报「无法打开这个文件」也不能把主程序吊死在那里
    static let maxStagnantHeaders: Int = 1_000
}
