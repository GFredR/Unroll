#!/bin/bash
# ============================================================================
# verify-ui.sh —— 界面验收自动取证(空态 / 阅读窗口 / 密码界面 / 崩溃询问 / dmg 布局)
# ----------------------------------------------------------------------------
# 用法:
#   ./Scripts/verify-ui.sh                 # 拍全套截图到 docs/
#   OUT_DIR=/tmp/shots ./Scripts/verify-ui.sh
#   APP=/path/to/Unroll.app ./Scripts/verify-ui.sh    # 换被测的 .app
#   ONLY=password ./Scripts/verify-ui.sh              # 只跑某一段(all|empty|reader|password|crash|dmg)
#
# 为什么要有这个脚本:
#   交付前有几处只能靠"看"来判定的东西 —— 空态长什么样、加密归档的密码框长什么样、
#   崩溃询问弹窗的文案与按钮、dmg 打开后的图标排列。过去它们被记成"需要人眼确认",
#   于是要么拖着不做,要么临发布才想起来。但其中**能被拍下来**的部分完全可以自动做掉:
#   脚本负责"拍到正确的那一帧",人只负责"看一眼对不对"。
#   密码界面这一段还有一层作用:README 的头图就是它,一张一条命令就能重拍,
#   文档里的图才不会悄悄停在上一版的界面上(2026-09-17 撞上过)。
#
# 拍不出来、必须人判断的:文案是否得体、图标间距是否好看。脚本不假装覆盖这些。
#
# 前置:终端需要「屏幕录制」权限(截图)与「自动化」权限(驱动 Finder)。
#       缺权限时对应段落会明确报错,不会静默跳过。
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Unroll"
VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}-dist}"
APP="${APP:-$DIST_DIR/$APP_NAME.app}"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/docs}"
ONLY="${ONLY:-all}"

SUPPORT_DIR="$HOME/Library/Containers/com.gfredr.unroll/Data/Library/Application Support/Unroll"
SESSION="$SUPPORT_DIR/session.json"
# 目录可能还不存在(App 从未在本机跑过,或容器被清理过)—— 不先建好,
# 下面写 session 会报 "No such file or directory"(2026-09-16 实测踩到)
mkdir -p "$SUPPORT_DIR"

FAILED=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*" >&2; FAILED=$((FAILED + 1)); }
info() { echo "  · $*"; }
head2(){ echo ""; echo "── $* ─────────────────────────────────────"; }

# ---------------------------------------------------------------- 环境自检 --
head2 "环境自检"

if [ ! -d "$APP" ]; then
    bad "找不到被测的 .app:$APP(先跑 Scripts/build-app.sh,或用 APP= 指定)"
    exit 2
fi
ok "被测 App:$APP($(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1))"

mkdir -p "$OUT_DIR"

# 屏幕录制权限:没有它 screencapture 会产出空图或干脆不写文件。
# 两处实测坑:① 文件名**不能以点开头** —— screencapture 会报
# "cannot write file to intended destination" 且**退出码仍是 0**;
# ② 正因为它用退出码骗人,判据只能是"文件是否真的非空",不能信 rc。
PROBE=/tmp/verify-ui-probe.png
rm -f "$PROBE"
screencapture -x -R1,1,40,40 "$PROBE" 2>/dev/null || true
if [ ! -s "$PROBE" ]; then
    bad "截屏不可用 —— 本终端缺「屏幕录制」权限"
    info "系统设置 → 隐私与安全性 → 屏幕录制,勾选后重启终端"
    exit 2
fi
ok "截屏可用"
rm -f "$PROBE"

# 窗口枚举小工具:编译一次,循环里反复用(swift 直跑每轮要多花约 1 秒)
WINID=/tmp/verify-ui-winid
swiftc -O -o "$WINID" Scripts/winid.swift 2>/dev/null || { bad "winid.swift 编译失败"; exit 2; }
ok "窗口枚举工具就绪"

