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

# 位置参数一律拒绝。ONLY= / APP= / OUT_DIR= 都是**环境变量**,得写在命令前面:
#   ONLY=grid APP=<Debug.app> ./Scripts/verify-ui.sh
# 写成 `./Scripts/verify-ui.sh ONLY=grid` 时它只被当成位置参数,脚本一个字都不读,
# 于是**静默跑全套**。2026-09-20 实测撞了两次(第二次是在 `time (...)` 里),
# 两次都看到"输出了 7 个段落却以为只有一个"。"以为只跑了一段、其实跑了全部"
# 属于最坏的一类误导:它不会报错,只会让结论对不上号。宁可当场拦下。
if [ "$#" -gt 0 ]; then
    echo "✗ 不接受位置参数:$*" >&2
    echo "  这几个是环境变量,要写在命令**前面**:" >&2
    echo "    ONLY=<段名> APP=<.app> OUT_DIR=<目录> $0" >&2
    echo "  段名:all | empty | reader | password | crash | dmg | grid | jump" >&2
    echo "  (grid / jump 需要可驱动的 Debug 版,见文末说明)" >&2
    exit 2
fi

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

# ------------------------------------------------------- 界面语言(2026-09-18) --
# 机制:`-AppleLanguages "(en)"` 作为**命令行参数**交给 App。它生效是因为
# NSUserDefaults 的 **argument domain** 优先级最高 —— 不是碰巧,也不是黑魔法。
# 判据用窗口标题(这一阶段标题就是 App 显示名),2026-09-18 实测三组对照:
#
#   基线  不传参数                        → «开卷»(系统语言)
#   A    --args -AppleLanguages "(en)"   → «Unroll»   ← 参数确实进了 argv,
#                                                       `ps -ww -o command=` 可见
#   C    容器偏好写 zh-Hans + args 传 en  → «Unroll»   ← args 压过偏好
#
# ⚠️ 唯一的前提:**App 必须尚未运行**。LaunchServices 只把 argv 交给**新**实例;
# 已有实例在跑时参数被静默丢弃(不报错,界面悄悄退回系统语言)—— 所以
# shoot_password 里 `quit_app` 必须在带 `--args` 那次 `open` **之前**,顺序不能调。
# 这也正是那里那道标题断言存在的理由:参数被丢弃时断言当场拦下,而不是把一张
# 中文图悄悄存进英文槽位。
#
# 备选做法(已试,不用):把 AppleLanguages 写进容器偏好
# ($HOME/Library/Containers/com.gfredr.unroll/Data/Library/Preferences/com.gfredr.unroll)
# 同样能切,但它往**用户自己的 App 容器**里写持久状态 —— 脚本若被 SIGKILL,trap 来不及
# 清,用户以后打开 App 就是英文界面且找不到原因。命令行参数用完即走、零残留,故选它。
#
# ⚠️ 别想"绕过 LaunchServices 直接 exec 二进制来传参":沙盒 App 被直接执行会在
# `_libsecinit_appsandbox` 初始化阶段 **SIGILL 崩掉**(EXC_BAD_INSTRUCTION,
# 2026-09-17 15:58:11 / 15:58:19 实测两次,还弹了系统崩溃报告窗)。传参只有 `open --args` 一条路。
#
# ⚠️ 2026-09-20 补记:连 `open --args` 本身也不行。用一个只回写自己 argv 的
# 探针 App 实测:经 `open` 启动 argc=1(参数一个没到),直接 exec 才有 4 个 ——
# `open -n` / 不带 -a / 写绝对路径 /usr/bin/open 四种变体结果一致。
# 所以网格与跳转面板那两段取证改用**标记文件**触发(见文末),不走 argv。
trap 'reset_session 2>/dev/null || true; cleanup_probe_flags' EXIT

