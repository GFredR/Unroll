#!/bin/bash
# ============================================================================
# test-history-scan.sh —— 反向测试:历史对象泄漏扫描真的补上了那两个盲区吗
# ----------------------------------------------------------------------------
# 用法: ./Scripts/test-history-scan.sh
#
# 为什么要有它:
#   scan-history-blobs.sh 存在的唯一理由是「原扫描看不见已删文件与二进制」。
#   如果它自己也不过是一句声明,那这个盲区就只是从"没人看"变成"没人看但以为有人看"。
#   本脚本在 /tmp 里现造仓库,把四个场景逐一造出来,并且**同时跑一遍旧扫描**
#   (`git ls-files | xargs grep -lIE`,publish.sh 第 6 步的做法),确认它在同一个
#   输入上确实是漏的 —— 这才是"盲区"这个词的证据,而不是推测。
#
# ⚠️ 全程在临时仓库里操作,**不碰真实仓库**。
# 退出码: 0 全部符合预期 / 1 有断言不成立 / 2 前置不满足
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SCAN="$ROOT_DIR/Scripts/scan-history-blobs.sh"
if [ ! -x "$SCAN" ]; then
    echo "✗ 缺少可执行脚本: $SCAN" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "✗ 需要 python3 来精确写二进制测试文件" >&2
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAILED=$((FAILED + 1)); }

# 新扫描:跑一次,只看退出码(0 干净 / 1 命中)
new_scan() { "$SCAN" "$1" "$2" >/dev/null 2>&1; }

# 旧扫描:完全照 publish.sh 第 6 步的做法(`grep -lIE`,其中 -I 跳过二进制)。
# 返回 0 = 命中,1 = 干净。
old_scan() {
    local hits
    hits="$(git -C "$2" ls-files -z | xargs -0 -r grep -lIE "$1" 2>/dev/null || true)"
    [ -n "$hits" ]
}

expect_hit()  { new_scan "$1" "$2" && bad "$3 —— 新扫描漏了" || ok "$3"; }
expect_clean() { new_scan "$1" "$2" && ok "$3" || bad "$3 —— 新扫描误报"; }

echo "=============================================="
echo " 反向测试:历史对象泄漏扫描"
echo "=============================================="
echo ""

R="$TMP/repo"
git init -q "$R"
git -C "$R" config user.email "scan-test@example.invalid"
git -C "$R" config user.name "scan-test"
echo "benign" > "$R/README.txt"
git -C "$R" add -A && git -C "$R" commit -q -m init

# ---------------------------------------------------------------------------
# T1/T2 二进制:文件**留在工作区**,好与旧扫描做同输入对照
# ---------------------------------------------------------------------------
# 二进制里夹一个 ASCII token,前后塞 NUL。grep -a 能读出来;而旧扫描用的
# `grep -I` 会把整个文件当二进制**跳过** —— 这就是"二进制"这个盲区的本体。
python3 -c "open('$R/bin.dat','wb').write(b'\x00\x01LEAK_TWO\x00\xff\xfe' + b'\x00'*64)"
git -C "$R" add -A && git -C "$R" commit -q -m "add binary"

if old_scan 'LEAK_TWO' "$R"; then
    bad "T2 前提不成立:旧扫描居然命中了二进制文件(那这个盲区不存在,本脚本的前提要重写)"
else
    ok "T2a 旧扫描(git ls-files + grep -I)确实跳过二进制 —— 盲区成立"
fi
expect_hit 'LEAK_TWO' "$R" "T2b 新扫描抓到二进制里的字符串"

# ---------------------------------------------------------------------------
# T3 已删文件:提交后再删。旧扫描看 `git ls-files`(当前工作区),历史无从谈起
# ---------------------------------------------------------------------------
echo "LEAK_ONE" > "$R/gone.txt"
git -C "$R" add -A && git -C "$R" commit -q -m "add gone"
rm -f "$R/gone.txt"
git -C "$R" add -A && git -C "$R" commit -q -m "delete gone"