unroll_windows() { "$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" {print $1"\t"$4}'; }

quit_app() {
    for p in $(pgrep -x "$APP_NAME" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
    sleep 2
}

# 复位会话标记:alive=false 且清掉 suppressedVersion。
# 不这么做的话,脚本会给用户留下一次**假的**"上次异常退出"。
reset_session() {
    local boot
    boot="$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+), usec = ([0-9]+).*/\1.\2/')"
    printf '{"alive":false,"version":"%s","build":"%s","bootTime":%s}' \
        "$VERSION" "$VERSION" "$boot" > "$SESSION"
}
trap 'reset_session 2>/dev/null || true' EXIT

# ------------------------------------------------------------------ 空态 --
if [ "$ONLY" = "all" ] || [ "$ONLY" = "empty" ]; then
    head2 "空态窗口"
    quit_app
    reset_session
    open -a "$APP"
    sleep 3
    ID="$(unroll_windows | head -1 | cut -f1)"
    if [ -z "$ID" ]; then
        bad "App 启动后找不到主窗口"
    else
        screencapture -l"$ID" -x -o "$OUT_DIR/shot-empty-state.png" 2>/dev/null
        if [ -s "$OUT_DIR/shot-empty-state.png" ]; then
            ok "shot-empty-state.png"
        else
            bad "空态截图失败"
        fi
    fi
fi

# ------------------------------------------------------- 阅读窗口 / 标题 --
if [ "$ONLY" = "all" ] || [ "$ONLY" = "reader" ]; then
    head2 "阅读窗口 · 标题带文件名与页码"
    FIXTURE="$ROOT_DIR/ArchiveKit/Tests/Fixtures/plain.cbz"
    if [ ! -f "$FIXTURE" ]; then
        bad "找不到 fixture:$FIXTURE"
    else
        quit_app
        reset_session
        # 用系统「打开方式」把归档交给自己 —— 沙盒授权由系统一并给出,
        # 这条路与用户双击文件完全同构
        open -a "$APP" "$FIXTURE"
        sleep 4
        # 窗口标题能直接读到,所以这一项是**机器判据**,不需要人看图
        TITLE="$("$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" {print $3; exit}')"
        if [ -z "$TITLE" ]; then
            bad "拿不到窗口标题(读窗口名需要「屏幕录制」权限)"
        else
            case "$TITLE" in
                *plain.cbz*) ok "标题含文件名:$TITLE" ;;
                *) bad "标题不含文件名:«$TITLE»" ;;
            esac
            if printf '%s' "$TITLE" | grep -qE 'P\.[0-9]+/[0-9]+'; then
                ok "标题含页码 —— Window 菜单 / Dock 悬停能分辨读到哪"
            else
                bad "标题不含页码:«$TITLE»"
            fi
        fi
        ID="$(unroll_windows | head -1 | cut -f1)"
        if [ -n "$ID" ]; then
            screencapture -l"$ID" -x -o "$OUT_DIR/shot-reader-window.png" 2>/dev/null
            [ -s "$OUT_DIR/shot-reader-window.png" ] && ok "shot-reader-window.png"
        fi
    fi
fi

# --------------------------------------------- 加密归档 · 密码输入界面 --
# v1.0.1 新增能力。README 里那张头图就是它,所以必须能一条命令重拍 ——
# 否则功能一改,文档里的图就悄悄变成上一版的界面(2026-09-17 实测撞上:
# 图上还写着"当前版本暂不支持输入密码",而标题却在讲"给出密码入口")。
if [ "$ONLY" = "all" ] || [ "$ONLY" = "password" ]; then
    head2 "加密归档 · 密码输入(v1.0.1 新增)"

    # ⚠️ 语言覆盖的关键前提:**App 必须尚未运行**。
    # LaunchServices 只在新实例启动时把 argv 交给 App;已有实例在跑时 `--args`
    # 会被静默丢掉 —— 这正是"open --args 传不进 App"这个印象的来源。
    # 2026-09-17 复测:先 quit_app 再传,语言确实切过去了(LANG 用 --args 传,
    # 归档仍走 `open -a` 交给同一个实例,沙盒授权随打开事件一并给出)。
    #
    # 窗口标题在这一阶段就是 App 显示名(开卷 / Unroll),所以"语言有没有真的
    # 切过去"是**机器判据** —— 不做这一步的话,切换失败会把一张中文图悄悄
    # 存进英文槽位,而脚本全绿。
    shoot_password() {  # $1=语言  $2=输出文件名  $3=期望的窗口标题
        local lang="$1" out="$2" want_title="$3"
        local fixture="$ROOT_DIR/ArchiveKit/Tests/Fixtures/encrypted-zip.cbz"
        if [ ! -f "$fixture" ]; then
            bad "找不到 fixture:$fixture"
            return
        fi
        quit_app
        reset_session
        sleep 1
        open -a "$APP" --args -AppleLanguages "($lang)"
        sleep 2
        open -a "$APP" "$fixture"
        sleep 3

        local title
        title="$("$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" {print $3; exit}')"
        if [ -z "$title" ]; then
            bad "$lang:打开加密归档后找不到窗口"
            return
        fi
        if [ "$title" != "$want_title" ]; then
            bad "$lang:窗口标题是 «${title}»,期望 «${want_title}» —— 语言没切过去,拍出来的会是另一种语言的图"
            return
        fi
        # ⚠️ 变量后面紧跟中文/书名号这类多字节字符时**必须写 ${var}**:
        # UTF-8 locale 下 bash 会把多字节字符的首字节当成变量名的一部分
        # (`$title»` → 变量名变成 `title»`),`set -u` 于是报 "unbound variable"。
        # 2026-09-17 实测撞上,报错信息里那个变量名还带着一个乱码字节。
        ok "$lang:标题 «${title}» —— 语言已生效"

        local id
        id="$(unroll_windows | head -1 | cut -f1)"
        rm -f "$OUT_DIR/$out"
        screencapture -l"$id" -x -o "$OUT_DIR/$out" 2>/dev/null
        if [ -s "$OUT_DIR/$out" ]; then
            ok "$out"
        else
            bad "$lang:截图失败"
        fi
    }

    shoot_password zh-Hans shot-encrypted.png    开卷
    shoot_password en      shot-encrypted-en.png Unroll
