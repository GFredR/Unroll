#!/bin/bash
# ============================================================================
# test-release-guards.sh —— 反向测试:确认发布前检真的拦得住坏产物
# ----------------------------------------------------------------------------
# 用法: ./Scripts/test-release-guards.sh
# 前置: ./Scripts/build-app.sh && ./Scripts/make-dmg.sh(需要真实产物做基线)
#       且产物必须**仍代表当前源码** —— 源码前进过就先重建,否则「基线」与
#       「commit 不符」两条只能跳过,脚本以退出码 2 告诉你"未完整验证"
#
# 为什么要有这个脚本:
#   publish.sh 里「产物↔源码绑定」那三条判据平时**永远是绿的** —— 因为正常流程
#   下产物就是对的。于是没人知道它是"真绿"还是"根本没在检查"。一个从不失败的
#   守卫等于没有守卫,而它的失效方式是无声的:人以为有保护,实际什么都没有。
#   这里注入四种坏产物,逐一确认前检会以明确的文案拦下。
#
# 覆盖范围:
#   publish.sh 的三条判据(commit / dirty / 哈希)全部注入验证。
#   make-dmg.sh 里「镜像内 App 的提交号 == 侧车」那条**不在本脚本内** ——
#   它必须真的建一次 dmg 再挂载才能触发,成本是整个打包流程。验证办法见
#   docs/测试与验证.md §14.3(一次性手工注入,已在 2026-09-16 实测通过)。
#
# 退出码: 0 全部符合预期 / 1 有判据没拦住 / 2 前置不满足(产物已过期,未能完整验证)
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

REAL_DIST="${DIST_DIR:-${ROOT_DIR}-dist}"
VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
REAL_DMG="$REAL_DIST/Unroll-$VERSION.dmg"
REAL_SHA="$REAL_DMG.sha256"
REAL_INFO="$REAL_DMG.buildinfo"
NOTES="release-notes-v$VERSION.md"

MISSING=""
for f in "$REAL_DMG" "$REAL_SHA" "$REAL_INFO"; do
  [ -e "$f" ] || MISSING="$MISSING $(basename "$f")"
done
if [ -n "$MISSING" ]; then
  echo "✗ 缺真实产物:$MISSING" >&2
  echo "  → 先跑:./Scripts/build-app.sh && ./Scripts/make-dmg.sh" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# DMG 用符号链接指过去:测试全程不复制、不修改真实产物。
# shasum / du / PlistBuddy 都会跟随符号链接,所以前检读到的就是真那份。
ln -s "$REAL_DMG" "$TMP/Unroll-$VERSION.dmg"
cp "$REAL_SHA" "$TMP/Unroll-$VERSION.dmg.sha256"
if [ -f "$REAL_DIST/$NOTES" ]; then cp "$REAL_DIST/$NOTES" "$TMP/$NOTES"; fi

INFO_TMP="$TMP/Unroll-$VERSION.dmg.buildinfo"
PASS=0
FAILED=0
SKIPPED=0
STALE=0

# 跑一次前检。整体注定失败(本机 gh 未登录 / tag 可能落后),我们只看关心的那几句
run_check() { DIST_DIR="$TMP" "$ROOT_DIR/Scripts/publish.sh" 2>&1 || true; }

# case_check <名称> <期望出现的拦截文案> [不应出现的文案]
case_check() {
  local name="$1" want="$2" notwant="${3:-}" out
  out="$(run_check)"
  if ! printf '%s' "$out" | grep -qF -- "$want"; then
    echo "  ✗ $name —— 前检没拦下(期望出现:$want)" >&2
    FAILED=$((FAILED + 1))
    return
  fi
  if [ -n "$notwant" ] && printf '%s' "$out" | grep -qF -- "$notwant"; then
    echo "  ✗ $name —— 不该报错却报了:$notwant" >&2
    FAILED=$((FAILED + 1))
    return
  fi
  echo "  ✓ $name"
  PASS=$((PASS + 1))
}

# 把真实侧车按给定 sed 表达式改一处,写成一个"坏侧车"
mutate_info() { sed -e "$1" "$REAL_INFO" > "$INFO_TMP"; }

