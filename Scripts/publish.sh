#!/bin/bash
# ============================================================================
# publish.sh —— 把 Unroll 发布到 GitHub(默认 dry-run)
# ----------------------------------------------------------------------------
# 用法:
#   ./Scripts/publish.sh          # 只做前检 + 打印将要执行的命令,不碰网络
#   ./Scripts/publish.sh --go     # 真正执行:建仓 → 推 main → 推 tag → 建 Release
#
# 为什么默认 dry-run:
#   发布是**不可逆的对外动作** —— 推上去的东西会被镜像、缓存、搜到。而这里
#   前检的每一项都属于"沉默失败":比如 tag 与 HEAD 不一致时,Release 页面
#   看起来完全正常,指向的却是不含最新修复的提交。这类问题必须挡在推送之前。
#
# 前检覆盖:gh 登录态 / 提交身份是否匿名 / 历史里有没有混入真实身份 /
#           工作区干净度 / tag 是否指向 HEAD / DMG 与 SHA256 / 发布说明 /
#           受版本控制文件里有没有本机路径与私人邮箱
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

REPO="GFredR/Unroll"
REPO_DESC="A native macOS reader for CBZ / CBR / CB7 / CBT archives — no unzip, no library, no extraction. Double-click and read."
TOPICS=(macos swift swiftui macos-app comic-reader cbz cbr manga archive-reader quicklook libarchive)

GO=0
if [ "${1:-}" = "--go" ]; then
    GO=1
fi

DIST_DIR="${DIST_DIR:-${ROOT_DIR}-dist}"

# ---------------------------------------------------------------- 输出小工具 --
FAILED=0
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; FAILED=$((FAILED + 1)); }
warn() { echo "  ! $*"; }
step() { echo ""; echo "$*"; }

# dry-run 时只打印;--go 时真正执行
run() {
    if [ "$GO" = 1 ]; then
        echo "  \$ $*"
        "$@"
    else
        echo "  \$ $*  (dry-run 未执行)"
    fi
}

echo "=============================================="
if [ "$GO" = 1 ]; then
    echo " Unroll 发布(!! 真实执行 !!)"
else
    echo " Unroll 发布前检(dry-run,不会碰网络)"
fi
echo "=============================================="

# ------------------------------------------------------------ 1. 版本与命名 --
step "[1/8] 版本号与命名"

VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
if [ -z "$VERSION" ]; then
    fail "project.yml 里读不到 MARKETING_VERSION"
    VERSION="0.0.0"
else
    ok "版本 $VERSION(来源:project.yml)"
fi
TAG="v$VERSION"

# --------------------------------------------------------------- 2. 工具链 --
step "[2/8] 工具与登录态"

for tool in gh git xcodebuild; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool 已安装"
    else
        fail "缺少 $tool"
    fi
done

if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        ok "gh 已登录"
    else
        fail "gh 未登录 —— 先跑:gh auth login"
    fi
fi

# ------------------------------------------------------------- 3. 提交身份 --
# 公开仓库的每一笔提交都带作者邮箱。用真实邮箱推上去等于把身份挂在搜索结果里,
# 而笔名隔离一旦破掉是**要重写历史**才能挽回的(filter-repo + 强推)。
step "[3/8] 提交身份(笔名隔离)"

GIT_NAME="$(git config user.name || true)"
GIT_EMAIL="$(git config user.email || true)"

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    fail "git user.name / user.email 未配置"
else
    ok "当前身份:$GIT_NAME <$GIT_EMAIL>"
    case "$GIT_EMAIL" in
        *noreply.github.com) ok "使用的是 GitHub noreply 邮箱" ;;
        *) fail "邮箱不是 noreply —— 公开提交会泄漏真实邮箱($GIT_EMAIL)" ;;
    esac
fi

# 历史里的作者必须全部等于当前身份;任何一笔例外都意味着曾经用真实身份提交过
ME="$GIT_NAME <$GIT_EMAIL>"
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
    OUTSIDERS="$(git log --format='%an <%ae>' | sort -u | grep -Fxv "$ME" || true)"
    if [ -n "$OUTSIDERS" ]; then
        fail "历史里存在非当前身份的作者提交(需要 filter-repo 重写历史):"
        printf '      %s\n' $OUTSIDERS >&2
    else
        ok "全部 $(git rev-list --count HEAD) 笔提交的作者都是当前身份"
    fi
fi

# --------------------------------------------------------- 4. 工作区与 tag --
step "[4/8] 工作区与 tag 对齐"

DIRTY="$(git status --porcelain)"
if [ -z "$DIRTY" ]; then
    ok "工作区干净"
