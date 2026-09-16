#!/bin/bash
# ============================================================================
# verify-quicklook.sh —— QuickLook 扩展的「真机验收」(2026-09-16)
# ----------------------------------------------------------------------------
# 为什么需要单独一个脚本:
#   QuickLook appex 由系统(quicklookd)按需拉起,**无法在受限环境里验证** ——
#   AI 的沙箱里连 `pluginkit -m` 查询都会被拒(PKDiscovery 未授权),
#   `qlmanage` 直接报 sandbox initialization failed,`log show` 也拒绝运行。
#   所以「扩展到底会不会被系统调用」这一环只能在你的正常终端里跑本脚本。
#
# 脚本能覆盖的边界(与单测分工明确,不重叠):
#   · 单测(UnrollQuickLookTests)  → 扩展的决策逻辑:明文/加密/损坏/降采样上限
#   · 本脚本                      → appex 管道:系统能否发现、加载、路由 cbz 过来
#   · build-app.sh 的硬校验        → Info.plist 声明 / 架构 / 嵌套签名
#
# 用法:
#   Scripts/verify-quicklook.sh               # 只注册 + 校验(不装 App)
#   Scripts/verify-quicklook.sh --install     # 先装到 /Applications 再校验
#
# ⚠️ 必须在**普通终端**里跑,不要经由 AI 沙箱执行,否则必然误报失败。
# ============================================================================
set -uo pipefail   # 刻意不设 -e:要跑完全部检查再汇总,不能第一条失败就退出
cd "$(dirname "$0")/.."
REPO="$PWD"
DIST="$REPO/../Unroll-dist"
APP="$DIST/Unroll.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

