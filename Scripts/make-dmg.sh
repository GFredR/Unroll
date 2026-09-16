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
#   VERSION=1.0.1           覆盖版本号(默认取 project.yml)
#   SKIP_FINDER_LAYOUT=1    跳过 Finder 窗口布局(无人值守/CI 场景用 —— 该步骤会
#                           走 AppleScript 驱动 Finder,可能弹自动化授权框)
#
# 为什么不再用「staging 目录 + hdiutil create -srcfolder」(2026-09-16 改):
#   旧做法要在磁盘上 cp -R 出一份完整 .app、用完再 rm -rf 掉 —— 一次发布写两遍、
#   再删一遍上百个文件。改成「先建空的读写镜像 → 挂载 → ditto 拷进去」后:
#     · 不再有「删除一棵上百文件的目录」这个动作。这不只是省事:批量删除在受限
#       环境里会被安全守卫拦下(实测 SAFE_DELETE_BULK_CONFIRM_REQUIRED,EXIT=1),
#       而这条 rm 纯粹是自扫门前雪,不该成为发布链的失败点;
#     · App 只写一遍;
#     · 多出一个新校验位:拷进镜像后签名还在不在(见第 6 步)。
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
VOL_NAME="$APP_NAME $VERSION"
TEMP_DMG="$DIST_DIR/temp-${DMG_NAME}"

# 1. 先确保 .app 存在
if [ ! -d "$APP_DIR" ]; then
  echo "→ $APP_DIR 不存在,先构建"
  ./Scripts/build-app.sh
fi

# 1.2 读 .app 的 buildinfo:本次打包的 App 属于哪个提交
#     之所以不让 dmg 侧车自己去问 git:dmg 里装的是**这份 .app**,而不是「当前源码」。
#     两者在「只重建了 app 没重建 dmg」或反过来时会分叉,而分叉正是要抓的东西。
APP_BUILDINFO="$DIST_DIR/$APP_NAME.buildinfo"
if [ -f "$APP_BUILDINFO" ]; then
  APP_COMMIT="$(sed -n 's/^commit=//p' "$APP_BUILDINFO" | head -1)"
  APP_DIRTY="$(sed -n 's/^dirty=//p' "$APP_BUILDINFO" | head -1)"
  APP_COMMIT="${APP_COMMIT:-unknown}"
  APP_DIRTY="${APP_DIRTY:-1}"
else
  echo "  ! 缺 $APP_NAME.buildinfo —— 无法确认这份 App 来自哪个提交" >&2
  echo "    先重跑 ./Scripts/build-app.sh(旧版脚本不写侧车文件)" >&2
  APP_COMMIT="unknown"
  APP_DIRTY=1
fi

# 1.5 清场:同名卷若还挂着,后面的 attach / convert 会互相打架
#     (2026-09-14 实测:残留卷占着同名临时镜像 → convert 报「资源暂时不可用」)
RESIDUAL="$(mount | grep -F "on /Volumes/$VOL_NAME " | awk '{print $1}' || true)"
if [ -n "$RESIDUAL" ]; then
  echo "→ 卸载残留卷 $RESIDUAL"
  hdiutil detach "$RESIDUAL" > /dev/null || hdiutil detach -force "$RESIDUAL" > /dev/null
fi
rm -f "$TEMP_DMG"

# 2. 建一个空的读写镜像(同样是 HFS+,与旧 -srcfolder 产物同格式,便于比对)
#    注意:这里**不能**写 -format UDRW —— 一旦显式给了 -format,hdiutil 就要求
#    必须有 -srcfolder/-srcdevice(实测报「-format requires -srcfolder」)。
#    不带 -format 时默认产出的正是 UDRW(可用 hdiutil imageinfo 复核)。
echo "→ 创建临时读写镜像"
VOL_SIZE_MB=$(( $(du -sm "$APP_DIR" | awk '{print $1}') + 25 ))
hdiutil create -ov -fs HFS+ -size "${VOL_SIZE_MB}m" \
  -volname "$VOL_NAME" "$TEMP_DMG" > /dev/null

