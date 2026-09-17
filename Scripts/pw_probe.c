/* ============================================================================
 * pw_probe.c —— 加密归档密码支持边界探针（一次性工具的固化版本）
 * ----------------------------------------------------------------------------
 * 用途：回答「系统 libarchive 对某种加密归档，在 不给密码 / 给对 / 给错 三种
 *       输入下分别能读到什么」。这是 v2「输密码查看图片」功能的行为依据 ——
 *       **决定给不给某个格式密码入口**，靠的就是这张表，不是猜。
 *       结果矩阵见 `docs/测试与验证.md` §6.3。
 *
 * 编译与运行：
 *   cc -O0 -o /tmp/pw_probe Scripts/pw_probe.c -larchive
 *   /tmp/pw_probe ArchiveKit/Tests/Fixtures/encrypted-zip.cbz            # 不给密码
 *   /tmp/pw_probe ArchiveKit/Tests/Fixtures/encrypted-zip.cbz secret     # 给对
 *   /tmp/pw_probe ArchiveKit/Tests/Fixtures/encrypted-zip.cbz wrongpw    # 给错
 *
 * 为什么不用 App 里的代码：本探针**故意不复用** ArchiveKit —— 它要回答的是
 * 「库本身的能力边界」，混进项目自己的错误分流逻辑反而看不清原始返回码与
 * 错误串。它只做最小的事：加密码 → 打开 → 列目录 → 逐条读干净。
 *
 * 安全：**只读**。不写任何文件、不改样本、不发网络请求。
 *
 * 为什么自写 extern 原型：macOS SDK 不导出 `archive.h`（详见 ArchiveKit 的
 * CArchiveShim），这里的声明与 `shim.h` 同路线。
 * 注意 `archive_read_data` 的返回值必须声明成 `long`/32 位有符号 ——
 * 声明成无符号会把失败的 -25 读成 4294967271 并造成死循环（§6.2 的挂起坑）。
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct archive;
struct archive_entry;

extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_add_passphrase(struct archive *, const char *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern long archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_format_name(struct archive *);
extern int archive_entry_is_encrypted(struct archive_entry *);
extern const char *archive_version_string(void);

/* 参数: <file> [password]   password 为空串或缺省表示不给密码 */
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: pw_probe <file> [password]\n"); return 2; }
    const char *path = argv[1];
    const char *pw = (argc >= 3 && argv[2][0]) ? argv[2] : NULL;

    printf("### %s  [pw=%s]\n", path, pw ? pw : "(none)");
    printf("    version=%s\n", archive_version_string());

    struct archive *a = archive_read_new();
    if (!a) { printf("    new=NULL\n"); return 1; }

    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    if (pw) {
        /* 注意：这里返回 0 只代表「密码登记成功」，**不代表密码对** ——
         * 库不在这时校验。真正的验证只能靠下面真读一条（§5.9.6 约束②）。 */
        int r = archive_read_add_passphrase(a, pw);
        printf("    add_passphrase -> %d\n", r);
    }

    if (archive_read_open_filename(a, path, 10240) != 0) {
        printf("    OPEN FAILED: %s\n", archive_error_string(a) ?: "(null)");
        archive_read_free(a);
        return 1;
    }

    int listed = 0, okdata = 0, faildata = 0;
    char firstFail[512] = "";
    char fmt[128] = "";
    int lastEnc = 0;

    for (;;) {
        struct archive_entry *e = NULL;
        int r = archive_read_next_header(a, &e);
        if (r == 1) break;                       /* EOF */
        if (r < 0 && r != -20) {                 /* FAILED / FATAL */
            snprintf(firstFail, sizeof firstFail, "next_header r=%d: %s",
                     r, archive_error_string(a) ?: "(null)");
            break;
        }
        if (!e) continue;
        if (listed == 0) {
            const char *fn = archive_format_name(a);
            if (fn) snprintf(fmt, sizeof fmt, "%s", fn);
        }
        lastEnc = archive_entry_is_encrypted(e);
        listed++;

        /* 尝试读出整个条目 —— ZipCrypto 的校验字节在条目**末尾**，
         * 只读开头有 1/256 的概率放过错误密码，所以这里必须读到底。 */
        long total = 0; int bad = 0;
        char buf[65536];
        for (;;) {
            long n = archive_read_data(a, buf, sizeof buf);
            if (n == 0) break;
            if (n < 0) { bad = 1;
                if (!firstFail[0])
                    snprintf(firstFail, sizeof firstFail, "read_data r=%ld: %s",
                             n, archive_error_string(a) ?: "(null)");
                break; }
            total += n;
        }
        if (bad) { faildata++; }
        else { okdata++; }
        if (listed <= 3)
            printf("    [%d] %-22s enc=%d bytes=%ld%s\n",
                   listed, archive_entry_pathname(e) ?: "?", lastEnc, total,
                   bad ? "  <FAILED>" : "");
    }

    printf("    format=%s  listed=%d  ok=%d  failed=%d  firstEnc=%d\n",
           fmt[0] ? fmt : "(none)", listed, okdata, faildata, lastEnc);
    if (firstFail[0]) printf("    ERR: %s\n", firstFail);

    archive_read_free(a);
    return (faildata == 0 && listed > 0) ? 0 : 1;
}
