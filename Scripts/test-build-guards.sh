#!/bin/bash
# ============================================================================
# test-build-guards.sh —— 反向测试:两条**构建期**守卫真的拦得住吗(2026-09-24)
# ----------------------------------------------------------------------------
# 用法: ./Scripts/test-build-guards.sh
#
# 覆盖:
#   A. check-file-associations.sh —— 缺导出 UTI / 文档类型过少
#   B. git-tree-state.sh         —— 未跟踪文件算不算脏(以及**不许**误伤的三个方向)
#
# 为什么要有这个脚本:
#   这两段校验原先都内联在 build-app.sh 里,**只有跑完整次 archive 才碰得到**。
#   成本高到没人会去试,于是它们从来没被反向测试过 —— 而"缺一个 UTI"拦的是最沉默
#   的一类故障:装完看着一切正常,双击 .cbz 没反应,不报错。这不是假想的风险,
#   2026-09-16 复查时就发现旧的数量下限判据在"cbz 被删、rar/7z 还在"时会放行。
#
# ★ 关键设计:**不需要真实产物**。
#   A 用 /tmp 里现造的假 .app + 变异过的 Info.plist(守卫只读 Contents/Info.plist);
#   B 在 /tmp 里现造一个临时 git 仓库。
#   所以本脚本可以和构建完全解耦,随时能跑 —— 一个必须"先成功构建一次"才能跑的
#   自检,实际使用频率会低到等于不存在。
#
# 退出码: 0 全部符合预期 / 1 有守卫没拦住 / 2 前置不满足
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ASSOC="$ROOT_DIR/Scripts/check-file-associations.sh"
TREE="$ROOT_DIR/Scripts/git-tree-state.sh"
PB=/usr/libexec/PlistBuddy

for s in "$ASSOC" "$TREE"; do
    if [ ! -x "$s" ]; then
        echo "✗ 缺少可执行脚本: $s" >&2
        exit 2
    fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0