echo "=============================================="
echo " 反向测试:产物↔源码绑定判据(Unroll $VERSION)"
echo "=============================================="
echo "  基线产物:$(basename "$REAL_INFO") ← $(sed -n 's/^commit=//p' "$REAL_INFO" | head -1)"
echo ""

# --- 0. 基线:真实侧车必须通过,否则后面几条"拦下了"毫无意义 ------------------
# ⚠️ 这一步必须**先判定产物是否还代表当前源码**,否则会给出一个会把人带偏的结论:
#    源码在打 tag 之后又前进时(开发期的常态),基线必然红 —— 而"基线红"看起来
#    和"判据坏了"一模一样,脚本原先把两者都叫「守卫有洞,先修 publish.sh」,
#    正好把人推向"去放宽 publish.sh"这条错路。真相是**产物过期了**,
#    该做的是重建产物,而不是改判据。
cp "$REAL_INFO" "$INFO_TMP"
BASE_OUT="$(run_check)"
if printf '%s' "$BASE_OUT" | grep -qF -- "产物来自当前源码"; then
  echo "  ✓ 基线:真实侧车三条判据全过"
  PASS=$((PASS + 1))
else
  STALE=1
  SKIPPED=$((SKIPPED + 1))
  echo "  ⚠ 基线:跳过 —— 产物**已过期**,不是当前源码构建的" >&2
  echo "     侧车:$(sed -n 's/^commit=//p' "$REAL_INFO" | head -1 | cut -c1-7) · 当前 HEAD:$(git rev-parse --short HEAD)" >&2
  echo "     这不是「守卫有洞」:源码在打 tag 之后又前进了。" >&2
  echo "     → 要跑完整自检,先重建产物:./Scripts/build-app.sh && ./Scripts/make-dmg.sh" >&2
  echo "     → 发布前同样必须先重建 —— publish.sh 拦下过期产物是它**应该**做的。" >&2
fi

# --- 1. 侧车声明的提交不是最后一次源码改动 → 产物里没有当前源码 ---------------
# ⚠️ 产物已过期时这条**证明不了任何事**:那句拦截文案本来就会打出来(因为确实不符),
#    所以它既可能来自"判据在工作",也可能只是"产物真的旧了"。必须标为跳过。
mutate_info 's/^commit=.*/commit=0000000000000000000000000000000000000000/'
if [ "$STALE" = 1 ]; then
  echo "  ⚠ 跳过:commit 与当前源码不符 —— 产物已过期时这条文案本来就成立;重建后可验"
  SKIPPED=$((SKIPPED + 1))
else
  case_check "commit 与当前源码不符 → 拦下" "产物不是当前源码构建的"
fi

# --- 2. 构建时工作区是脏的 → 有未提交改动被编进了二进制 -----------------------
mutate_info 's/^dirty=.*/dirty=1/'
case_check "dirty=1 → 拦下" "产物构建时工作区是脏的"

# --- 3. 侧车哈希与 DMG 实际哈希不符 → 侧车是旧产物留下的 ----------------------
#   这条是防「侧车旧、DMG 也旧,两者恰好自洽」的关键补位
mutate_info 's/^dmg_sha256=.*/dmg_sha256=0000000000000000000000000000000000000000000000000000000000000000/'
case_check "侧车哈希与 DMG 不符 → 拦下" "侧车哈希与 DMG 实际哈希不符"

# --- 4. 侧车整个不在(旧流程产出的 DMG)→ 不能假装知道它来自哪个提交 ----------
rm -f "$INFO_TMP"
case_check "侧车缺失 → 拦下" "无法确认产物来自哪个提交"

echo ""
echo "----------------------------------------------"
if [ "$FAILED" -gt 0 ]; then
  echo "✗ $FAILED 条判据没拦住,$PASS 条符合预期 —— 守卫有洞,先修 publish.sh"
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "⚠ $PASS 条符合预期,但 $SKIPPED 条**跳过** —— 产物已过期,本次未完整验证"
  echo "  重建产物($PASS/$((PASS + SKIPPED)) → 全部)后再跑一次才算过:"
  echo "  ./Scripts/build-app.sh && ./Scripts/make-dmg.sh && ./Scripts/test-release-guards.sh"
  exit 2
fi
echo "✓ $PASS 条判据全部符合预期(注入的坏产物都被拦下了)"
