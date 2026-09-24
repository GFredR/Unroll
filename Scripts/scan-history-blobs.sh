#!/bin/bash
# ---------------------------------------------------------------------------
# 历史对象泄漏扫描（2026-09-24 新增）—— 补上原扫描的两个盲区
#
# 原扫描（publish.sh 第 6 步）只覆盖两处，都很窄：
#   ① `git ls-files` 的**当前内容** —— 看不见**曾经存在、后来被删掉**的文件；
#   ② `git log --format=%B` 的提交消息 —— 看不见文件内容。
# 于是留下两个盲区，而它们的共同点是**你事后删不掉**：
#   · 已删文件的历史内容：当前工作区干净得看不出任何问题，但那份内容仍在对象库里，
#     push 之后任何人 `git log --all -- <path>` 都能取回；
#   · 二进制里的字符串：PNG 元数据、被编进产物的 .strings、工具链刻进二进制的
#     本机路径 —— `grep -I`（跳过二进制）与「只扫文本」都会静默放过。
#
# 本脚本扫的是 `--batch-all-objects` —— 比 `rev-list --all` 更全：**连已不可达的
# dangling 对象也扫**。那些对象照样会被 push 上去（除非 gc 过），而 gc 不受我们
# 控制，所以不能拿"它现在不可达"当安全依据。
#
# ⚠️ 命中时**只打印对象短哈希与自查命令，绝不打印内容、也绝不打印路径**：
#   把命中行打出来，正好就是把要防的东西显示到终端 / CI 日志里 —— 守卫自己完成
#   一次泄漏。路径同理：泄漏物本身可能就是文件名。
#
# ⚠️ 已知覆盖不到的一档（如实记录，不假装扫全了）：UTF-16 编码的**非 ASCII**
#   文本。去 NUL 那一遍能覆盖 UTF-16 里的 ASCII 片段（`a\0b\0c\0` → `abc`），
#   但一个 UTF-16 编码的中文姓名取不出连续的 UTF-8 字节。仓库自身受控文件都是
#   UTF-8（实测），所以这一档只在"有人手工提交了一份 UTF-16 文本"时才成立。
#
# ---------------------------------------------------------------------------
# ★ 为什么不是纯 shell —— 两次实测之后改的（2026-09-24）
#   第一版：对**每个** blob 起一次 `git cat-file` + 两次 `wc -c` + `tr` + `grep`。
#           真实仓库 551 个 blob ⇒ 三千多次 fork/exec，跑了 2 分 42 秒还没完；
#           第二版即便只在"命中"分支做逐对象定位，也照样被前台超时杀掉（退出码 137）。
#           沙箱下每次 fork/exec 都很贵，而"扫描"本身反而是最便宜的部分。
#   现在：**一个 python3 进程**流式读 `git cat-file --batch-all-objects --batch`，
#           按 header 里的 size 精确切片、顺带完成定位。整库实测 **约 3 秒**。
#           一次做完，不再分「先判定再定位」两阶段 —— 定位既然不额外花钱，
#           就没有理由把可自查的哈希推迟到第二阶段。
#
# ⚠️ 正则语义差异：grep 用的是 POSIX ERE，python 用 re。本项目实际使用的模式
#   （本机路径 / 私人邮箱域名 / 本地自定义关键词）在两者下等价；但如果以后往
#   Scripts/.identity-patterns 里写 POSIX 专有语法（如 `[[:space:]]`），
#   必须同时确认 python re 也认（\s 才是它的写法）。
#
# 用法:  scan-history-blobs.sh '<ERE 模式>' [仓库路径]
# 退出码: 0 = 干净；1 = 有命中；2 = 前置不满足（参数缺失 / 不是 git 仓库 / 缺 python3）
# ---------------------------------------------------------------------------
set -uo pipefail

PATTERN="${1:-}"
REPO="${2:-.}"

if [ -z "$PATTERN" ]; then
    echo "用法: $(basename "$0") '<ERE 模式>' [仓库路径]" >&2
    exit 2
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "不是 git 仓库: $REPO" >&2
    exit 2
fi

# 缺 python3 时**不能**静默降级成"扫过了、干净" —— 那比不扫更坏。
# 退出码 2 让调用方（publish.sh）把它当"前置不满足"拦下来。
if ! command -v python3 >/dev/null 2>&1; then
    echo "缺 python3 —— 本扫描无法完成(不做降级:静默跳过等于假装扫过)" >&2
    exit 2
fi

OUT="$(python3 - "$PATTERN" "$REPO" <<'PY'
import re, subprocess, sys

pattern, repo = sys.argv[1], sys.argv[2]
# 与旧扫描一致:不区分大小写(grep -iE)。ERE 与 python re 的差异说明见脚本头。
try:
    rx = re.compile(pattern.encode("utf-8"), re.IGNORECASE)