# 断言:退出码 + (可选)输出里必须出现的文案
# 用法: expect <名称> <期望退出码> <期望文案|-> <命令...>
expect() {
    local name="$1" want_rc="$2" want_text="$3"
    shift 3
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        echo "  ✗ $name —— 退出码是 $rc,期望 $want_rc" >&2
        printf '%s\n' "$out" | sed 's/^/      | /' >&2
        FAILED=$((FAILED + 1))
        return
    fi
    if [ "$want_text" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$want_text"; then
        echo "  ✗ $name —— 输出里没有「$want_text」" >&2
        printf '%s\n' "$out" | sed 's/^/      | /' >&2
        FAILED=$((FAILED + 1))
        return
    fi
    echo "  ✓ $name"
    PASS=$((PASS + 1))
}

# 专读 git-tree-state.sh 的 dirty 字段并比对。
# 不写成 `bash -c "[ \"\$(...)\" = 1 ]"` 那种一层套一层的写法:引号一多必然出错,
# 而且出错时看起来像"守卫没拦住",把根因指向错的地方。
expect_dirty() {
    local name="$1" want="$2" got
    got="$("$TREE" "$GR" 2>/dev/null | sed -n 's/^dirty=//p' | head -1)"
    if [ "$got" = "$want" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name —— dirty=$got,期望 $want" >&2
        FAILED=$((FAILED + 1))
    fi
}

echo "=============================================="
echo " 反向测试:构建期守卫"
echo "=============================================="

# ===========================================================================
# A. 文件关联守卫 —— 合成一个"完好"的 .app,再逐条破坏它
# ===========================================================================
echo ""
echo "── A. check-file-associations.sh ──"

GOOD_APP="$TMP/Good.app"
mkdir -p "$GOOD_APP/Contents"
GOOD_PLIST="$GOOD_APP/Contents/Info.plist"
cat > "$GOOD_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict><key>UTTypeIdentifier</key><string>com.gfredr.unroll.cbz</string></dict>
    <dict><key>UTTypeIdentifier</key><string>com.gfredr.unroll.cbr</string></dict>
    <dict><key>UTTypeIdentifier</key><string>com.gfredr.unroll.cb7</string></dict>
    <dict><key>UTTypeIdentifier</key><string>com.gfredr.unroll.cbt</string></dict>
    <dict><key>UTTypeIdentifier</key><string>com.gfredr.unroll.rar</string></dict>
    <dict><key>UTTypeIdentifier</key><string>com.gfredr.unroll.sevenzip</string></dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict><key>CFBundleTypeName</key><string>T1</string></dict>
    <dict><key>CFBundleTypeName</key><string>T2</string></dict>
    <dict><key>CFBundleTypeName</key><string>T3</string></dict>
    <dict><key>CFBundleTypeName</key><string>T4</string></dict>
    <dict><key>CFBundleTypeName</key><string>T5</string></dict>
  </array>
</dict>
</plist>
PLIST

# A0. 基线:完好的声明必须放行。**先有这一条,后面"拦下了"才有意义** ——
#     否则一个"什么输入都 exit 1"的坏守卫也能让后面全绿。
expect "A0 完好声明 → 放行" 0 "文件关联: 导出 UTI 6 个" "$ASSOC" "$GOOD_APP"

# A1. 只删 cbz 一个标识符,其余 5 个还在 ⇒ 计数仍是 5。
#     这正是 2026-09-16 那个旧数量下限判据会**放行**的场景,也是本守卫存在的理由。
BAD1="$TMP/Bad1.app"; mkdir -p "$BAD1/Contents"; cp "$GOOD_PLIST" "$BAD1/Contents/Info.plist"
$PB -c 'Delete :UTExportedTypeDeclarations:0' "$BAD1/Contents/Info.plist" >/dev/null
expect "A1 只删 cbz(其余 5 个仍在)→ 点名拦下" 1 "缺导出 UTI 声明: cbz" "$ASSOC" "$BAD1"

# A2. 四条漫画格式全删 ⇒ 四个名字都要点到,不能只说"缺了点什么"
BAD2="$TMP/Bad2.app"; mkdir -p "$BAD2/Contents"; cp "$GOOD_PLIST" "$BAD2/Contents/Info.plist"
for _ in 1 2 3 4; do $PB -c 'Delete :UTExportedTypeDeclarations:0' "$BAD2/Contents/Info.plist" >/dev/null; done
expect "A2 四条全删 → 四个名字都点到" 1 "缺导出 UTI 声明: cbz cbr cb7 cbt" "$ASSOC" "$BAD2"

# A3. 文档类型只剩 4 条 ⇒ 宽松数量下限触发
BAD3="$TMP/Bad3.app"; mkdir -p "$BAD3/Contents"; cp "$GOOD_PLIST" "$BAD3/Contents/Info.plist"
$PB -c 'Delete :CFBundleDocumentTypes:4' "$BAD3/Contents/Info.plist" >/dev/null
expect "A3 文档类型只剩 4 条 → 拦下" 1 "文档类型声明过少(4 个)" "$ASSOC" "$BAD3"

# A4. 前置不满足要与"守卫判它不合格"区分开:退出码 2 而不是 1。
#     混成一个码的话,调用方就没法区分"产物坏了"和"我传错了路径"。
expect "A4 不是 .app → 退出码 2(前置不满足)" 2 "不是 .app" "$ASSOC" "$TMP"
expect "A5 没给参数 → 退出码 2" 2 "用法:" "$ASSOC"

# A6. 真实产物(若在)也要过一遍 —— 合成 plist 只能证明守卫的逻辑对,
#     证明不了"它对真实 project.yml 生成出来的 plist 一样成立"。
REAL_APP="${DIST_DIR:-${ROOT_DIR}-dist}/Unroll.app"
if [ -d "$REAL_APP" ]; then
    expect "A6 真实产物 → 放行" 0 "文件关联: 导出 UTI" "$ASSOC" "$REAL_APP"
else
    echo "  ⚠ A6 跳过:没有 $REAL_APP(先跑 ./Scripts/build-app.sh)"
fi

# ===========================================================================
# B. git 树状态守卫 —— 在临时仓库里造五种树状态
# ===========================================================================
echo ""
echo "── B. git-tree-state.sh ──"

expect "B0 不是 git 仓库 → 退出码 2" 2 "不是 git 仓库" "$TREE" "$TMP"

GR="$TMP/repo"
mkdir -p "$GR"
git -C "$GR" init -q
git -C "$GR" config user.email "guard-test@example.invalid"
git -C "$GR" config user.name "guard-test"
# .gitignore 必须**先提交**:未跟踪的 .gitignore 自己就是"未跟踪文件",
# 会让 B1 的基线莫名其妙变成脏(这个坑在写本脚本时踩过一次)
printf 'ignored.log\n' > "$GR/.gitignore"
printf 'hello\n' > "$GR/tracked.txt"
git -C "$GR" add -A
git -C "$GR" commit -q -m init

# 读 guard 的某个字段
field() { "$TREE" "$GR" 2>/dev/null | sed -n "s/^$1=//p" | head -1; }

# B1. 基线:干净树
expect_dirty "B1 干净树 → dirty=0" 0

# B2. ★ 本次修掉的那个空洞:未跟踪文件必须算脏。
#     project.yml 的 sources 是目录级的、构建前又会 regen ⇒ 未跟踪的 .swift 会被
#     编进二进制,所以这一条不成立时,侧车的 dirty=0 就是一句谎话。
printf 'x\n' > "$GR/untracked.txt"
expect_dirty "B2 有未跟踪文件 → dirty=1(本次修掉的空洞)" 1
rm -f "$GR/untracked.txt"

# B3. 反方向:只动被 .gitignore 忽略的文件,必须**仍然干净**。
#     缺了这条,把判据改成"任何风吹草动都算脏"也能让 B2 绿 —— 那就成了误报机器,
#     而误报的下场是人开始忽略守卫。方向相反的两条断言必须成对存在。
printf 'noise\n' > "$GR/ignored.log"
expect_dirty "B3 只改被忽略的文件 → 仍 dirty=0(不许误伤)" 0
rm -f "$GR/ignored.log"

# B4. 已跟踪文件被改
printf 'changed\n' >> "$GR/tracked.txt"
expect_dirty "B4 改了已跟踪文件 → dirty=1" 1
git -C "$GR" checkout -q -- tracked.txt

# B5. 新文件已 git add(暂存)也算脏 —— 暂存不等于提交,二进制里仍有未提交的代码
printf 'y\n' > "$GR/staged.txt"
git -C "$GR" add staged.txt
expect_dirty "B5 新文件已暂存 → dirty=1" 1
git -C "$GR" reset -q HEAD staged.txt; rm -f "$GR/staged.txt"

# B6. 提交号/分支名与 git 自己的答案一致(侧车这两行也不能是"差不多")
WANT_COMMIT="$(git -C "$GR" rev-parse HEAD)"
WANT_BRANCH="$(git -C "$GR" rev-parse --abbrev-ref HEAD)"
GOT_COMMIT="$(field commit)"
GOT_BRANCH="$(field branch)"
if [ "$GOT_COMMIT" = "$WANT_COMMIT" ] && [ "$GOT_BRANCH" = "$WANT_BRANCH" ]; then
    echo "  ✓ B6 commit / branch 与 git 一致"
    PASS=$((PASS + 1))
else
    echo "  ✗ B6 commit/branch 不一致:guard=$GOT_COMMIT/$GOT_BRANCH git=$WANT_COMMIT/$WANT_BRANCH" >&2
    FAILED=$((FAILED + 1))
fi

echo ""
echo "----------------------------------------------"
if [ "$FAILED" -gt 0 ]; then
    echo "✗ $FAILED 条**没拦住**,$PASS 条符合预期 —— 守卫有洞,先修脚本再谈发布"
    exit 1
fi
echo "✓ $PASS 条全部符合预期(每条注入的坏输入都被拦下了)"
exit 0