SAMPLE_SRC="$REPO/ArchiveKit/Tests/Fixtures/plain.cbz"
WORK=$(mktemp -d /tmp/unroll-ql-verify.XXXXXX)
SAMPLE="$WORK/sample.cbz"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; warn=0
ok()   { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  ⚠️  %s\n' "$1"; warn=$((warn+1)); }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
head2 "0. 环境自检(在沙箱里跑会全军覆没,先拦下来)"
if /usr/bin/log show --last 1s >/dev/null 2>&1; then
    ok "非沙箱环境(log 可运行)"
else
    bad "当前环境受限(log 拒绝运行)—— 请在普通终端重跑本脚本"
    printf '\n  检测到沙箱/受限环境,后续检查无意义,提前退出。\n'
    exit 2
fi

if [ ! -d "$APP" ]; then
    bad "找不到 $APP —— 先跑 Scripts/build-app.sh"
    exit 2
fi
ok "找到构建产物 Unroll.app"

# ---------------------------------------------------------------------------
head2 "1. 扩展是否嵌入(Contents/PlugIns/)"
for A in UnrollQuickLookThumbnail UnrollQuickLookPreview; do
    if [ -d "$APP/Contents/PlugIns/$A.appex" ]; then
        ok "$A.appex 已嵌入"
    else
        bad "$A.appex 缺失 —— Finder 空格会毫无反应,且不报错"
    fi
done

# ---------------------------------------------------------------------------
head2 "2. 嵌套签名(内层 appex 先签,外层 App 后签)"
for A in UnrollQuickLookThumbnail UnrollQuickLookPreview; do
    if codesign --verify --strict "$APP/Contents/PlugIns/$A.appex" 2>/dev/null; then
        ok "$A.appex 签名有效"
    else
        bad "$A.appex 签名无效"
    fi
done
if codesign --verify --strict "$APP" 2>/dev/null; then
    ok "Unroll.app 签名有效(含 PlugIns 递归校验)"
else
    bad "Unroll.app 签名无效 —— 多半是签名顺序反了(appex 必须在 App 之前签)"
fi

# ---------------------------------------------------------------------------
head2 "3. 安装到 /Applications(可选)"
if [ "${1:-}" = "--install" ]; then
    if [ -w /Applications ]; then
        rm -rf /Applications/Unroll.app
        cp -R "$APP" /Applications/
        APP=/Applications/Unroll.app
        ok "已安装到 /Applications/Unroll.app"
    else
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/Unroll.app"
        cp -R "$APP" "$HOME/Applications/"
        APP="$HOME/Applications/Unroll.app"
        note "/Applications 不可写,改装到 ~/Applications"
    fi
else
    note "未传 --install,沿用 $APP(LaunchServices 对非 /Applications 路径的扩展有时不加载)"
fi

# ---------------------------------------------------------------------------
head2 "4. 向 LaunchServices 注册"
"$LSREG" -f "$APP" 2>/dev/null
if "$LSREG" -dump 2>/dev/null | grep -q "com.gfredr.unroll.quicklook.thumbnail"; then
    ok "LaunchServices 已收录缩略图扩展"
else
    bad "LaunchServices 没有收录扩展"
fi

# ---------------------------------------------------------------------------
head2 "5. PlugInKit 注册与启用状态(这是「系统会不会调用它」的关键)"
for ID in com.gfredr.unroll.quicklook.thumbnail com.gfredr.unroll.quicklook.preview; do
    LINE=$(pluginkit -m -i "$ID" 2>/dev/null | head -1)
    # pluginkit 用首字符表状态:+ 已启用 / - 被禁用
    MARK=$(printf '%s' "$LINE" | cut -c1)
    if [ -z "$LINE" ]; then
        bad "$ID 未注册 —— 系统不会把 cbz 路由给它"
    elif [ "$MARK" = "-" ]; then
        bad "$ID 处于**被禁用**状态 → 系统设置 → 通用 → 登录项与扩展 → 快速查看,打开它"
    else
        ok "$ID 已注册且启用  [$LINE]"
    fi
done

# ---------------------------------------------------------------------------
head2 "6. 端到端:让系统真去生成 cbz 缩略图"
if [ ! -f "$SAMPLE_SRC" ]; then
    bad "缺少样本 $SAMPLE_SRC"
else
    cp "$SAMPLE_SRC" "$SAMPLE"
    printf '  · 样本 %s (%s 字节)\n' "$SAMPLE" "$(stat -f%z "$SAMPLE")"
    printf '  · 系统认定的 UTI: %s\n' "$(mdls -name kMDItemContentType -raw "$SAMPLE" 2>/dev/null || echo '?')"

    OUT="$WORK/out"; mkdir -p "$OUT"
    if qlmanage -t -s 512 -o "$OUT" "$SAMPLE" >/dev/null 2>&1 && [ -f "$OUT/sample.cbz.png" ]; then
        W=$(sips -g pixelWidth  "$OUT/sample.cbz.png" 2>/dev/null | awk '/pixelWidth/{print $2}')
        H=$(sips -g pixelHeight "$OUT/sample.cbz.png" 2>/dev/null | awk '/pixelHeight/{print $2}')
        ok "系统生成了缩略图: ${W}x${H}px"
        # 判别「是我们的封面」还是「系统通用图标」:fixture 首页是 3:4 竖版,
        # 通用图标是正方形。这一条正是本次要回答的问题
        if [ -n "$W" ] && [ -n "$H" ] && [ "$H" -gt "$W" ]; then
            ok "竖版比例 → 来自我们的扩展(fixture 首页 240x320),不是系统通用图标"
        else
            bad "方形/非竖版 → 仍是系统通用图标,扩展没有被调用(见下方排查)"
        fi
    else
        bad "系统没能为 cbz 生成缩略图 —— 扩展未被路由"
    fi
fi

# ---------------------------------------------------------------------------
head2 "7. 人工确认(脚本验不了,只能眼睛看)"
cat <<'EOF'
  · Finder 里找一个 .cbz,图标应直接显示封面(不是压缩包通用图标)
  · 选中它按空格:出现预览面板,显示首页 + 「共 N 页」
  · 加密归档:预览应显示锁图标 + 说明,缩略图应退回默认图标(不挂占位图)
EOF

printf '\n────────────────────────────────────────────\n'
printf '结果: %d 通过 / %d 失败 / %d 提示\n' "$pass" "$fail" "$warn"
if [ "$fail" -gt 0 ]; then
    cat <<'EOF'

排查顺序(按命中率从高到低):
  1. 扩展被禁用 → 系统设置 → 通用 → 登录项与扩展 → 快速查看,找到 Unroll 打开
  2. App 不在 /Applications → 重跑本脚本加 --install
  3. pluginkit 缓存旧 → pluginkit -r <appex路径> 后重跑本脚本
  4. 签名是 ad-hoc(TeamIdentifier=not set)→ 部分系统版本会拒绝加载第三方扩展,
     需要 Developer ID 签名 + 公证;可用 `codesign -dv --verbose=4 <appex>` 查看
EOF
    exit 1
fi
printf '✅ QuickLook 扩展在真机上工作正常\n'