# 驱动标记必须清干净:标记文件一旦残留,Debug 版 App 在**下一次正常启动**时
# 也会自动跑演示 —— 用户自己打开会莫名其妙看到自动翻页 / 面板自动弹出,
# 而且不知道是谁干的。所以挂进 trap,中途 exit 也照清。
cleanup_probe_flags() {
    local dir="$HOME/Library/Containers/com.gfredr.unroll/Data/tmp"
    rm -f "$dir/demo-enabled" "$dir/demo-grid" "$dir/demo-jump" 2>/dev/null || true
}

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

    # ⚠️ 语言覆盖的关键前提:**App 必须尚未运行**(原因见上面"界面语言"那一段)。
    # 顺序固定为 quit_app → 带 `--args` 冷启动,不能调换。
    #
    # 窗口标题在这一阶段就是 App 显示名(开卷 / Unroll),所以"语言有没有真的
    # 切过去"是**机器判据** —— 没有这一步,参数被丢弃时只会拍出一张中文图
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
        # 带语言的那次 `open` 必须是**冷启动**这一次;后一条只是把 fixture 交给
        # 已在跑的同一个实例(沙盒授权随打开事件一并给出)。
        open -a "$APP" --args -AppleLanguages "($lang)"
        sleep 2
        open -a "$APP" "$fixture"
        sleep 3

        # 取标题用**轮询**,不是"固定 sleep 后取一次":窗口出现的时间不固定
        # (冷启动 + LaunchServices,实测有 5 秒时窗口还没出来的),单次取样会把
        # 一次正常的慢启动误报成"找不到窗口"。
        local title="" i
        for i in $(seq 1 15); do
            title="$("$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" {print $3; exit}')"
            if [ -n "$title" ]; then break; fi
            sleep 1
        done
        if [ -z "$title" ]; then
            bad "$lang:打开加密归档后 15 秒内没出现窗口"
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

