#!/bin/bash
# ============================================================================
# build-app.sh —— 构建可分发的 Unroll.app（Universal 2: arm64 + x86_64）
# ----------------------------------------------------------------------------
# 用法: ./Scripts/build-app.sh
# 产物: 仓库同级的 Unroll-dist/Unroll.app
#
# 说明:
# · 产物一律输出到「仓库之外」的同级目录 —— .app / .dmg / DerivedData 落进仓库根
#   会让 Xcode 与 Spotlight 反复遍历大目录,打开工程明显卡顿
#   (与 DLNACast / CacheCleaner 的 build-app.sh 同规)。
# · 版本号以 project.yml 的 MARKETING_VERSION 为唯一来源,可用 VERSION= 覆盖。
# · 默认 ad-hoc 签名(-),无需付费开发者账号即可分发;若要过 Gatekeeper 需
#   Developer ID + 公证,见文件末尾提示。
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="${DIST_DIR:-${ROOT_DIR}-dist}"
mkdir -p "$DIST_DIR"

# ----------------------------------------------- 产物↔源码绑定(2026-09-16) --
# 发布链要回答一个问题:「这个 .app 是从哪份源码构建的?」
# 早期用文件 mtime 回答(产物不早于源码最后一次提交时间),但那条判据有**假阳性**:
# 自然顺序是「先改源码 → 构建 → 提交」,构建必然发生在提交之前 —— 于是自己刚建好
# 的产物会被自己的守卫拦下(2026-09-16 实测,方向完全反了)。
# 现在改为**内容判据**:构建时把 HEAD 提交号写进 buildinfo 侧车文件,发布前检只比
# 字符串相等,时间不再参与任何判断。
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
# dirty 只看**已跟踪**文件:Unroll.xcodeproj 与两个 appex 的 Info.plist 都是
# xcodegen 生成物、已在 .gitignore 里,不该因为「构建过程重写了它们」就把一次
# 干净构建判成脏构建(那会让守卫长期误报,人就会开始忽略它)。
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  COMMIT_DIRTY=1
else
  COMMIT_DIRTY=0
fi

APP_NAME="Unroll"
SCHEME="${SCHEME:-Unroll-Distribution}"

VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)}"
VERSION="${VERSION:-1.0.0}"

ARCHIVE="$DIST_DIR/$APP_NAME.xcarchive"
APP_DIR="$DIST_DIR/$APP_NAME.app"

# 签名:默认 ad-hoc。有 Developer ID 时:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build-app.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "→ 从 project.yml 重新生成工程"
./Scripts/regen.sh

echo "→ xcodebuild archive ($APP_NAME $VERSION, arm64 + x86_64)"
rm -rf "$ARCHIVE" "$APP_DIR"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DIST_DIR/DerivedData" \
  ARCHS="x86_64 arm64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  -quiet

SRC_APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
if [ ! -d "$SRC_APP" ]; then
  echo "✗ 未找到 $SRC_APP" >&2
  exit 1
fi

cp -R "$SRC_APP" "$APP_DIR"

# 把提交号刻进 bundle —— 这是「产物↔源码」绑定的载体。
# · 必须写在**签名之前**:签名覆盖 Info.plist,签完再改会让 codesign --verify 直接失败;
# · 也不能写进 project.yml 的 info: 段 —— 那个文件里放不了「本次构建的头号」这种
#   随构建变化的值,只能在这里注入。
# 顺带的好处:拿到 dmg 的人不必信我们,直接
#   /usr/libexec/PlistBuddy -c 'Print :UnrollSourceCommit' Unroll.app/Contents/Info.plist
# 就知道这个二进制对应哪个公开提交。
APP_PLIST="$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UnrollSourceCommit string $COMMIT" "$APP_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :UnrollSourceCommit $COMMIT" "$APP_PLIST"