else
    fail "工作区有未提交改动 —— 先提交(否则发布物与源码对不上):"
    printf '      %s\n' "$DIRTY" >&2
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    # 约束不是"tag 必须顶在 HEAD"——那条规则会让每改一次文档就得移动 tag,
    # 反而养成移动 tag 的坏习惯。真正要保证的是**产物仍精确代表 tag 那棵树**:
    #   ① tag 必须在 HEAD 的历史上(否则 tag 指向一个不在 main 上的提交);
    #   ② tag 与 HEAD 之间不能有**源码**改动(源码 = 编进二进制的那些)。
    # 只改了 .github/ 或文档时,产物与 tag 的对应关系完全没变,放行。
    # 只算**编进二进制**的路径。刻意排除测试与 fixture:它们改十次也不影响产物,
    # 算进去只会制造噪音,而噪音会训练人忽略告警(守卫失效的常见死法)。
    SHIPPING_PATHS=(Unroll ArchiveKit UnrollQuickLook project.yml Scripts/gen_appicon.swift
                    ':(exclude)ArchiveKit/Tests')

    if ! git merge-base --is-ancestor "$TAG" HEAD 2>/dev/null; then
        fail "$TAG 不在 HEAD 的历史上 —— tag 指向了一个不在 main 上的提交"
    else
        SRC_CHANGED="$(git diff --name-only "$TAG"..HEAD -- "${SHIPPING_PATHS[@]}")"
        if [ -n "$SRC_CHANGED" ]; then
            fail "$TAG 之后还有**源码**改动 —— 产物不再代表当前代码:"
            printf '      %s\n' $SRC_CHANGED >&2
            echo "      → 要发布 tag 那版:确认产物是 tag 时构建的即可(见下条提示)" >&2
            echo "      → 要发布当前代码:把 tag 移到 HEAD 并重跑 build-app.sh + make-dmg.sh" >&2
        else
            OTHER_CHANGED="$(git diff --name-only "$TAG"..HEAD | wc -l | tr -d ' ')"
            ok "$TAG 在 HEAD 历史上,且两者之间无源码改动($OTHER_CHANGED 个非源码文件已忽略)"
        fi
    fi
else
    fail "tag $TAG 不存在 —— 先:git tag -a $TAG -m \"Unroll $VERSION\""
fi

# ------------------------------------------------------------- 5. 发布产物 --
step "[5/8] 发布产物"

DMG="$DIST_DIR/Unroll-$VERSION.dmg"
SHA="$DMG.sha256"
NOTES="$DIST_DIR/release-notes-$TAG.md"

if [ -f "$DMG" ]; then
    ok "DMG:$(du -h "$DMG" | awk '{print $1}')"
else
    fail "缺 $DMG —— 先跑:./Scripts/make-dmg.sh"
fi

# 产物必须由**当前的**打包脚本生成。改了打包脚本却不重建,是一类最隐蔽的
# 沉默不一致:源码没变、tag 没变、sha256 也自洽 —— 唯独产物里少了这次的改进
# (2026-09-16 实测撞上:.fseventsd 隐藏与布局告警改完,旧 dmg 里一个都没有)。
SCRIPTS=(Scripts/build-app.sh Scripts/make-dmg.sh)
if [ -n "$(git status --porcelain -- "${SCRIPTS[@]}")" ]; then
    fail "打包脚本有未提交改动 —— 现有产物必然不是它生成的"
fi
if [ -f "$DMG" ]; then
    SCRIPT_TS="$(git log -1 --format=%ct -- "${SCRIPTS[@]}" 2>/dev/null || echo 0)"
    DMG_TS="$(stat -f %m "$DMG" 2>/dev/null || echo 0)"
    if [ "${DMG_TS:-0}" -ge "${SCRIPT_TS:-0}" ]; then
        ok "产物不早于打包脚本的最后一次提交"
    else
        fail "打包脚本在产物生成之后被改过 —— 产物不含这次的改进"
        echo "      最后一次脚本改动:$(git log -1 --format='%h %s' -- "${SCRIPTS[@]}")" >&2
        echo "      → 重跑:./Scripts/build-app.sh && ./Scripts/make-dmg.sh" >&2
    fi
fi

if [ -f "$SHA" ]; then
    # 必须 cd 到校验和文件所在目录再校验:文件里记的是相对文件名,
    # 在别处跑会报 No such file or directory,被误读成"产物损坏"
    if (cd "$DIST_DIR" && shasum -a 256 -c "Unroll-$VERSION.dmg.sha256" >/dev/null 2>&1); then
        ok "SHA256 校验通过"
    else
        fail "SHA256 校验失败 —— DMG 与校验和不一致(重新跑 make-dmg.sh)"
    fi
else
    fail "缺 $SHA"
fi

if [ -f "$NOTES" ]; then
    ok "发布说明:$(basename "$NOTES")"
else
    fail "缺 $NOTES —— Release 会没有说明正文"
fi

# ----------------------------------------------------------- 6. 泄漏扫描 --
# 扫描的是**受版本控制的文本文件**。本机绝对路径里带着系统用户名,私人邮箱域名
# 同理 —— 两者都能把笔名和真实身份连起来。
# 想额外扫真实姓名等关键词:本地建 Scripts/.identity-patterns(每行一个,
# 已被 .gitignore 排除)。**不要把该文件提交**。
step "[6/8] 受控文件泄漏扫描"

