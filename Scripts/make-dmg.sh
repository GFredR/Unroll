#!/bin/bash
# ============================================================================
# make-dmg.sh —— 把 Unroll.app 打成 .dmg 安装包
# ----------------------------------------------------------------------------
# 用法: ./Scripts/make-dmg.sh
# 产物: 仓库同级的 Unroll-dist/Unroll-<版本>.dmg
#
# 内容:Unroll.app + /Applications 符号链接(拖进去即安装) + Finder 图标布局。
# 若 .app 不存在会先调 build-app.sh。
#
# 环境变量:
#   VERSION=1.0.0           覆盖版本号(默认取 project.yml)
#   SKIP_FINDER_LAYOUT=1    跳过 Finder 窗口布局(无人值守/CI 场景用 —— 该步骤会
#                           走 AppleScript 驱动 Finder,可能弹自动化授权框)
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="${DIST_DIR:-${ROOT_DIR}-dist}"
mkdir -p "$DIST_DIR"

APP_NAME="Unroll"

VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)}"
VERSION="${VERSION:-1.0.0}"

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
VOL_NAME="$APP_NAME $VERSION"

# 1. 先确保 .app 存在
if [ ! -d "$APP_DIR" ]; then
  echo "→ $APP_DIR 不存在,先构建"
  ./Scripts/build-app.sh
fi

# 2. staging:app + Applications 别名
echo "→ 准备 staging 目录"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# 3. 临时 dmg(可写,便于设图标布局)
echo "→ 生成临时 dmg"
TEMP_DMG="$DIST_DIR/temp-${DMG_NAME}"
rm -f "$TEMP_DMG"
hdiutil create -ov -format UDRW -srcfolder "$DMG_STAGING" \
  -volname "$VOL_NAME" -fs HFS+ \
  "$TEMP_DMG" > /dev/null

# 4. Finder 窗口布局(失败一律不阻塞 —— 布局只是观感)
if [ "${SKIP_FINDER_LAYOUT:-0}" != "1" ]; then
  DEVICE="$(hdiutil attach -readwrite -noverify "$TEMP_DMG" | grep -o '/dev/disk[0-9]*' | head -1 || true)"
  if [ -n "$DEVICE" ]; then
    MOUNT_POINT="$(mount | grep "$DEVICE " | awk '{print $3}' || true)"
    if [ -n "$MOUNT_POINT" ]; then
      echo "→ 设置 Finder 窗口布局"
      osascript <<EOF || true
      tell application "Finder"
        tell disk "$VOL_NAME"
          open
          delay 1
          set current view of container window to icon view
          set toolbar visible of container window to false
          set statusbar visible of container window to false
          set the bounds of container window to {200, 120, 860, 560}
          set arrangement of icon view options of container window to not arranged
          set icon size of icon view options of container window to 110
          set position of item "$APP_NAME.app" of container window to {160, 220}
          set position of item "Applications" of container window to {500, 220}
          update without registering applications
          delay 1
          close
        end tell
      end tell
EOF
      hdiutil detach "$DEVICE" > /dev/null || true
    fi
  fi
fi

# 5. 压成最终 dmg
echo "→ 压缩为最终 dmg"
# 布局步骤的 detach 是 `|| true`:一旦没卸干净,同名卷占着 temp 镜像,
# convert 必报「资源暂时不可用」(2026-09-14 实测踩坑)—— 这里强制清场
RESIDUAL="$(mount | grep -F "on /Volumes/$VOL_NAME " | awk '{print $1}' || true)"
if [ -n "$RESIDUAL" ]; then
  echo "→ 卸载残留卷 $RESIDUAL"
  hdiutil detach "$RESIDUAL" > /dev/null || hdiutil detach -force "$RESIDUAL" > /dev/null
fi
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DIST_DIR/$DMG_NAME" > /dev/null
rm -f "$TEMP_DMG"
rm -rf "$DMG_STAGING"

# 6. 挂载校验:能否挂上、内容是否齐全
echo "→ 挂载校验"
MOUNT_OUT="$(hdiutil attach -readonly -noverify "$DIST_DIR/$DMG_NAME" | grep -o '/Volumes/.*' | head -1 || true)"
if [ -n "$MOUNT_OUT" ]; then
  if [ -d "$MOUNT_OUT/$APP_NAME.app" ] && [ -L "$MOUNT_OUT/Applications" ]; then
    echo "  内容    : $APP_NAME.app + Applications 链接 ✓"
  else
    echo "  ✗ dmg 内容不完整" >&2
    hdiutil detach "$MOUNT_OUT" > /dev/null || true
    exit 1
  fi
  hdiutil detach "$MOUNT_OUT" > /dev/null || true
else
  echo "  ✗ dmg 挂载失败" >&2
  exit 1
fi

# 7. 签名提示
if ! codesign -dv "$APP_DIR" 2>&1 | grep -q 'Developer ID'; then
  echo ""
  echo "⚠️  当前是 ad-hoc 签名(无付费开发者账号),别人首次打开会被 Gatekeeper 拦。"
  echo "    README 安装说明里给出这两条绕行方式即可:"
  echo "      xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
  echo "      或:右键点 $APP_NAME.app → 打开"
fi

DMG_SIZE="$(du -h "$DIST_DIR/$DMG_NAME" | awk '{print $1}')"

# 8. 校验和:无签名的发布,SHA256 是下载者唯一的完整性/防篡改凭据
(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

echo ""
echo "✓ 生成 $DIST_DIR/$DMG_NAME ($DMG_SIZE)"
echo "  → SHA256: $DIST_DIR/$DMG_NAME.sha256"
echo "  → open $DIST_DIR/$DMG_NAME"