# ------------------------------------------------------ 嵌套代码签名 --
# 由内向外:先签 Contents/PlugIns/ 里的 QuickLook 扩展,再签 App 本身。
# 顺序反了(先签外层)会让外层签名当场失效 —— 嵌套代码校验要求子签名早于父签名。
# 为什么必须重签:Xcode 归档时扩展是按自身 target 的设置签的,而本脚本允许用
#   SIGN_IDENTITY 覆盖身份(默认 ad-hoc);不重签就会出现「扩展与外层身份不一致」,
#   Finder 会静默拒绝加载扩展(空格预览毫无反应,不报任何错 —— 最难查的一类故障)。
PLUGINS="$APP_DIR/Contents/PlugIns"

sign_appex() {
  local name="$1" ent="$2"
  local appex="$PLUGINS/$name.appex"
  [ -d "$appex" ] || { echo "✗ 缺少 $name.appex(Xcode 未嵌入扩展?)" >&2; exit 1; }
  [ -f "$ent" ] || { echo "✗ 缺少 entitlements:$ent" >&2; exit 1; }
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --entitlements "$ent" "$appex"
}

echo "→ 由内向外签名(先扩展后 App)"
if [ -d "$PLUGINS" ]; then
  sign_appex UnrollQuickLookThumbnail UnrollQuickLook/Thumbnail/UnrollQuickLookThumbnail.entitlements
  sign_appex UnrollQuickLookPreview   UnrollQuickLook/Preview/UnrollQuickLookPreview.entitlements
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --entitlements Unroll/Unroll.entitlements "$APP_DIR"
else
  echo "  ⚠️ 未找到 Contents/PlugIns/ —— QuickLook 扩展未嵌入(下方校验会拦下)" >&2
fi

# ------------------------------------------------------------------ 校验 --
echo ""
echo "→ 校验"

BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
INFO="$APP_DIR/Contents/Info.plist"

ARCHS_BUILT="$(lipo -archs "$BIN")"
echo "  架构    : $ARCHS_BUILT"
for want in arm64 x86_64; do
  case " $ARCHS_BUILT " in
    *" $want "*) ;;
    *) echo "  ✗ 缺架构 $want —— Universal 2 未达成" >&2; exit 1 ;;
  esac
done

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
echo "  版本    : $BUILT_VERSION"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "  ✗ 版本号不一致(期望 $VERSION)" >&2
  exit 1
fi

# 刻进去的提交号必须等于当前 HEAD。不相等只有一种可能:注入被跳过或被覆盖 ——
# 那之后整条「产物↔源码」链的根就断了,侧车写出来的也将是假的。所以在这里钉死。
COMMIT_IN_APP="$(/usr/libexec/PlistBuddy -c 'Print :UnrollSourceCommit' "$INFO" 2>/dev/null || echo '(缺)')"
if [ "$COMMIT_IN_APP" != "$COMMIT" ]; then
  echo "  ✗ bundle 内提交号与当前 HEAD 不一致:bundle=$COMMIT_IN_APP, HEAD=$COMMIT" >&2
  exit 1
fi
if [ "$COMMIT_DIRTY" = "1" ]; then
  echo "  源码提交: ${COMMIT:0:7}(⚠️ 工作区有未提交改动,此产物不宜发布)"
else
  echo "  源码提交: ${COMMIT:0:7}"
fi

# 下面两行刻意**不写成 `codesign … | grep …`**。原因是 set -o pipefail 下一个很隐蔽的
# 竞态(2026-09-16 实测抓到一次,同一行打印出两个互相矛盾的值):
#   `grep -m1` / `grep -q` 命中后立刻退出并关掉管道读端,而 codesign 可能还在写 →
#   codesign 收到 SIGPIPE、以 141 退出 → pipefail 让**整条管道**判为失败 →
#   后面的 `|| echo '…'` 兜底分支也执行。
# 危害不是"少打一个值",而是**打了两个矛盾的结论**:签名行会同时显示
# "Signature=adhoc" 和 "(无)";沙盒行会把已启用的沙盒报成「未启用」—— 后者是一句
# 关于安全边界的陈述,报错方向正好是误报"没有保护"。所以这里改成先把输出整段收进
# 变量、再用 shell 自己匹配,完全去掉会早退的管道。
SIG_DUMP="$(codesign -dv "$APP_DIR" 2>&1 || true)"
SIG_LINE=""
while IFS= read -r _line; do
  case "$_line" in Signature=*) SIG_LINE="$_line"; break ;; esac