except re.error as e:
    print("REGEX_ERROR %s" % e)
    sys.exit(3)

proc = subprocess.Popen(
    ["git", "-C", repo, "cat-file", "--batch-all-objects", "--batch"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

blobs = 0
hits = []
while True:
    header = proc.stdout.readline()
    if not header:
        break
    parts = header.split()
    if len(parts) != 3:
        continue                # "<sha> missing" 之类:没有 size,无法定位,跳过
    sha = parts[0].decode("ascii", "replace")
    otype = parts[1]
    try:
        size = int(parts[2])
    except ValueError:
        continue
    data = proc.stdout.read(size)
    proc.stdout.read(1)         # 尾部换行
    if otype != b"blob":
        continue
    blobs += 1
    if rx.search(data):
        hits.append(sha)
        continue
    # 去 NUL 再试一遍:UTF-16 里的 ASCII 片段(`a\0b\0c\0`)还原成 `abc` 后才匹配得到
    if b"\x00" in data and rx.search(data.replace(b"\x00", b"")):
        hits.append(sha)
proc.stdout.close()
proc.wait()

# 路径也是泄漏面:文件名本身可能就是泄漏物(已删文件的名字同样留在历史里)
paths = subprocess.run(
    ["git", "-C", repo, "rev-list", "--objects", "--all"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
path_hits = 0
for line in paths.split(b"\n"):
    sp = line.find(b" ")
    if sp < 0:
        continue
    if rx.search(line[sp + 1:]):
        path_hits += 1

print("BLOBS %d" % blobs)
print("PATHHITS %d" % path_hits)
for sha in hits:
    print("HIT %s" % sha)
PY
)"
RC=$?

if [ "$RC" -eq 3 ]; then
    echo "✗ 关键词不是合法的正则:$OUT" >&2
    exit 2
fi
if [ "$RC" -ne 0 ]; then
    echo "✗ 历史扫描未能完成(python3 退出码 $RC)" >&2
    exit 2
fi

N_BLOB="$(printf '%s\n' "$OUT" | sed -n 's/^BLOBS //p' | head -1)"
PATH_HITS="$(printf '%s\n' "$OUT" | sed -n 's/^PATHHITS //p' | head -1)"
N_BLOB="${N_BLOB:-0}"
PATH_HITS="${PATH_HITS:-0}"
# ⚠️ 用 grep -c(读到 EOF)而不是 grep -q(命中即退):后者配上 pipefail 会因 printf
#    收到 SIGPIPE(141)而把整条管道判成非零 —— 于是"有命中"被读成"没命中",
#    在**唯一需要报警的那条分支**上给出完全相反的结论。本项目的头号老坑。
HIT_COUNT="$(printf '%s\n' "$OUT" | grep -c '^HIT ' || true)"
HIT_COUNT="${HIT_COUNT:-0}"

if [ "$PATH_HITS" -eq 0 ] && [ "$HIT_COUNT" -eq 0 ]; then
    echo "✓ 历史对象未命中(扫了 $N_BLOB 个 blob,含已删文件与 dangling 对象)"
    exit 0
fi

if [ "$HIT_COUNT" -gt 0 ]; then
    # 上限 20 行:命中数可能上百(比如关键词恰好是 bundle id 片段),而前检的输出
    # 会进终端与 CI 日志 —— 刷屏会让人直接跳过这一段,反而看不见"确实有泄漏"。
    # 省略的条数照实报出来,不假装只有 20 个。
    echo "✗ 以下 blob 的**内容**命中关键词(内容刻意不打印,用 blob= 自查):" >&2
    LISTED=0
    printf '%s\n' "$OUT" | grep '^HIT ' | while read -r _ sha; do
        LISTED=$((LISTED + 1))
        [ "$LISTED" -gt 20 ] && continue
        printf '      blob=%s  → 自查: git log --all --find-object=%s --oneline\n' \
            "${sha:0:10}" "$sha" >&2
    done
    if [ "$HIT_COUNT" -gt 20 ]; then
        echo "      … 另有 $((HIT_COUNT - 20)) 个 blob 命中(省略;要看全部请把脚本里的 20 改大再跑)" >&2
    fi
fi
if [ "$PATH_HITS" -gt 0 ]; then
    echo "✗ 有 $PATH_HITS 个对象**路径**命中关键词(刻意不打印路径:它本身可能就是泄漏物)" >&2
    echo "  自查(在本机跑,输出别贴进任何公开渠道):" >&2
    echo "    git -C '$REPO' rev-list --objects --all | cut -d' ' -f2- | grep -aE '<模式>'" >&2
fi
echo "  ⚠️ 这类泄漏当前工作区看着是干净的 —— 要清它必须重写历史(filter-repo 后 force-push)。" >&2
exit 1