if old_scan 'LEAK_ONE' "$R"; then
    bad "T3 前提不成立:旧扫描竟然看见了已删文件的内容"
else
    ok "T3a 旧扫描看不见已删文件的内容 —— 盲区成立"
fi
expect_hit 'LEAK_ONE' "$R" "T3b 新扫描抓到已删文件的历史内容"

# ---------------------------------------------------------------------------
# T4 UTF-16LE:ASCII 字符被 NUL 隔开 ⇒ 原始字节匹配不到,必须靠"去 NUL"那一遍
# ---------------------------------------------------------------------------
python3 -c "open('$R/u16.txt','wb').write('LEAK_THREE'.encode('utf-16-le'))"
git -C "$R" add -A && git -C "$R" commit -q -m "add utf16"
rm -f "$R/u16.txt"
git -C "$R" add -A && git -C "$R" commit -q -m "delete utf16"

expect_hit 'LEAK_THREE' "$R" "T4 新扫描抓到 UTF-16 里的 ASCII 片段(靠去 NUL 那一遍)"

# ---------------------------------------------------------------------------
# T5 路径也是一种泄漏面:文件名本身可能就是泄漏物
# ---------------------------------------------------------------------------
echo "x" > "$R/LEAK_FOUR.txt"
git -C "$R" add -A && git -C "$R" commit -q -m "add named"
rm -f "$R/LEAK_FOUR.txt"
git -C "$R" add -A && git -C "$R" commit -q -m "delete named"
expect_hit 'LEAK_FOUR' "$R" "T5 新扫描抓到**路径**命中(且刻意不打印路径)"

# ---------------------------------------------------------------------------
# T6 dangling:提交被 reset 掉之后,内容仍在对象库里,但已不在任何 ref 上。
#     --batch-all-objects 看得见它,rev-list --all **看不见** —— 差别必须是可证的。
# ---------------------------------------------------------------------------
D="$TMP/dangling"
git init -q "$D"
git -C "$D" config user.email "scan-test@example.invalid"
git -C "$D" config user.name "scan-test"
echo "base" > "$D/README.txt"
git -C "$D" add -A && git -C "$D" commit -q -m init
echo "LEAK_FIVE" > "$D/ghost.txt"
git -C "$D" add -A && git -C "$D" commit -q -m "will be dropped"
git -C "$D" reset -q --hard HEAD~1          # 那一笔不再可达

if git -C "$D" rev-list --objects --all | grep -qa 'ghost'; then
    bad "T6 前提不成立:rev-list --all 还能看见 ghost.txt(本机 git 行为与预期不符)"
else
    ok "T6a rev-list --objects --all 看不见被 reset 掉的对象 —— 旧口径会漏"
fi
expect_hit 'LEAK_FIVE' "$D" "T6b 新扫描仍抓到 dangling 对象里的内容"

# ---------------------------------------------------------------------------
# T7 反方向:干净仓库必须放过。缺了这条,一个"永远报红"的坏守卫也能让上面全绿。
# ---------------------------------------------------------------------------
expect_clean 'ZZZ_DEFINITELY_NOT_PRESENT_ZZZ' "$R" "T7 不存在的关键词 → 干净(不许误报)"

# T8 退出码 2:前置不满足要与"检出泄漏"分开
"$SCAN" 'x' "$TMP" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "T8 不是 git 仓库 → 退出码 2(前置不满足)"; else bad "T8 前置不满足没返回 2"; fi
"$SCAN" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "T9 没给模式 → 退出码 2"; else bad "T9 缺参数没返回 2"; fi

echo ""
echo "----------------------------------------------"
if [ "$FAILED" -gt 0 ]; then
    echo "✗ $FAILED 条不成立,$PASS 条符合预期"
    exit 1
fi
echo "✓ $PASS 条全部符合预期(两个盲区都补上,且没有误报)"
exit 0