done <<< "$SIG_DUMP"
echo "  签名    : ${SIG_LINE:-(无法读取)}"

ENT_DUMP="$(codesign -d --entitlements :- "$APP_DIR" 2>/dev/null || true)"
case "$ENT_DUMP" in
  *app-sandbox*) echo "  沙盒    : 已启用" ;;
  *)             echo "  沙盒    : ✗ 未启用(entitlements 里没有 app-sandbox)" ;;
esac

echo "  最低系统: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"

# 文件关联是「双击即用」的命脉:漏了 UTI,装完也抢不到默认打开权
#
# 校验的是**具体标识符在不在**,不是数量。2026-09-16 复查发现问题:原先只卡
# 「UTI ≥ 4 且文档类型 ≥ 5」的数量下限,而自 2026-09-14 新增裸 .rar / .7z 关联后
# 实际已是 6 / 7 —— 此时若 cbz 声明被误删而 rar/7z 还在,计数为 5,照样通过。
# 这正是这道防线本该拦住的沉默故障(装完看着正常,双击 .cbz 没反应)。
UTI_LIST="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations' "$INFO" 2>/dev/null || true)"
UTI_COUNT="$(printf '%s\n' "$UTI_LIST" | grep -c 'UTTypeIdentifier' || true)"
DOC_COUNT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$INFO" 2>/dev/null | grep -c 'CFBundleTypeName' || true)"
echo "  文件关联: 导出 UTI ${UTI_COUNT:-0} 个 / 文档类型 ${DOC_COUNT:-0} 个"

MISSING_UTI=""
for U in cbz cbr cb7 cbt; do
  # 用 grep -c(读到 EOF)而不是 grep -q(命中即退):后者配上 pipefail 会在
  # printf 收到 SIGPIPE 时把整条管道判失败,于是**每个** UTI 都报"缺失",
  # 变成一次纯属虚构的构建失败(同上文 codesign 那处是同一类坑)
  U_HITS="$(printf '%s\n' "$UTI_LIST" | grep -c "UTTypeIdentifier = com.gfredr.unroll.$U\$" || true)"
  if [ "${U_HITS:-0}" -eq 0 ]; then MISSING_UTI="$MISSING_UTI $U"; fi
done
if [ -n "$MISSING_UTI" ]; then
  echo "  ✗ 缺导出 UTI 声明:$MISSING_UTI —— 装完无法双击打开对应格式" >&2
  exit 1
fi
# 文档类型数量只做宽松下限(防止关联表整体塌掉);具体格式由上面的标识符校验负责
if [ "${DOC_COUNT:-0}" -lt 5 ]; then
  echo "  ✗ 文档类型声明过少($DOC_COUNT 个)—— 至少需 cbz/cbr/cb7/cbt + zip Alternate" >&2
  exit 1
fi

# Dock 图标是「像个正经 App」的底线:没编进 icns,Dock/Finder 只能显示通用白板
# (2026-09-14 实测踩坑:project.yml 缺 ASSETCATALOG_COMPILER_APPICON_NAME 时静默丢失)
if [ ! -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]; then
  echo "  ✗ 缺少 AppIcon.icns —— Dock/Finder 会显示通用图标(project.yml 需设 ASSETCATALOG_COMPILER_APPICON_NAME)" >&2
  exit 1
fi
echo "  图标    : AppIcon.icns ✓"

