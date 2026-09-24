// AI-Generated | 可修改
// SequentialPageReader —— 单实例顺序扫描器(设计文档 §5.1 硬约束 / M2 核心)
// ----------------------------------------------------------------------------
// 为什么存在:ArchiveDocument.data(at:) 每页自建 libarchive 实例(「每页一实例」),
// 对 solid 7z 是 O(n²) —— 实测 150 页累计 2423ms vs 顺序扫描 34ms(71×),
// 数据见 工程笔记(未随仓库发布) §4,工具 Scripts/bench_archive.c。
//
// 本类持有**单个** struct archive 顺序前进:
//   · 前向访问(连续翻页/预读):从当前位置继续 next_header,摊销 O(1)/页;
//   · 后向访问:流不能回头 → 关实例重开、从头走到目标(唯一重复解压代价,
//     与「大跨度跳页才重建实例」的设计一致 —— 后向跳页天然属于重建分支);
//   · 加密页前置拦截(与 data(at:) 同款分流),不消耗流位置 —— 失败后仍可
//     继续读其他页(§5.9.4 约束 4「单页失败 ≠ 整档失败」)。
//     v2(2026-09-17):拦截判据是「加密 **且** 没带密码」。带对了密码的包
//     不拦(加密标志在解锁后仍为 true,见 ArchiveDocument 文件头实测①),
//     否则用户输对密码后每页都被误拦 —— 那是最容易被误当「密码没用」的故障。
//
// 线程约束(写死):struct archive 非线程安全,本类**必须被单一 actor/Task 独占**。
// M2 由 App 层 PageStore actor 持有 —— 非 Sendable 设计是故意的:
// 跨隔离域传递它会直接编译报错,把运行期数据竞争变成编译期错误(§4.4 规则 1)。
//
// 错误模型与 ArchiveDocument.data(at:) 完全一致(.corrupted/.encrypted/…)。
import CArchiveShim
import Foundation

public final class SequentialPageReader {

    /// 元数据来源(open 时已建好索引,这里只做流式读取)
    private let document: ArchiveDocument

    /// 当前打开的 libarchive 实例;nil = 尚未打开/已被 close
    private var handle: OpaquePointer?

    /// 已消费到的原始条目序号(-1 = 实例刚打开,一个 header 都没走)。
    /// 语义:next_header 每成功走一个 +1;读到 consumedRaw == n 时,
    /// 第 n 条的 header 已就位(数据由 readCurrentEntryData 消费)
    private var consumedRaw = -1

    /// 惰性创建句柄:构造不碰磁盘,首次 data(at:) 才打开。
    /// (PageStore 可能在归档打开后很久才发第一个读请求)
    public init(document: ArchiveDocument) {
        self.document = document
    }

    deinit {
        // C 句柄释放不依赖 actor:最后一个引用消失时就地清理。
        // 若被 actor 独占(设计如此),等价于在 actor 内释放
        if let h = handle {
            ArchiveDocument.dispose(h)
            handle = nil
        }
    }

    // MARK: - 读页(语义与 ArchiveDocument.data(at:) 对齐)

    /// 取第 index 页原始字节。访问模式决定成本:
    ///   · 前向(含 +1 翻页):摊销 O(1) —— M2 预读 +1/+2 就是靠这个;
    ///   · 后向:重开 + 从头走 O(target);
    ///   · 加密页:O(1) 直接抛错,不动流。
    public func data(at index: Int) throws -> Data {
        guard document.entries.indices.contains(index) else {
            // 调用方 bug 兜底:绝不 trap(§5.9.4「绝不闪退」)
            throw ArchiveError.unknown(code: 0,
                message: "page index \(index) out of range 0..\(document.entries.count)")
        }
        // 加密页前置拦截:不消耗流位置,失败后其他页照常可读。
        // 带密码时不拦 —— 那些页现在读得出来,该由真读决定成败
        if document.entryEncrypted[index], document.passphrase == nil {
            throw ArchiveDocument.encryptionError(for: document.format)
        }

        let target = document.rawPositions[index]

        // 流只能前进:目标在已消费位置之前(或句柄未开)→ 重开重建
        if handle == nil || target <= consumedRaw {
            try reopen()
        }

        // 前向推进到目标条目。next_header 自动跳过上一条未读数据(libarchive 语义),
        // 所以翻页读完整页后再走下一个 header 不会残留半个条目
        while consumedRaw < target {
            guard let handle else {
                // reopen 刚成功,理论不可达;防御式兜底,绝不闪退
                throw ArchiveError.unknown(code: 0, message: "sequential reader handle lost")
            }
            var entry: OpaquePointer? = nil
            let r = archive_read_next_header(handle, &entry)
            if r == C.EOF {
                // open 之后文件被替换/截断:物理条目数比索引快照少
                throw ArchiveError.corrupted
            }
            if r < 0, r != C.WARN {
                // FAILED / FATAL:与 data(at:) 同款翻译(不区分错误细节,统一损坏)
                throw ArchiveError.corrupted
            }
            // r == OK 或 WARN(-20,警告但条目有效):推进
            consumedRaw += 1
        }

        guard let handle else {
            throw ArchiveError.unknown(code: 0, message: "sequential reader handle lost")
        }
        return try document.readCurrentEntryData(handle)
    }

    // MARK: - 生命周期

    /// 主动关闭(换归档 / PageStore.teardown 时调用)。
    /// 之后再用会自动重开实例,行为正确但代价重置 —— 调用方应直接丢弃本对象
    public func close() {
        if let h = handle {
            ArchiveDocument.dispose(h)
            handle = nil
        }
        consumedRaw = -1
    }

    /// 重开实例:close 旧的 → openRawHandle(与 open/data(at:) 共用同一套
    /// filter/format 注册逻辑,含 §3.2 的 rar/7zip 显式注册与 WARN 容忍)。
    /// **密码必须一起带上**。漏传的症状(2026-09-17 注入验证):第一页正常、
    /// 之后每页失败 —— reopen 出来的句柄没有密码,读到加密数据返回 -25。
    /// 分流层已能把这种情形翻译成密码类错误(见 `readCurrentEntryData`),
    /// 但**同一本书前后页行为不一致**这一点依旧:前向顺着同一个句柄走没事,
    /// 只有后向跳页(触发重建)才坏。「翻回去就坏」这类故障查起来很费时间,
    /// 所以这句提醒不能删
    private func reopen() throws {
        if let h = handle {
            ArchiveDocument.dispose(h)
            handle = nil
        }
        handle = try ArchiveDocument.openRawHandle(url: document.url,
                                                   passphrase: document.passphrase)
        consumedRaw = -1
    }
}
