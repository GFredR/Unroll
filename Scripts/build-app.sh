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

echo "  签名    : $(codesign -dv "$APP_DIR" 2>&1 | grep -m1 'Signature=' || echo '(无)')"
echo "  沙盒    : $(codesign -d --entitlements :- "$APP_DIR" 2>/dev/null | grep -q 'app-sandbox' && echo '已启用' || echo '未启用')"
echo "  最低系统: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"

# 文件关联是「双击即用」的命脉:漏了 UTI,装完也抢不到默认打开权
UTI_COUNT="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations' "$INFO" 2>/dev/null | grep -c 'UTTypeIdentifier' || true)"
DOC_COUNT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$INFO" 2>/dev/null | grep -c 'CFBundleTypeName' || true)"
echo "  文件关联: 导出 UTI $UTI_COUNT 个 / 文档类型 $DOC_COUNT 个"
if [ "${UTI_COUNT:-0}" -lt 4 ] || [ "${DOC_COUNT:-0}" -lt 5 ]; then
  echo "  ✗ 文件关联声明不全(cbz/cbr/cb7/cbt + zip Alternate),装完无法双击打开" >&2
  exit 1
fi

# Dock 图标是「像个正经 App」的底线:没编进 icns,Dock/Finder 只能显示通用白板
# (2026-09-14 实测踩坑:project.yml 缺 ASSETCATALOG_COMPILER_APPICON_NAME 时静默丢失)
if [ ! -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]; then
  echo "  ✗ 缺少 AppIcon.icns —— Dock/Finder 会显示通用图标(project.yml 需设 ASSETCATALOG_COMPILER_APPICON_NAME)" >&2
  exit 1
fi
echo "  图标    : AppIcon.icns ✓"

echo ""
echo "✓ 生成 $APP_DIR"
echo "  → open $APP_DIR"
echo "  → 打 dmg: ./Scripts/make-dmg.sh"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo ""
  echo "  ℹ 当前为 ad-hoc 签名:本机可运行,但分发到别人机器会被 Gatekeeper 拦一次,"
  echo "    需在 README 安装说明里给出绕行方式(xattr -dr com.apple.quarantine / 右键打开)。"
fi