# QuickLook 扩展:漏嵌 / 扩展点写错 / 缺架构,症状都是「Finder 里空格毫无反应、
# 图标还是通用图标」—— 不报错、不崩,只能靠人偶然发现。所以这里逐项硬校验
echo "  扩展    :"
for entry in "UnrollQuickLookThumbnail:com.apple.quicklook.thumbnail" \
             "UnrollQuickLookPreview:com.apple.quicklook.preview"; do
  EXT_NAME="${entry%%:*}"
  EXT_WANT="${entry##*:}"
  EXT_DIR="$PLUGINS/$EXT_NAME.appex"
  if [ ! -d "$EXT_DIR" ]; then
    echo "    ✗ 缺少 $EXT_NAME.appex —— Finder 缩略图/空格预览会直接没反应(不报错)" >&2
    exit 1
  fi
  EXT_GOT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' \
             "$EXT_DIR/Contents/Info.plist" 2>/dev/null || echo '(缺)')"
  if [ "$EXT_GOT" != "$EXT_WANT" ]; then
    echo "    ✗ $EXT_NAME 扩展点错误:期望 $EXT_WANT,实际 $EXT_GOT" >&2
    exit 1
  fi
  EXT_ARCHS="$(lipo -archs "$EXT_DIR/Contents/MacOS/$EXT_NAME" 2>/dev/null || echo '(无二进制)')"
  for want_arch in arm64 x86_64; do
    case " $EXT_ARCHS " in
      *" $want_arch "*) ;;
      *) echo "    ✗ $EXT_NAME 缺架构 $want_arch($EXT_ARCHS)—— 扩展也必须 Universal 2" >&2
         exit 1 ;;
    esac
  done
  # QLSupportedContentTypes 决定系统把哪些 UTI 路由到这个扩展。缺了它扩展仍会被
  # 加载,但任何 cbz 都不会送进来 —— 现场只报 "Could not generate a thumbnail"
  # (code 102),没有一行日志指出是声明缺失(2026-09-16 实测踩到)
  EXT_TYPES="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:QLSupportedContentTypes' \
               "$EXT_DIR/Contents/Info.plist" 2>/dev/null || true)"
  if [ -z "$EXT_TYPES" ]; then
    echo "    ✗ $EXT_NAME 未声明 QLSupportedContentTypes —— 系统不会把 cbz 路由过来" >&2
    exit 1
  fi
  echo "    $EXT_NAME ✓ $EXT_WANT · $EXT_ARCHS · 认 $(printf '%s\n' "$EXT_TYPES" | grep -c 'com.gfredr' || true) 种 UTI"
done

# 嵌套代码校验:--verify --strict 会一路校验到 PlugIns 里的扩展。
# 这一步是上面「由内向外签名」的验收,也是扩展能被 Finder 加载的前提
if ! codesign --verify --strict "$APP_DIR" 2>/dev/null; then
  echo "  ✗ 签名校验失败(嵌套代码未按由内向外签名?)—— Finder 会拒绝加载扩展" >&2
  exit 1
fi
echo "  签名校验: codesign --verify --strict ✓(含嵌套扩展)"

# ---------------------------------------------------------------- buildinfo --
# 侧车文件,与 .app 同级。发布前检(publish.sh)与打包脚本(make-dmg.sh)读它,
# 不再依赖任何文件时间戳。键值格式故意做成最朴素的一行一个 key=value ——
# 用 sed 就能读,不必引入 jq / plist。
BUILDINFO="$DIST_DIR/$APP_NAME.buildinfo"
{
  echo "app=$APP_NAME"
  echo "version=$BUILT_VERSION"
  echo "commit=$COMMIT"
  echo "branch=$GIT_BRANCH"
  echo "dirty=$COMMIT_DIRTY"
  echo "archs=$ARCHS_BUILT"
  echo "identity=$SIGN_IDENTITY"
  echo "built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$BUILDINFO"

echo ""
echo "✓ 生成 $APP_DIR"
echo "  → buildinfo: $BUILDINFO(commit ${COMMIT:0:7} / dirty=$COMMIT_DIRTY)"
echo "  → open $APP_DIR"
echo "  → 打 dmg: ./Scripts/make-dmg.sh"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo ""
  echo "  ℹ 当前为 ad-hoc 签名:本机可运行,但分发到别人机器会被 Gatekeeper 拦一次,"
  echo "    需在 README 安装说明里给出绕行方式(xattr -dr com.apple.quarantine / 右键打开)。"
fi
