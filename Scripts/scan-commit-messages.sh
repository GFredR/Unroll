#!/bin/bash
# ---------------------------------------------------------------------------
# 提交消息泄漏扫描（2026-09-23 新增）
#
# 为什么单独成一个脚本而不是塞进 publish.sh 里:
#   publish.sh 第 6 步扫的是**受控文件的内容**,而提交消息是**另一个通道**。
#   两者都会随 push 公开,但代价差一个量级 —— 文件里的泄漏删掉重提交即可,
#   提交消息里的泄漏要 filter-repo 重写历史、还得 force-push。
#   更关键的是**没有人会回头重读 68 条旧 commit message**,所以它天然是盲区。
#
# ⚠️ 命中时只打印「短哈希 + 日期」,**绝不打印消息内容**:
#   把命中行打出来,正好就是把要防的东西显示到终端 / CI 日志里 ——
#   守卫自己完成了一次泄漏。
#
# 用法:  scan-commit-messages.sh '<ERE 模式>' [仓库路径]
# 退出码:0 = 干净;1 = 有命中;2 = 前置不满足(参数缺失 / 不是 git 仓库)
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

HITS=0
# here-string 而不是管道:① 管道会让循环跑在子 shell 里,HITS 出了循环就丢;
# ② 管道 + pipefail 时 `grep -q` 提前退出会让上游收 SIGPIPE(141),
#    打印出与事实相反的结论。两条坑都用 here-string 避开。
while read -r sha; do
    [ -z "$sha" ] && continue
    BODY="$(git -C "$REPO" log -1 --format='%B' "$sha" 2>/dev/null || true)"
    if grep -qIE "$PATTERN" <<< "$BODY"; then
        printf '      %s  %s\n' \
            "$(git -C "$REPO" log -1 --format='%h' "$sha")" \
            "$(git -C "$REPO" log -1 --format='%ad' --date=short "$sha")" >&2
        HITS=$((HITS + 1))
    fi
done <<< "$(git -C "$REPO" log --format=%H 2>/dev/null || true)"

if [ "$HITS" -gt 0 ]; then
    echo "✗ $HITS 条提交消息命中关键词(内容刻意不打印,用 git show <哈希> 自查)" >&2
    exit 1
fi

echo "✓ 提交消息未命中($(git -C "$REPO" rev-list --count HEAD 2>/dev/null) 条已扫)"
exit 0