# 3. 挂载并把 App 拷进去
#    ditto 而不是 cp -R:Apple 官方推荐的 bundle 拷贝方式,完整保留扩展属性
echo "→ 挂载并拷入 App"
ATTACH_OUT="$(hdiutil attach -readwrite -noverify "$TEMP_DMG")"
DEVICE="$(printf '%s' "$ATTACH_OUT" | grep -o '/dev/disk[0-9]*' | head -1 || true)"
MOUNT_POINT="$(printf '%s' "$ATTACH_OUT" | grep -o '/Volumes/.*' | head -1 || true)"
if [ -z "$DEVICE" ] || [ -z "$MOUNT_POINT" ]; then
  echo "  ✗ 无法挂载临时镜像,放弃" >&2
  exit 1
fi
ditto "$APP_DIR" "$MOUNT_POINT/$APP_NAME.app"
ln -s /Applications "$MOUNT_POINT/Applications"

# 4. Finder 窗口布局(失败不阻塞 —— 布局只是观感,**但不能悄悄失败**)
#
# 为什么这里要显式判成败:布局靠 AppleScript 驱动 Finder,而 AppleScript 依赖
# 系统「自动化」授权。授权缺失时 osascript 会**直接失败**,旧写法 `|| true` 把它
# 连人带话一起吞掉 —— 脚本照旧打印「→ 设置 Finder 窗口布局」,产物却根本没布局,
# 属于典型的沉默故障(2026-09-16 实测踩到:一度以为布局做了,其实是 .DS_Store 兜住了)。
# 判据用 `.DS_Store`:Finder 把图标位置/窗口几何写在这里,它不在就说明没落盘。
LAYOUT_OK=0
if [ "${SKIP_FINDER_LAYOUT:-0}" != "1" ]; then
  echo "→ 设置 Finder 窗口布局"
  if osascript <<EOF
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
  then
    sleep 1 # Finder 写 .DS_Store 是异步的,给它一拍
    # 注意:这里不能写成 `[ -f F ] && LAYOUT_OK=1` —— 条件为假时整条 AND-OR
    # 列表返回 1,在 `set -e` 下会直接**终止脚本**(实测过的坑)
    if [ -f "$MOUNT_POINT/.DS_Store" ]; then LAYOUT_OK=1; fi
  fi
  if [ "$LAYOUT_OK" = "1" ]; then
    echo "  布局    : 已写入 .DS_Store ✓"
  else
    echo "  ! Finder 布局未生效 —— dmg 打开时图标是默认排列、窗口是默认尺寸" >&2
    echo "    仍可正常拖动安装,只是观感打折。原因通常是当前终端没有「自动化」权限:" >&2
    echo "    系统设置 → 隐私与安全性 → 自动化,放行后再跑一次即可。" >&2
  fi
fi

# 4b. 把 .fseventsd 藏起来
#     它是**挂载时由系统自动创建**的、不带 hidden 标志的普通文件夹。绝大多数人
#     看不到(点号开头默认隐藏),但开了「显示隐藏文件」的人会看到卷里多一个突兀
#     的目录 —— 实测本机 AppleShowAllFiles=1 时它就明晃晃地显示在窗口第一行。
chflags hidden "$MOUNT_POINT/.fseventsd" 2>/dev/null || true

# 5. 卸载,再压成只读压缩镜像
echo "→ 压缩为最终 dmg"
hdiutil detach "$DEVICE" > /dev/null || hdiutil detach -force "$DEVICE" > /dev/null
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DIST_DIR/$DMG_NAME" > /dev/null
rm -f "$TEMP_DMG"