# ------------------------- 缩略图网格 / 跳转面板预览(v1.1,2026-09-18 新增) --
# 验的是 v1.1 加的两个「先看再跳」入口:
#   · ⇧⌘G 缩略图网格      —— 一次铺开整卷,点哪页去哪页
#   · ⌥⌘G 跳转面板的预览  —— 输页码时就先看到目标页长什么样
#
# ⚠️ 前提:必须用**可驱动的 .app**(Debug 版)。这两个面板只能靠按键打开,
#    而按键注入被 TCC 挡死(2026-09-20 实测:`osascript … System Events …
#    keystroke` 报 1002「osascript 不允许发送按键」)。出路是让 App 自己驱动
#    ViewModel —— 那套代码(Unroll/App/DemoDriver.swift)只在 DEBUG 编译。
#
#    APP=<Debug 版 Unroll.app> OUT_DIR=/tmp/shots ./Scripts/verify-ui.sh ONLY=grid
#
#    拿 Release 产物跑 → 判「前提不满足」而不是「功能坏了」:Release 版里
#    根本没有驱动代码,连 demo-driver.log 都不会被创建。这一点很要紧 ——
#    把「压根没执行」报成「执行失败」,会把人送去查一个没跑过的功能。
#    (同一条教训见 docs/测试与验证.md §11.9:守卫自测脚本把产物过期误诊成
#     守卫有洞,顺着走就会去拆掉守卫本身。)
#
# 判据分两层,缺一不可:
#   · 驱动状态行 → 证明**数据对**(生成了几张 / 预览的是哪一页)
#   · 截图       → 证明**长得对**,这层只能人看
# 只看截图会漏掉「铺出来了但少几页」;只看状态行会漏掉「数据对但版式塌了」。
if [ "$ONLY" = "grid" ] || [ "$ONLY" = "jump" ]; then
    head2 "缩略图网格 / 跳转预览取证(ONLY=$ONLY)"

    PROBE_TMP="$HOME/Library/Containers/com.gfredr.unroll/Data/tmp"
    DRIVER_LOG="$PROBE_TMP/demo-driver.log"
    mkdir -p "$PROBE_TMP"

    # ---- 多页样本 ----
    # 复用 plain.cbz 是不行的:它只有 3 页,一格一页地铺根本看不出「一屏多张」——
    # 而那正是这两个面板存在的理由。样本落在**仓库之外**(与 Unroll-dist 同规)。
    PROBE_DIR="${PROBE_DIR:-${ROOT_DIR}-manual-fixtures}"
    PROBE_SAMPLE="${PROBE_SAMPLE:-$PROBE_DIR/probe-grid-sample.cbz}"
    PROBE_PAGES="${PROBE_PAGES:-30}"
    if [ ! -s "$PROBE_SAMPLE" ]; then
        mkdir -p "$PROBE_DIR"
        GEN="$PROBE_DIR/gen_big_sample"
        if [ ! -x "$GEN" ]; then
            info "编译样本生成器…"
            xcrun --sdk macosx swiftc -O -o "$GEN" Scripts/gen_big_sample.swift >/dev/null 2>&1 \
                || { bad "gen_big_sample 编译失败"; exit 2; }
        fi
        info "造 $PROBE_PAGES 页取证样本(仓库外,约 1s)…"
        "$GEN" --pages "$PROBE_PAGES" --width 600 --height 850 --quality 0.5 \
               --out "$PROBE_SAMPLE" >/dev/null 2>&1 \
            || { bad "样本生成失败"; exit 2; }
    fi
    PROBE_PAGES_ON_DISK="$(unzip -l "$PROBE_SAMPLE" 2>/dev/null | grep -c '\.jpg$' || true)"
    ok "取证样本:$(basename "$PROBE_SAMPLE")(${PROBE_PAGES_ON_DISK} 页)"

    # ---- 场景 ----
    if [ "$ONLY" = "grid" ]; then
        SCENE="grid"; SHOT="shot-grid-panel.png"; WAIT_PAT="scene=grid pages="
    else
        SCENE="jump"; SHOT="shot-jump-preview.png"; WAIT_PAT="scene=jump current="
    fi

    quit_app
    reset_session
    # 每次只留一个标记:虽然驱动的判定顺序是 grid > jump > paging,
    # 但「跑的是 grid 却拍到了 jump」这种失败查起来极费劲,不值得省那一次 rm
    cleanup_probe_flags
    rm -f "$DRIVER_LOG"
    touch "$PROBE_TMP/demo-$SCENE"

    open -a "$APP" "$PROBE_SAMPLE"

    # 两段等待,各判一件事 —— 混成一段会把「没执行」和「执行失败」搅在一起。
    #
    # 第一段短:**可驱动的产物在 App 一起来就会写第一行**(DemoDriver 挂在视图的
    # onAppear 上),所以 10 秒还不见日志,基本就能断定这份产物里没有驱动。
    # 没必要为「根本没跑」白等一分钟 —— 而白等还有个副作用:超时久了人会
    # 以为是环境偶发,重跑一遍,然后又失败一次。
    #
    # ⚠️ 别改用「二进制里有没有 demo-driver.log 字符串」来提前判定。2026-09-20
    # 实测过:Release 构建会把字符串优化掉 —— 二进制里 `session` 还在、`session.json`
    # 已经没了,`UnrollSourceCommit` 更是只存在于 Info.plist。字符串判据是脆的,
    # 而它误判的方向恰好是**把正常的 Debug 版判成没驱动**(Debug 的代码还在
    # 单独的 Unroll.debug.dylib 里,只扫主二进制就找不到)。
    for i in $(seq 1 40); do            # 上限 10s
        [ -f "$DRIVER_LOG" ] && break
        sleep 0.25
    done
    if [ ! -f "$DRIVER_LOG" ]; then
        bad "10 秒内没有出现驱动日志 —— 被测产物不含驱动(仅 DEBUG 编译)"
        info "当前 APP=$APP"
        info "构建:xcodebuild build -project Unroll.xcodeproj -scheme Unroll \\"
        info "        -configuration Debug -destination 'platform=macOS' -derivedDataPath <目录>"
        info "说明:⇧⌘G / ⌥⌘G 无法从外部注入(TCC 拒绝发送按键),只能由 App 自己驱动"
        exit 2
    fi
    ok "驱动已启动"

    # 第二段:等场景跑完。网格要顺序扫全档,样本越大越慢
    for i in $(seq 1 240); do           # 再给 60s
        grep -q "$WAIT_PAT" "$DRIVER_LOG" && break
        sleep 0.25
    done
    if ! grep -q "$WAIT_PAT" "$DRIVER_LOG"; then
        # 有驱动、但场景没跑完 —— 这一条是**真失败**,不是前提不满足
        bad "驱动没跑完场景(日志里没有 $WAIT_PAT)"
        info "日志尾部:"
        tail -5 "$DRIVER_LOG" | sed 's/^/      /'
        exit 1
    fi

    # ---- 机器判据:状态行 ----
    # 收进变量再解析,不走管道:set -o pipefail 下 `… | grep -q` 会因 SIGPIPE
    # 打出互相矛盾的结论(build-app.sh 里记过同类坑)
    LINE="$(grep "$WAIT_PAT" "$DRIVER_LOG" | tail -1 || true)"
    field() { printf '%s\n' "$LINE" | sed -n "s/.*[ =]$1=\([0-9a-zA-Z]*\).*/\1/p"; }
    info "状态行:$LINE"

    if [ "$ONLY" = "grid" ]; then
        G_PAGES="$(field pages)"; G_GEN="$(field generated)"; G_STOP="$(field stop)"
        G_THUMBS="$(field thumbs)"; G_SKIP="$(field skipped)"; G_FAIL="$(field failed)"
        if [ "${G_STOP:-nil}" = "full" ]; then
            ok "生成正常结束(stop=full)"
        else
            bad "生成没跑完:stop=${G_STOP:-nil}(nil = 30s 内没等到结束)"
        fi
        [ "${G_GEN:-0}" = "${G_PAGES:-x}" ] && ok "报告覆盖全档:$G_GEN/$G_PAGES" \
            || bad "报告没覆盖全档:generated=$G_GEN pages=$G_PAGES"
        # 池子里真有图 ≠ 报告说生成了几张 —— 报告可能对而池子是空的
        [ "${G_THUMBS:-0}" = "${G_PAGES:-x}" ] && ok "池中确有图:thumbs=$G_THUMBS" \
            || bad "池中图数与页数不符:thumbs=$G_THUMBS pages=$G_PAGES"
        [ "${G_FAIL:-1}" = "0" ] && [ "${G_SKIP:-1}" = "0" ] \
            && ok "样本无坏页无加密页(failed=0 skipped=0)" \
            || bad "不该有失败/跳过:failed=$G_FAIL skipped=$G_SKIP"
    else
        J_CUR="$(field current)"; J_PREV="$(field previewPage)"
        J_HAS="$(field hasPreview)"; J_FAIL="$(field failure)"; J_LOAD="$(field loading)"
        [ "${J_HAS:-0}" = "1" ] && ok "预览已取到图(previewPage=$J_PREV)" \
            || bad "预览没取到图:hasPreview=$J_HAS failure=$J_FAIL loading=$J_LOAD"
        # 配对断言 —— 面板的全部价值就是「看一眼确认是哪一页」,
        # 显示出错页比什么都不显示更糟(见 ReaderView.preview 的注释)
        [ "${J_PREV:-x}" = "${J_CUR:-y}" ] && ok "预览页与当前页一致:$J_PREV" \
            || bad "预览页与当前页不符:previewPage=$J_PREV current=$J_CUR"
        [ "${J_FAIL:-1}" = "0" ] && [ "${J_LOAD:-1}" = "0" ] \
            && ok "预览不是失败态也不是转圈态" \
            || bad "预览停在异常态:failure=$J_FAIL loading=$J_LOAD"
    fi

    # ---- 截图 ----
    # sheet 是独立窗口,且**没有标题** —— 主窗口的标题是「文件名 · P.n/m」。
    # 这两点合起来是「哪个窗口是面板」的可靠判据(比按尺寸挑稳:主窗口
    # 900x508、网格面板 720x520,高度几乎一样,按尺寸会选错)
    ID=""
    for i in $(seq 1 20); do
        ID="$("$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" && $3=="" {print $1; exit}')"
        [ -n "$ID" ] && break
        sleep 0.5
    done
    if [ -z "$ID" ]; then
        bad "没找到面板窗口(sheet 应为独立无标题窗口)"
    else
        rm -f "$OUT_DIR/$SHOT"
        screencapture -l"$ID" -x -o "$OUT_DIR/$SHOT" 2>/dev/null
        if [ -s "$OUT_DIR/$SHOT" ]; then
            ok "$SHOT"
        else
            bad "$SHOT 截图失败"
        fi
    fi

    cleanup_probe_flags
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
