/*
 * AI-Generated | 可修改
 * ============================================================================
 * shim.h —— libarchive 手写 C 原型声明(设计文档 §3.2 方案 B)
 * ----------------------------------------------------------------------------
 * 为什么需要它:macOS SDK 只带 libarchive 的动态库(.tbd),不带 archive.h 头文件。
 * 自写 ~19 个原型即可用,零外部文件、零许可负担(BSD-2 的头文件拷贝方案被否掉)。
 *
 * 三条铁律(M1 实现时必须遵守,均有单测锁死):
 *   1. struct archive / archive_entry 永远不透明 —— 只传指针,绝不定义/访问字段
 *   2. archive_read_data_block 返回 int(4 字节)!声明成 8 字节会读到
 *      4294967271 并死循环(实测血泪,§5.9.2;Tests 有回归用例)
 *   3. 所有返回码只判断 ARCHIVE_OK(0)/EOF(1)/WARN(-20)/FAILED(-25)/FATAL(-30),
 *      禁止 try! / 强制解包(AGENTS.md 五.1);原文错误只进日志,不给用户(§5.9.3.1)
 * ============================================================================
 */
#ifndef CARCHIVESHIM_H
#define CARCHIVESHIM_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* int64_t */

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 不透明句柄:只传指针,不碰字段 ------------------------------------- */
struct archive;
struct archive_entry;

/* ---- 生命周期 ------------------------------------------------------------
 * 返回值均为 int 状态码:0=OK, 负值=WARN/FAILED/FATAL
 */
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
/* rar/7zip 单独再声明一次:format_all 已含,但显式注册可拿到更早的格式报错,
 * 便于 ArchiveProtection 区分「格式不支持」与「加密不支持」(§5.9 图 10) */
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

/* ---- 遍历与按页读取 ------------------------------------------------------ */
int archive_read_next_header(struct archive *, struct archive_entry **);

/* 返回 la_ssize_t(= ssize_t = long,LP64 下 8 字节):读到 0 表示本条目结束 */
long archive_read_data(struct archive *, void *buff, size_t len);

/* ⚠️⚠️⚠️ 实测血泪(§5.9.2):本函数返回 int(4 字节)!
 * 曾被错误声明为 8 字节类型,导致读到 4294967271 死循环。
 * 任何人不得改此签名;CArchiveShimTests.testDataBlockSignatureIsInt 锁死。 */
int archive_read_data_block(struct archive *, const void **buff, size_t *len, int64_t *offset);

int archive_read_data_skip(struct archive *);

/* ---- 条目属性 ------------------------------------------------------------ */
const char *archive_entry_pathname(struct archive_entry *);   /* 归档内相对路径 */
int64_t archive_entry_size(struct archive_entry *);            /* la_int64_t = int64_t */
int archive_entry_is_encrypted(struct archive_entry *);         /* 四态检测的原始信号(§5.9.3) */

/* ---- 诊断 ----------------------------------------------------------------
 * error_string 为英文且可能含完整路径 → 只进日志/面包屑,绝不直接展示给用户(§5.9.3.1 规则 1)
 */
const char *archive_error_string(struct archive *);
const char *archive_version_string(void);

/* 格式名(如 "Zip" / "7-Zip" / "RAR5"):首次 next_header 成功后有效。
 * 加密四态中「全部加密」按格式分文案(§5.9.3 图 10 FMT 分支):
 * zip → 可解(需密码);7z → 库层面不支持(实测,给密码也没用)。 */
const char *archive_format_name(struct archive *);

/* ---- 解压密码(v2,2026-09-17) --------------------------------------------
 * ⚠️ 必须在 archive_read_open_filename **之前**调用 —— libarchive 在 open 时
 *    初始化各格式的解密上下文,open 之后再设就来不及了。
 * 返回 ARCHIVE_OK(0) / ARCHIVE_FAILED(-25) / ARCHIVE_FATAL(-30)。
 *
 * 实测边界(macOS 15.x / libarchive 3.7.4,样本见 Tests/Fixtures):
 *   · ZIP + ZipCrypto(传统加密)  可解 ✓
 *   · ZIP + AES-256(WinZip AES)  可解 ✓
 *   · 7z  内容加密 / 头部加密     不可解 ✗ —— 报 "currently not supported",
 *     即便密码正确也一样(这是库的能力边界,不是密码问题)
 *   · 密码错 → read 时报 -25 且错误串为 "Incorrect passphrase"
 *     未提供  → read 时报 -25 且错误串为 "Passphrase required for this entry"
 *     (两者**可区分**,故 UI 能精确说「密码不对」而不是笼统的「打开失败」)
 *   · 明文归档上调用本函数无害:密码被忽略,正常打开(有单测锁死)
 *
 * ⚠️ 隐私:passphrase 是敏感数据。调用方只可把它留在内存里传进来,
 *    绝不可写进面包屑 / 日志 / 崩溃报告 / 持久化存储(§5.10.4 同一条红线)。
 */
int archive_read_add_passphrase(struct archive *, const char *passphrase);

#ifdef __cplusplus
}
#endif

#endif /* CARCHIVESHIM_H */