fi

# ------------------------------------------------------------- 崩溃询问 --
if [ "$ONLY" = "all" ] || [ "$ONLY" = "crash" ]; then
    head2 "崩溃询问弹窗"

    # 人为制造一次"异常退出":强杀不会写 alive=false,正是真实的崩溃残留形态
    quit_app
    BOOT="$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+), usec = ([0-9]+).*/\1.\2/')"
    printf '{"alive":true,"version":"%s","build":"%s","bootTime":%s}' \
        "$VERSION" "$VERSION" "$BOOT" > "$SESSION"
    info "已注入异常退出残留(alive=true)"

    open -a "$APP"
    # 弹窗在启动后 1.5s 出现,且实测只停留很短时间 —— 必须高频轮询,
    # 只在窗口集合**发生变化**的那一拍抓图,既不漏帧也不刷屏
    FOUND=""
    PREV=""
    for i in $(seq 1 24); do
        SNAP="$(unroll_windows)"
        SIG="$(printf '%s' "$SNAP" | tr '\n' ';')"
        if [ "$SIG" != "$PREV" ] && [ -n "$SIG" ]; then
            # 弹窗是独立的小面板:同进程里尺寸明显更小的那个
            ALERT_ID="$(printf '%s\n' "$SNAP" | awk -F'\t' '
                { split($2, a, "x"); if (a[1] + 0 > 0 && (min == 0 || a[1] + 0 < min)) { min = a[1]+0; id = $1 } }
                END { print id }')"
            COUNT="$(printf '%s\n' "$SNAP" | grep -c .)"
            if [ "${COUNT:-0}" -ge 2 ] && [ -n "$ALERT_ID" ]; then
                screencapture -l"$ALERT_ID" -x -o "$OUT_DIR/shot-crash-prompt.png" 2>/dev/null
                [ -s "$OUT_DIR/shot-crash-prompt.png" ] && FOUND="$ALERT_ID"
            fi
        fi
        PREV="$SIG"
        [ -n "$FOUND" ] && break
        sleep 0.4
    done

    if [ -n "$FOUND" ]; then
        ok "shot-crash-prompt.png(弹窗窗口 id=$FOUND)"
    else
        bad "没抓到崩溃询问弹窗"
        info "可能原因:suppressedVersion 已是当前版本(同版本不再询问)"
        info "检查:$SESSION"
    fi

    # 免打扰:用户拒绝后同一版本不该再问第二次
    head2 "崩溃询问 · 免打扰"
    quit_app
    SUPPRESSED="$(sed -n 's/.*"suppressedVersion":"\([^"]*\)".*/\1/p' "$SESSION" 2>/dev/null)"
    if [ -z "$SUPPRESSED" ]; then
        # 没人点过弹窗时**自己注入** suppressedVersion,而不是干等。
        # 分工:「取消按钮 → 写 suppressedVersion」由 CrashReporterTests 单测覆盖;
        # 这里要验的是端到端行为 —— 标了 suppressed 之后系统是不是真的不再问。
        # 靠人手点的话,这一项就永远停在"等人",等于没验。
        info "弹窗未被处理过 —— 注入 suppressedVersion=$VERSION 后验证"
        BOOT2="$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+), usec = ([0-9]+).*/\1.\2/')"
        printf '{"alive":true,"version":"%s","build":"%s","bootTime":%s,"suppressedVersion":"%s"}' \
            "$VERSION" "$VERSION" "$BOOT2" "$VERSION" > "$SESSION"
        SUPPRESSED="$VERSION"
    fi
    open -a "$APP"
    AGAIN=""
    for i in $(seq 1 12); do
        [ "$(unroll_windows | grep -c .)" -ge 2 ] && AGAIN="yes"
        sleep 0.4
    done
    if [ -z "$AGAIN" ]; then
        ok "同版本($SUPPRESSED)不再弹窗 —— 免打扰生效"
    else
        bad "suppressedVersion=$SUPPRESSED 时仍然弹窗了"
    fi
fi

# --------------------------------------------------------------- dmg 布局 --
if [ "$ONLY" = "all" ] || [ "$ONLY" = "dmg" ]; then
    head2 "dmg 图标布局"

    if [ ! -f "$DMG" ]; then
        bad "找不到 $DMG(先跑 Scripts/make-dmg.sh)"
    else
        # 先卸干净同名残留卷,否则 hdiutil 会挂到 " 1" 之类的名字上,后面找不到
        for V in /Volumes/"$APP_NAME"*; do
            [ -d "$V" ] && hdiutil detach "$V" >/dev/null 2>&1
        done
        MOUNT="$(hdiutil attach -readonly -noverify "$DMG" 2>/dev/null | grep -o '/Volumes/.*' | head -1 || true)"
        if [ -z "$MOUNT" ]; then
            bad "dmg 挂载失败"
        else
            ok "已挂载:$MOUNT"
            if [ -f "$MOUNT/.DS_Store" ]; then
                ok "镜像内含 .DS_Store(图标布局已随发布物下发)"
            else
                bad "镜像内没有 .DS_Store —— 打开 dmg 时图标是默认排列"
                info "在授予「自动化」权限的终端里重跑 Scripts/make-dmg.sh"
            fi
            FSEV="$(ls -ldO "$MOUNT/.fseventsd" 2>/dev/null | awk '{print $5}' || true)"
            case "$FSEV" in
                *hidden*) ok ".fseventsd 已隐藏" ;;
                *) bad ".fseventsd 未隐藏 —— 开了「显示隐藏文件」的人会看到它" ;;
            esac

            open "$MOUNT"
            sleep 4
            FID="$("$WINID" 访达 2>/dev/null | awk -F'\t' -v v="$APP_NAME" '$3 ~ v {print $1; exit}')"
            if [ -n "$FID" ]; then
                screencapture -l"$FID" -x -o "$OUT_DIR/shot-dmg-layout.png" 2>/dev/null
                [ -s "$OUT_DIR/shot-dmg-layout.png" ] && ok "shot-dmg-layout.png"
            else
                bad "找不到 dmg 的访达窗口(可能需要「自动化」权限)"
            fi
            hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1
        fi
    fi
fi

# ------------------------------------------------------------------ 收尾 --
quit_app
reset_session

head2 "结论"
if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "✗ 有 $FAILED 项未通过。"
    exit 1
fi
echo "  ✓ 全部通过"
echo ""
echo "截图在 $OUT_DIR:"
ls -1 "$OUT_DIR"/shot-*.png 2>/dev/null | sed 's/^/    /'
echo ""
echo "脚本能保证的是「拍到的就是那一帧」;下面这些仍要你自己看一眼:"
echo "    · 崩溃询问的文案读起来会不会太硬"
echo "    · 空态的三个元素(AppIcon / 说明 / 打开按钮)是否协调"
echo "    · dmg 里两个图标的位置关系是否符合直觉(左 App 右 Applications)"
echo "    · HUD 的进度条拖起来跟不跟手(拖动中页码跟着变,松手才跳页)"
echo "    · 「文件 → 另存当前页…」存出来的图与屏幕上看到的一致(双页应是一整摊)"
echo "    · 静止 2.5s 后光标是否一起隐藏、动一下就回来"
