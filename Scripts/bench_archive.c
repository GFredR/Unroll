// ============================================================================
// bench_archive.c —— solid 7z 随机访问代价基准(设计文档 §5.1 / 测试文档 §4)
// ----------------------------------------------------------------------------
// 自给自足:自己造样本 + 自己测,零第三方依赖(只链系统 libarchive)。
// 编译:  xcrun --sdk macosx clang -O2 -Wall bench_archive.c -o bench_archive -larchive
//
// 用法:
//   ./bench_archive make  <out> <7z|zip> <pages> [pageKB]   # 造样本
//   ./bench_archive reopen <file> <maxPages>                # 每页独立 open(现状 data(at:))
//   ./bench_archive seq    <file> <maxPages>                # 单实例顺序扫描(M2 方案)
//
// 为什么存在:
//   M1 体检实测发现「每页调用一次 data(at:)」在 solid 7z 上是 O(n^2):
//   第 i 页要重解压前 i-1 页。本工具用来量化它,并验证「单实例顺序扫描器」
//   能把复杂度降回 O(n)。M2 实现 PageStore 后可直接复用来验收。
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

// ---- libarchive 手写原型(SDK 不导出 archive.h,与 CArchiveShim/shim.h 同源) ----
struct archive;
struct archive_entry;
typedef long long la_int64_t;

extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern int archive_read_data_block(struct archive *, const void **, size_t *, long long *);
extern int archive_read_data_skip(struct archive *);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);

extern struct archive *archive_write_new(void);
extern int archive_write_set_format_7zip(struct archive *);
extern int archive_write_set_format_zip(struct archive *);
extern int archive_write_open_filename(struct archive *, const char *);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern long archive_write_data(struct archive *, const void *, size_t);
extern int archive_write_finish_entry(struct archive *);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);
extern struct archive_entry *archive_entry_new(void);
extern void archive_entry_free(struct archive_entry *);
extern void archive_entry_set_pathname(struct archive_entry *, const char *);
extern void archive_entry_set_size(struct archive_entry *, long long);
extern void archive_entry_set_filetype(struct archive_entry *, unsigned int);
extern void archive_entry_set_perm(struct archive_entry *, unsigned int);

// 注意:archive_read_data_block 在 macOS libarchive 里返回 **32 位** int。
// 若误声明为 8 字节(ssize_t),失败的 -25 会被读成 4294967271,循环判断
// `> 0` 直接死循环 —— 这是 2026-09-09 实测踩过的坑,原型必须与 shim.h 一致。
// 返回值语义:0 = OK 且 len 出参有效;1 = EOF;< 0 = 错误码。

static double now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

// ---- 造样本 ----------------------------------------------------------------
static int cmd_make(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: make <out> <7z|zip> <pages> [pageKB]\n"); return 1; }
    const char *out = argv[2];
    int is7z = (strcmp(argv[3], "7z") == 0);
    int pages = atoi(argv[4]);
    size_t psz = (argc > 5 ? (size_t)atoi(argv[5]) : 300) * 1024;

    // 高重复数据:solid 压缩能真正生效(真实漫画 jpg 不可压缩,此样本为最坏情况的代价上界)
    char *buf = (char *)malloc(psz);
    if (!buf) return 1;
    for (size_t i = 0; i < psz; i += 16) memcpy(buf + i, "PIXELPATTERN-", 13);

    struct archive *a = archive_write_new();
    if (is7z) archive_write_set_format_7zip(a); else archive_write_set_format_zip(a);
    if (archive_write_open_filename(a, out) != 0) { fprintf(stderr, "open fail\n"); return 1; }
    for (int i = 0; i < pages; i++) {
        struct archive_entry *e = archive_entry_new();
        char nm[64]; snprintf(nm, sizeof nm, "p%03d.bin", i);
        archive_entry_set_pathname(e, nm);
        archive_entry_set_size(e, (long long)psz);
        archive_entry_set_filetype(e, 0100000);
        archive_entry_set_perm(e, 0644);
        archive_write_header(a, e);
        archive_write_data(a, buf, psz);
        archive_write_finish_entry(a);
        archive_entry_free(e);
    }
    archive_write_close(a);
    archive_write_free(a);
    free(buf);
    printf("✅ %s  %s  %d 页 × %zu KB\n", out, is7z ? "7z(solid)" : "zip", pages, psz / 1024);
    return 0;
}