# 6. 挂载校验:能否挂上、内容是否齐全、签名有没有在打包途中坏掉
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
  # QuickLook 扩展必须真的在包里:装完从 dmg 拖进 /Applications 的人不会去查
  # PlugIns,少一个扩展的后果是「Finder 空格没反应」——没人会想到是安装包的问题
  APPEX_COUNT="$(find "$MOUNT_OUT/$APP_NAME.app/Contents/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${APPEX_COUNT:-0}" -lt 2 ]; then
    echo "  ✗ dmg 内的 App 只带 $APPEX_COUNT 个扩展(期望 2:缩略图 + 预览)" >&2
    hdiutil detach "$MOUNT_OUT" > /dev/null || true
    exit 1
  fi
  echo "  扩展    : $APPEX_COUNT 个 appex ✓"
  # 签名必须活过「拷进镜像 → 压缩 → 挂回来」这一路。坏在这里的表现是
  # 「装完能开,但扩展/文件关联不生效」,几乎没人会往打包环节想,所以钉住
  if codesign --verify --strict "$MOUNT_OUT/$APP_NAME.app" 2>/dev/null; then
    echo "  签名    : 打包后 --verify --strict 通过 ✓"
  else
    echo "  ✗ dmg 内的 App 签名校验失败(打包过程破坏了签名)" >&2
    hdiutil detach "$MOUNT_OUT" > /dev/null || true
    exit 1
  fi
  # 产物↔源码绑定:读**镜像里**那个 App 的 Info.plist,确认它就是 .app 侧车描述的提交。
  # 特意从镜像里读而不是从 $APP_DIR 读 —— 将来打开这个 dmg 的人只能看到镜像里的东西,
  # 「源目录里是对的」不能证明「打进去的是对的」。
  GOT_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :UnrollSourceCommit' \
                "$MOUNT_OUT/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo '(缺)')"
  if [ "$APP_COMMIT" = "unknown" ]; then
    echo "  ! 镜像内 App 提交号 $GOT_COMMIT(无侧车可比,无法确认)" >&2
  elif [ "$GOT_COMMIT" != "$APP_COMMIT" ]; then
    echo "  ✗ 镜像内 App 的提交号与侧车不符:镜像=$GOT_COMMIT,侧车=$APP_COMMIT" >&2
    echo "    dmg 里装的不是侧车描述的那份 App —— 重跑 build-app.sh && make-dmg.sh" >&2
    hdiutil detach "$MOUNT_OUT" > /dev/null || true
    exit 1
  else
    echo "  源码提交: ${GOT_COMMIT:0:7} ✓(与侧车一致)"
  fi
  # 布局与观感只影响「打开 dmg 的第一眼」,但第一眼正是下载者唯一会给的注意力。
  # 两条都只警告不失败:产物本身是好的,只是观感打折,不该因此中断发布。
  if [ -f "$MOUNT_OUT/.DS_Store" ]; then
    echo "  布局    : 图标布局已随镜像发布"
  else
    echo "  ! 镜像内没有 .DS_Store —— 打开 dmg 时图标为默认排列(仍可正常拖装)" >&2
  fi
  FSEV_FLAGS="$(ls -ldO "$MOUNT_OUT/.fseventsd" 2>/dev/null | awk '{print $5}' || true)"
  case "$FSEV_FLAGS" in
    *hidden*) echo "  观感    : .fseventsd 已隐藏" ;;
    *)        echo "  ! .fseventsd 未隐藏 —— 开了「显示隐藏文件」的人会看到卷里多一个目录" >&2 ;;
  esac
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

# 9. dmg 侧车:发布前检只读这一份,它是「产物↔源码」链的最后一环。
#    为什么侧车里要钉住 dmg 自己的 SHA256:这是唯一能识破
#    「源码没变 / 侧车是旧的 / DMG 其实也被换过」的判据。任何一次重建都会产生
#    新哈希,而旧侧车里写的是旧哈希 —— 两者对不上就说明侧车不是这份产物的。
DMG_SHA="$(awk '{print $1}' "$DIST_DIR/$DMG_NAME.sha256")"
{
  echo "app=$APP_NAME"
  echo "version=$VERSION"
  echo "commit=$APP_COMMIT"
  echo "dirty=$APP_DIRTY"
  echo "dmg=$DMG_NAME"
  echo "dmg_sha256=$DMG_SHA"
  echo "built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$DIST_DIR/$DMG_NAME.buildinfo"

echo ""
echo "✓ 生成 $DIST_DIR/$DMG_NAME ($DMG_SIZE)"
echo "  → SHA256: $DIST_DIR/$DMG_NAME.sha256"
echo "  → buildinfo: $DIST_DIR/$DMG_NAME.buildinfo(commit ${APP_COMMIT:0:7} / dirty=$APP_DIRTY)"
echo "  → open $DIST_DIR/$DMG_NAME"