LOCAL_USER="$(id -un)"
PATTERN="/Users/${LOCAL_USER}/"
PATTERN="$PATTERN|[A-Za-z0-9._%+-]+@(qq|163|126|foxmail|gmail|outlook|hotmail)\.com"

PATFILE="Scripts/.identity-patterns"
if [ -f "$PATFILE" ]; then
    EXTRA="$(grep -v '^[[:space:]]*#' "$PATFILE" | grep -v '^[[:space:]]*$' | paste -sd'|' - || true)"
    if [ -n "$EXTRA" ]; then
        PATTERN="$PATTERN|$EXTRA"
        ok "已并入 $PATFILE 的自定义关键词"
    fi
else
    warn "未发现 $PATFILE(可选:放真实姓名等关键词,做更严的扫描)"
fi

LEAKS="$(git ls-files -z | xargs -0 grep -lIE "$PATTERN" 2>/dev/null || true)"
if [ -n "$LEAKS" ]; then
    fail "以下受控文件命中泄漏关键词:"
    printf '      %s\n' $LEAKS >&2
else
    ok "受控文件未命中本机路径 / 私人邮箱关键词"
fi

# ------------------------------------------------------------- 7. 远程状态 --
step "[7/8] 远程仓库状态"

REMOTE="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE" ]; then
    ok "尚无 origin —— 将由 gh repo create 建立"
else
    ok "origin = $REMOTE"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh repo view "$REPO" >/dev/null 2>&1; then
        ok "$REPO 已存在(将直接推送,不重复建仓)"
    else
        ok "$REPO 尚不存在(将新建 public 仓库)"
    fi
fi

# ----------------------------------------------------------------- 汇总 --
step "[8/8] 前检结论"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "✗ 有 $FAILED 项未通过 —— 修掉再发布。"
    exit 1
fi
echo "  ✓ 全部通过"

# --------------------------------------------------------------- 执行计划 --
echo ""
echo "----------------------------------------------"
echo "将要执行:"
echo "----------------------------------------------"
if [ -z "$REMOTE" ]; then
    run gh repo create "$REPO" --public --source=. --remote=origin --description "$REPO_DESC"
else
    echo "  \$ (已存在 origin,跳过建仓)"
fi
echo "  \$ gh auth setup-git        # 让 git 复用 gh 的凭据(推 https 需要)"
echo "  \$ git push -u origin main"
echo "  \$ git push origin --tags"
echo "  \$ gh release create $TAG <dmg> <sha256> --notes-file <notes>   # 附产物与校验和"
echo "  \$ gh repo edit $REPO --add-topic ...   # ${TOPICS[*]}"
echo ""

# ------------------------------------------------------- 只能人眼确认的门槛 --
cat <<'EOF'
----------------------------------------------
自动化覆盖不到、发布前请人眼过一遍的:
----------------------------------------------
  1. QuickLook 真机验收:./Scripts/verify-quicklook.sh --install
     若扩展不生效 → 从 release notes 里摘掉 QuickLook 条目并重切 DMG
     (不能让说明写着一件没验证过的事)
  2. 界面验收取证:./Scripts/verify-ui.sh
     自动拍三张截图(空态 / 崩溃询问 / dmg 布局)到 docs/,**需要人做的只是看一眼**。
     能自动拍的是"它长什么样";拍不出来的是"这文案是否得体",那仍得人判断。
  3. 200 页连翻的内存与掉帧(决定是否要走 AppKit Plan B)—— 体感类,只能人跑
  4. GitHub 网页侧:仓库描述与 Topics 是否正常;以及
     Settings → Emails → "Block command line pushes that expose my email" 已勾选
EOF

if [ "$GO" = 0 ]; then
    echo ""
    echo "以上为 dry-run。确认无误后执行:./Scripts/publish.sh --go"
    exit 0
fi

# ------------------------------------------------------------------ 执行 --
echo ""
echo "----------------------------------------------"
echo "开始发布"
echo "----------------------------------------------"

gh auth setup-git

if [ -z "$REMOTE" ]; then
    gh repo create "$REPO" --public --source=. --remote=origin --description "$REPO_DESC"
else
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
fi

git push -u origin main
# v1.0.0 从未公开发布,但 tag 本身是有效的历史标记,一并推上去让版本脉络可读
git push origin --tags

gh release create "$TAG" "$DMG" "$SHA" \
    --title "Unroll $VERSION" \
    --notes-file "$NOTES"

TOPIC_ARGS=()
for t in "${TOPICS[@]}"; do
    TOPIC_ARGS+=(--add-topic "$t")
done
gh repo edit "$REPO" "${TOPIC_ARGS[@]}"

echo ""
echo "✓ 发布完成:https://github.com/$REPO"
echo "  → 记得回到上面那份"人眼门槛"清单逐项确认"