// ---- 通用:open + 走 header --------------------------------------------------
static struct archive *open_archive(const char *path) {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    if (archive_read_open_filename(a, path, 10240) != 0) { archive_read_free(a); return NULL; }
    return a;
}

// 完整读完当前条目的字节数(正确语义:rc==0 累加,rc==1 EOF 退出)
static ssize_t drain_entry(struct archive *a) {
    const void *buf; size_t sz; long long off;
    ssize_t total = 0; int guard = 0;
    while (1) {
        int rc = archive_read_data_block(a, &buf, &sz, &off);
        if (rc == 1 || rc < 0) break;
        if (sz > 0) total += (ssize_t)sz;
        if (++guard > 500000) { fprintf(stderr, "GUARD_TRIP\n"); break; }
    }
    archive_read_data_skip(a);
    return total;
}

// ---- 模式 A:每页独立 open(模拟现状 ArchiveDocument.data(at:)) -------------
static int cmd_reopen(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: reopen <file> <maxPages>\n"); return 1; }
    const char *path = argv[2];
    int maxPages = atoi(argv[3]);
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("模式 A · 每页独立 open（现状 data(at:)）  %s\n", path);
    printf("%6s %10s %12s %12s\n", "page", "this(ms)", "cumul(ms)", "bytes");
    double cumul = 0;
    for (int i = 0; i < maxPages; i++) {
        double t0 = now_ms();
        struct archive *a = open_archive(path);
        if (!a) { fprintf(stderr, "open fail\n"); return 1; }
        struct archive_entry *e;
        int pos = -1;
        while (pos < i) { if (archive_read_next_header(a, &e) != 0) break; pos++; }
        ssize_t bytes = (pos == i) ? drain_entry(a) : 0;
        archive_read_close(a);
        archive_read_free(a);
        double dt = now_ms() - t0;
        cumul += dt;
        if (i < 10 || i % 10 == 0 || i == maxPages - 1)
            printf("%6d %10.2f %12.2f %12zd\n", i, dt, cumul, bytes);
    }
    printf("TOTAL(A) = %.2f ms / %d 页\n", cumul, maxPages);
    return 0;
}

// ---- 模式 B:单实例顺序扫描(M2 PageStore 方案) -----------------------------
static int cmd_seq(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: seq <file> <maxPages>\n"); return 1; }
    const char *path = argv[2];
    int maxPages = atoi(argv[3]);
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("模式 B · 单实例顺序扫描（M2 方案）  %s\n", path);
    printf("%6s %10s %12s %12s\n", "page", "this(ms)", "cumul(ms)", "bytes");
    struct archive *a = open_archive(path);
    if (!a) { fprintf(stderr, "open fail\n"); return 1; }
    struct archive_entry *e;
    double cumul = 0;
    for (int i = 0; i < maxPages; i++) {
        double t0 = now_ms();
        if (archive_read_next_header(a, &e) != 0) { printf("  仅 %d 个条目\n", i); break; }
        ssize_t bytes = drain_entry(a);
        double dt = now_ms() - t0;
        cumul += dt;
        if (i < 10 || i % 10 == 0 || i == maxPages - 1)
            printf("%6d %10.2f %12.2f %12zd\n", i, dt, cumul, bytes);
    }
    archive_read_close(a);
    archive_read_free(a);
    printf("TOTAL(B) = %.2f ms / %d 页\n", cumul, maxPages);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: bench_archive <make|reopen|seq> ...\n");
        return 1;
    }
    if (strcmp(argv[1], "make") == 0)   return cmd_make(argc, argv);
    if (strcmp(argv[1], "reopen") == 0) return cmd_reopen(argc, argv);
    if (strcmp(argv[1], "seq") == 0)    return cmd_seq(argc, argv);
    fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 1;
}
