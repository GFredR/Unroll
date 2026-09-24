#!/bin/bash
# ============================================================================
# verify-ui.sh —— 界面验收自动取证(空态 / 阅读窗口 / 密码界面 / 崩溃询问 / dmg 布局)
# ----------------------------------------------------------------------------
# 用法:
#   ./Scripts/verify-ui.sh                 # 拍全套截图到 docs/
#   OUT_DIR=/tmp/shots ./Scripts/verify-ui.sh
#   APP=/path/to/Unroll.app ./Scripts/verify-ui.sh    # 换被测的 .app
#   ONLY=password ./Scripts/verify-ui.sh              # 只跑某一段(all|empty|reader|password|crash|dmg|grid|jump|scroll|export|hint|chrome)
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
    echo "  段名:all | empty | reader | password | crash | dmg | grid | jump | scroll | export | hint | chrome" >&2
    echo "  (grid / jump / scroll / export / hint / chrome 需要可驱动的 Debug 版,见文末说明)" >&2
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
    # ⚠️ 这里必须**逐个列全**每一个标记文件名。漏掉的那个会让 App 在用户**下一次
    #    正常启动**时自己跑起演示,而用户不知道是谁干的 —— 正是本函数要防的事。
    #    2026-09-22 发现:demo-scroll 当年加进 DemoDriver 时漏在了这里(只清到
    #    demo-jump)。所以新增场景时有一条联动纪律:
    #      **DemoDriver.Scene 加一个 case → 本行就必须加一个文件名**
    #    两处不联动就是「跑完没清干净」的复发点,而它没有任何报错。
    rm -f "$dir/demo-enabled" "$dir/demo-grid" "$dir/demo-jump" \
          "$dir/demo-scroll" "$dir/demo-export" "$dir/demo-hint" "$dir/demo-chrome" \
          2>/dev/null || true
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
#   · ⇧⌘G 缩略图网格层    —— 一次铺开整卷,点哪页去哪页(自 2026-09-23 起它同时是
#                            打开归档后的**默认落点**,见下面那条 ⚠️)
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
#    (同一条教训见 工程笔记(未随仓库发布) §11.9:守卫自测脚本把产物过期误诊成
#     守卫有洞,顺着走就会去拆掉守卫本身。)
#
# 判据分两层,缺一不可:
#   · 驱动状态行 → 证明**数据对**(生成了几张 / 预览的是哪一页 / 视口动没动)
#   · 截图       → 证明**长得对**,这层只能人看
# 只看截图会漏掉「铺出来了但少几页」;只看状态行会漏掉「数据对但版式塌了」。
#
# ONLY=scroll(连续滚动 ⌘0,2026-09-21)走同一套机制,但**样本换成宽幅**:
# 高窄页按宽度适配后单页高约 2.2 屏,一帧里只看得见一页的一部分 ——
# 「一列铺开」这个版式特征在截图里根本显现不出来(那不是拍得不好,是几何)。
# 换成 1600x600 的宽幅页,行高约 0.66 屏,一帧能看到一行半,间距与连续关系都可见。
# 这是**选样本**让性质可观测,不是给性质加修饰。
# ONLY=export(导出本卷页文件 ⇧⌘E,2026-09-22 补)也走标记文件,但**判据重心不同**:
# 它多一条「报告 ↔ 磁盘」两条路对照 —— 驱动自己数一次磁盘(`onDisk`)、本脚本
# 再数一次,与报告的 `written` 三方对齐。理由与网格那条 `thumbs` 完全一样:
# 报告说写了 N 页**不等于**磁盘上真有 N 个文件,而「报告对、磁盘空」恰恰是
# 判据最容易放过的那类假绿。样本沿用网格那份 30 页(观感真实、进度有内容)。
#
# ONLY=hint(首次阅读提示条,2026-09-22)同样走标记文件,但它与前面几段有一处
# **根本不同**:取的不是面板、也不是滚动布局,而是「阅读时贴在画布上方的那一行」,
# 所以截图要的是**主窗口**(与 scroll 同款判据:有标题的那个窗口)。
# 提示条自己只自动出现一次,故驱动用 `showHintBar()` 显式调出来(菜单里那一项
# 走的是同一个方法);于是 `auto=0` 在重复跑时属于**预期**,不能当失败 ——
# 判据只看 `visible=1`。另:这一段**不验**「没盖住页面」,那由代码结构保证
# (它是布局里的一行,不是浮层),截图只供人看;详见 DemoDriver.runHint 的说明。
# ⚠️ **ONLY=grid 在 2026-09-23 有两处变化**,两处都容易让下一个人改错:
#   ① 它拍的窗口换成了**主窗口** —— 网格从 sheet 提升为「层」,不再有自己的窗口。
#      下面截图那一段的 `PANEL` 判定因此**反过来写**了(只列出仍是 sheet 的场景),
#      别再照着"grid 是面板"的旧印象改回"scroll/hint 拍主窗口、其余拍面板";
#   ② 驱动里 `runGrid` 之前的 `prepareForProbe` 会先切到**阅读层**(因为其余几个
#      场景验的都是画布),`runGrid` 再切回网格层 —— 那条"返回"路径因此也进了取证。
#      状态行里的 `layer=browse` 就是它切回去了的证据。
# 断言本身没有变:仍是 stop=full / generated==pages / thumbs==pages / failed=skipped=0。
if [ "$ONLY" = "grid" ] || [ "$ONLY" = "jump" ] || [ "$ONLY" = "scroll" ] \
   || [ "$ONLY" = "export" ] || [ "$ONLY" = "hint" ] || [ "$ONLY" = "chrome" ]; then
    head2 "面板取证:网格 / 跳转预览 / 连续滚动 / 导出 / 阅读提示 / 周边控件(ONLY=$ONLY)"

    PROBE_TMP="$HOME/Library/Containers/com.gfredr.unroll/Data/tmp"
    DRIVER_LOG="$PROBE_TMP/demo-driver.log"
    mkdir -p "$PROBE_TMP"

    # ---- 多页样本 ----
    # 复用 plain.cbz 是不行的:它只有 3 页,一格一页地铺根本看不出「一屏多张」——
    # 而那正是这两个面板存在的理由。样本落在**仓库之外**(与 Unroll-dist 同规)。
    PROBE_DIR="${PROBE_DIR:-${ROOT_DIR}-manual-fixtures}"
    PROBE_PAGES="${PROBE_PAGES:-30}"
    if [ "$ONLY" = "scroll" ]; then
        # 宽幅样本,理由见上面那段注释(高窄页看不出「一列」)
        PROBE_SAMPLE="${PROBE_SAMPLE:-$PROBE_DIR/probe-scroll-sample.cbz}"
        GEN_W=1600; GEN_H=600
    else
        PROBE_SAMPLE="${PROBE_SAMPLE:-$PROBE_DIR/probe-grid-sample.cbz}"
        GEN_W=600; GEN_H=850
    fi
    if [ ! -s "$PROBE_SAMPLE" ]; then
        mkdir -p "$PROBE_DIR"
        GEN="$PROBE_DIR/gen_big_sample"
        if [ ! -x "$GEN" ]; then
            info "编译样本生成器…"
            xcrun --sdk macosx swiftc -O -o "$GEN" Scripts/gen_big_sample.swift >/dev/null 2>&1 \
                || { bad "gen_big_sample 编译失败"; exit 2; }
        fi
        info "造 $PROBE_PAGES 页取证样本($GEN_W x $GEN_H,仓库外,约 1s)…"
        "$GEN" --pages "$PROBE_PAGES" --width "$GEN_W" --height "$GEN_H" --quality 0.5 \
               --out "$PROBE_SAMPLE" >/dev/null 2>&1 \
            || { bad "样本生成失败"; exit 2; }
    fi
    PROBE_PAGES_ON_DISK="$(unzip -l "$PROBE_SAMPLE" 2>/dev/null | grep -c '\.jpg$' || true)"
    ok "取证样本:$(basename "$PROBE_SAMPLE")(${PROBE_PAGES_ON_DISK} 页)"

    # ---- 场景 ----
    case "$ONLY" in
    grid)   SCENE="grid";   SHOT="shot-grid-panel.png";     WAIT_PAT="scene=grid pages=" ;;
    jump)   SCENE="jump";   SHOT="shot-jump-preview.png";   WAIT_PAT="scene=jump current=" ;;
    scroll) SCENE="scroll"; SHOT="shot-continuous-scroll.png"; WAIT_PAT="scene=scroll layout=" ;;
    export) SCENE="export"; SHOT="shot-export-panel.png";   WAIT_PAT="scene=export pages=" ;;
    hint)   SCENE="hint";   SHOT="shot-reading-tips.png";   WAIT_PAT="scene=hint " ;;
    chrome) SCENE="chrome"; SHOT="shot-reader-chrome.png";  WAIT_PAT="scene=chrome layer=" ;;
    esac

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
        info "说明:⇧⌘G / ⌥⌘G / ⌘0 都无法从外部注入(TCC 拒绝发送按键),只能由 App 自己驱动"
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
        # 「阅读层按『浏览』切回网格层」的机器判据(2026-09-23)。网格变成**层**之后,
        # `runGrid` 是被 `prepareForProbe` 先切到阅读层、再由 `showGrid()` 切回来的 ——
        # 这一段把上面注释里的说法从"叙述"变成"可判的事实"。
        # ⚠️ 字段取自**另一行**:`layer=` 只在 `scene=grid layer=browse` 那一行上,
        #    而 `field()` 解析的是紧随其后的 `scene=grid pages=…` 汇总行(两条不同的日志行)
        G_LAYER="$(grep 'scene=grid layer=' "$DRIVER_LOG" | tail -1 | sed -n 's/.*layer=\([a-z]*\).*/\1/p')"
        [ "${G_LAYER:-nil}" = "browse" ] && ok "确实切回了网格层(layer=browse)" \
            || bad "没切回网格层:layer=${G_LAYER:-nil}(nil = 那一行没打出来,别读成『功能坏了』)"
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
    elif [ "$ONLY" = "jump" ]; then
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
    elif [ "$ONLY" = "scroll" ]; then
        S_LAYOUT="$(field layout)"; S_FIRST="$(field first)"; S_MID="$(field mid)"
        S_EXPECT="$(field expectedMid)"; S_BACK="$(field back)"
        S_BEFORE="$(field loadsBefore)"; S_AFTER="$(field loadsAfter)"

        [ "${S_LAYOUT:-x}" = "scroll" ] && ok "已切到滚动模式" \
            || bad "模式没切过去:layout=${S_LAYOUT:-nil}"

        # 下行与回程的锚点。**注意这两条证明的是「锚点漏斗接通了」**,
        # 不是「视口真的滚了」—— 程序化设值会在同一次设值里同步回填 pageIndex,
        # 所以哪怕滚动视图根本没动,这两个数也会是对的。别把它们讲过头
        [ "${S_MID:-x}" = "${S_EXPECT:-y}" ] && ok "下行锚点到位:$S_MID" \
            || bad "下行锚点不对:mid=${S_MID:-nil} expected=$S_EXPECT"
        [ "${S_BACK:-x}" = "${S_FIRST:-y}" ] && ok "回程锚点回到起点:$S_BACK" \
            || bad "回程锚点不对:back=${S_BACK:-nil} first=$S_FIRST"

        # 「视口真的移动过」的**唯一**机器判据:rowLoads 只由行视图累加
        # (VM 自己的锚点页读取与预读都不计入)。视口不动 → 新行不会 materialize
        # → 计数不涨。少了这一条,上面那两条可以全绿而屏幕上是一片占位框
        if [ "${S_AFTER:-0}" -gt "${S_BEFORE:-0}" ] 2>/dev/null; then
            ok "视口确实移动过并渲染了新行(rowLoads $S_BEFORE → $S_AFTER)"
        else
            bad "行视图没有为新位置取图:$S_BEFORE → ${S_AFTER:-nil}(视口可能没动)"
        fi
    elif [ "$ONLY" = "export" ]; then
        # ---- 导出本卷页文件:判据的重心是「报告 ↔ 磁盘」的对照 ----------------
        E_PAGES="$(field pages)"; E_WRITTEN="$(field written)"; E_SKIP="$(field skipped)"
        E_FAIL="$(field failed)"; E_STOP="$(field stop)"; E_COVERS="$(field covers)"
        E_ONDISK="$(field onDisk)"

        if [ "${E_STOP:-nil}" = "full" ]; then
            ok "导出正常结束(stop=full)"
        else
            bad "导出没跑完:stop=${E_STOP:-nil}(nil = 60s 内没等到结束)"
        fi

        # 「有没有漏页」用报告自带的 coversWholeArchive(delivered+skipped+failed==pages),
        # **不在这里自己再算一遍** —— 算错的方向恰好是「把没弄完的说成弄完了」
        [ "${E_COVERS:-0}" = "1" ] && ok "报告覆盖全档(交付 + 跳过 + 坏页 = 总页数)" \
            || bad "报告没覆盖全档:pages=$E_PAGES written=$E_WRITTEN skipped=$E_SKIP failed=$E_FAIL"

        # 这一段的核心:「报告说写了 N」与「磁盘上真有 N」是**两条路**。
        # 报告对而磁盘空的时候,上面两条照样全绿 —— 那正是判据最容易放过的假绿
        [ "${E_ONDISK:-x}" = "${E_WRITTEN:-y}" ] && ok "磁盘文件数与报告一致:$E_ONDISK" \
            || bad "报告与磁盘不符:written=$E_WRITTEN onDisk=$E_ONDISK(报告说写了、磁盘上却没有)"

        [ "${E_FAIL:-1}" = "0" ] && [ "${E_SKIP:-1}" = "0" ] \
            && ok "样本无坏页无加密页(failed=0 skipped=0)" \
            || bad "不该有失败/跳过:failed=$E_FAIL skipped=$E_SKIP"

        # 第二条路(与驱动那条独立):脚本自己再数一次那个目录,并与报告三方对齐。
        # 目录不存在时只提示、不判红 —— 容器被清理过不该被说成功能坏了
        EXPORT_DIR="$PROBE_TMP/export-probe"
        if [ -d "$EXPORT_DIR" ]; then
            E_SCRIPT_N="$(find "$EXPORT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
            [ "${E_SCRIPT_N:-0}" = "${E_WRITTEN:-y}" ] && ok "脚本复数的文件数一致:$E_SCRIPT_N(同一份数据量的第二次口径)" \
                || bad "脚本复数与报告不符:脚本=$E_SCRIPT_N 报告=${E_WRITTEN:-nil}"
            if [ "${E_SCRIPT_N:-0}" -gt 0 ] 2>/dev/null; then
                E_FIRST="$(find "$EXPORT_DIR" -type f 2>/dev/null | sort | head -1)"
                E_LAST="$(find "$EXPORT_DIR" -type f 2>/dev/null | sort | tail -1)"
                info "导出首/尾:$(basename "${E_FIRST:-?}") / $(basename "${E_LAST:-?}")"
                # 命名规则抽查(补零页号 + 原扩展名)。**只抽查首尾** ——
                # 「按阅读顺序」那条性质由 swift test 逐字节断言(乱序条目名 fixture),
                # 本段样本的条目名本身有序,在这里看不出顺序的价值
                case "$(basename "${E_FIRST:-}")" in
                    *-p001.*) ok "首个文件名是补零的第 1 页" ;;
                    *)        bad "首个文件名不合「补零页号」规则:$(basename "${E_FIRST:-?}")" ;;
                esac
            fi
            info "导出文件留在:$EXPORT_DIR(不在仓库内;下次取证时由驱动清空重建)"
        else
            info "导出目录不存在 —— 跳过脚本侧复数:$EXPORT_DIR"
        fi
    elif [ "$ONLY" = "hint" ]; then
        # ---- 首次阅读提示条(2026-09-22)------------------------------------
        H_AUTO="$(field auto)"; H_VIS="$(field visible)"

        # 唯一的断言项。菜单「帮助 → 显示阅读提示」走的就是驱动调的那个方法,
        # 它为 0 = 重看入口坏了(而这是提示条"只自动出现一次"之后的唯一出路)
        [ "${H_VIS:-0}" = "1" ] && ok "提示条已在屏上(visible=1)" \
            || bad "showHintBar() 之后提示条不在屏上:visible=${H_VIS:-nil}"

        # 下面这条**只提示、不判红**:提示条只自动出现一次,同一容器再跑必然是 0 ——
        # 把它当失败会把人送去查一个没坏的功能。想看 auto=1,得先让容器回到
        # "没见过这条提示"的状态(新装 / 清过容器),再跑一次这一段
        if [ "${H_AUTO:-0}" = "1" ]; then
            ok "打开文档时它自己出现了 —— 真实 App 里这条自动路径通着(auto=1)"
        else
            info "这次没自动出现(auto=0)—— 预期之内:它只自动出现一次"
        fi
    elif [ "$ONLY" = "chrome" ]; then
        # ---- 阅读层周边控件:左侧缩略图栏 + 左右翻页箭头(2026-09-23)--------
        C_LAYER="$(field layer)"; C_THUMBS="$(field thumbs)"; C_PAGES="$(field pages)"

        # 唯一的结构性断言:**必须停在阅读层**。层不对,整张图与主题无关
        [ "$C_LAYER" = "read" ] && ok "停在阅读层(layer=read)" \
            || bad "没停在阅读层:layer=${C_LAYER:-nil}(左栏与箭头只长在阅读层上)"

        # 左栏的**数据源**有多少张图。它只证明"有东西可显示",**不等于**"栏画出来了"
        # —— 画没画出来只有截图能证(与 grid 那条同一套分工:状态行证数据、截图证观感)
        if [ "${C_THUMBS:-0}" -gt 0 ] && [ "${C_PAGES:-0}" -gt 0 ]; then
            ok "左栏数据源有图(thumbs=${C_THUMBS} / pages=${C_PAGES})"
        else
            bad "左栏没有可显示的缩略图:thumbs=${C_THUMBS:-nil} pages=${C_PAGES:-nil}"
        fi

        info "本段明确没覆盖:鼠标静默的淡化、箭头方向语义(理由见 DemoDriver.runChrome)"
    else
        # 走到这里说明 case 里加了场景、断言分支却没跟上。
        # **必须当场判红**:少一个分支的表现是"脚本全绿、断言一条没跑",
        # 而那正是 §18.5 记下的"新场景静默走进旧场景判据"的同型事故
        bad "场景 $ONLY 没有断言分支 —— verify-ui.sh 的 case 与这里的 elif 链没联动"
    fi

    # ---- 截图 ----
    # 判据仍是"有没有标题":sheet 是独立窗口且**没有标题**,主窗口的标题是
    # 「文件名 · P.n/m」(比按尺寸挑稳:主窗口与网格层的高宽可能几乎一样)。
    #
    # ⚠️ **2026-09-23 反过来写了**。原先是"scroll / hint 拍主窗口,其余拍面板",
    # 而网格从 sheet 提升为**层**之后它改拍主窗口 —— 上面那种写法会让它继续去找
    # 一个**不存在的无标题窗口**,表现是截图失败或拍到别的东西,**而断言全绿**。
    # 现在只列出"确实还是 sheet"的场景,其余一律当主窗口:
    # 以后再来一个"层"场景,不写进这个列表就**天然是对的**
    case "$ONLY" in
    jump|export) PANEL=1 ;;   # 仍是 sheet
    *)           PANEL=0 ;;   # 主窗口(grid 自 2026-09-23 起、scroll、hint)
    esac
    ID=""
    for i in $(seq 1 20); do
        if [ "$PANEL" = "1" ]; then
            ID="$("$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" && $3=="" {print $1; exit}')"
        else
            ID="$("$WINID" unroll 2>/dev/null | awk -F'\t' '$2=="Unroll" && $3!="" {print $1; exit}')"
        fi
        [ -n "$ID" ] && break
        sleep 0.5
    done
    if [ -z "$ID" ]; then
        if [ "$PANEL" = "1" ]; then
            bad "没找到要拍的窗口(本场景是 sheet = 无标题窗口)"
        else
            bad "没找到要拍的窗口(本场景拍主窗口 = 有标题那个)"
        fi
    else
        rm -f "$OUT_DIR/$SHOT"
        screencapture -l"$ID" -x -o "$OUT_DIR/$SHOT" 2>/dev/null
        if [ -s "$OUT_DIR/$SHOT" ]; then
            ok "$SHOT"
        else
            bad "$SHOT 截图失败"
        fi
    fi

    # ---- 版式测量:页面有没有被横向裁掉(ONLY=scroll,2026-09-21)----
    #
    # 这一条是上面那堆状态行断言**测不到**的:状态行只能证「数据对」,页面被裁掉
    # 15pt(两边各 7.5pt)时状态行全绿,截图上看着也还是「铺满」—— 肉眼分不出。
    #
    # 所以拿样本页**自带的**内容当尺子:生成器给每页画了页脚进度条(黑底 + 白色
    # 「已完成」段),白段宽 = 页宽 × n/总页数。按**滚动视图内容区实宽**算出的期望
    # 值,与被裁时的实测值差 ~13 设备px —— 足以把「铺满」和「被裁」分开。
    # 期望值从状态行的 first/pages 推,不写死页码;样本宽高从 GEN_W/GEN_H 取。
    if [ "$ONLY" = "scroll" ] && [ -s "$OUT_DIR/$SHOT" ]; then
        METRICS=/tmp/verify-ui-pagemetrics
        if [ ! -x "$METRICS" ]; then
            swiftc -O -o "$METRICS" Scripts/page_metrics.swift >/dev/null 2>&1 \
                || bad "page_metrics.swift 编译失败"
        fi
        if [ -x "$METRICS" ]; then
            M="$("$METRICS" "$OUT_DIR/$SHOT" 2>/dev/null || true)"
            mfield() { printf '%s\n' "$M" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }
            M_COL="$(mfield colRight)"; M_LEFT="$(mfield colLeft)"
            M_W="$(mfield contentWidth)"; M_BAR="$(mfield barWhiteRight)"
            M_H="$(mfield blockHeight)"; M_STRIP="$(mfield scrollerStrip)"
            # 内容区**实宽** = colRight − colLeft。
            #
            # 2026-09-23 阅读层左侧多了缩略图栏(112pt)之后,「内容区从 x=0 起」
            # 这条老假设不再成立。拿 colRight 当宽度会把页面算宽**整整一个栏宽**
            # (224 设备px),于是**正常状态被判成裁切** —— 正是「守卫把正常状态
            # 说成故障」那一类假红。
            #
            # 兜底:`page_metrics` 的老二进制没有这两行 → mfield 返回空 →
            # 退化成 colRight − 0,与改动前完全等价(set -u,故一律带 :-)
            [ -n "${M_LEFT:-}" ] || M_LEFT=0
            [ -n "${M_W:-}" ] || M_W=$(( ${M_COL:-0} - M_LEFT ))
            info "版式: 内容区 ${M_LEFT}..${M_COL:-nil}(实宽 ${M_W:-nil}) 页高=${M_H:-nil} 页脚白段右缘=${M_BAR:-nil} 滚动条占位=${M_STRIP:-nil}"

            S_PAGES="$(field pages)"
            if [ "${M_W:-0}" -gt 0 ] && [ -n "$M_BAR" ] && [ -n "${S_FIRST:-}" ] && [ -n "${S_PAGES:-}" ]; then
                # 页面按内容区实宽铺满 → 页脚白段右缘**距页左缘** = 实宽 × (index+1)/总页数
                WANT=$(( M_W * (S_FIRST + 1) / S_PAGES ))
                GOT=$(( M_BAR - M_LEFT ))
                D=$(( GOT - WANT )); [ "$D" -lt 0 ] && D=$(( -D ))
                if [ "$D" -le 5 ]; then
                    ok "页面铺满内容区实宽(页脚白段距页左缘 ${GOT} ≈ ${WANT} 设备px)"
                else
                    bad "页面被横向裁了:页脚白段距页左缘 ${GOT},按内容区实宽应为 ${WANT}(差 ${D} 设备px)"
                fi
            else
                bad "量不出页面版式:contentWidth=${M_W:-nil} bar=${M_BAR:-nil}"
            fi

            # 第二条独立判据:页高必须等于「按内容区实宽等比」的高度。
            # 裁切时页面按更宽的容器排,于是比实宽等比**更高** —— 差值与栏宽同量级。
            # 这条不依赖页脚进度条,所以它和上面那条不会「同时瞎」
            if [ -n "$M_H" ] && [ "${M_W:-0}" -gt 0 ]; then
                WANTH=$(( M_W * GEN_H / GEN_W ))
                DH=$(( M_H - WANTH )); [ "$DH" -lt 0 ] && DH=$(( -DH ))
                if [ "$DH" -le 8 ]; then
                    ok "页面按实宽等比:页高 ${M_H} ≈ ${WANTH}"
                else
                    bad "页面比例不对:页高 ${M_H},按内容区实宽等比应为 ${WANTH}(差 ${DH})"
                fi
            fi
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
echo "    · 连续滚动连滑的跟手程度与掉帧(版式与「有没有被裁」已由上面的版式测量量过)"
echo "    · 首次阅读提示条那一行:文案是否说清了那三个手势、有没有盖住页面、"
echo "      「×」点一下是否真的收回去(驱动调的是 ViewModel 那一层,证明不了按钮接线)"
echo "    · 「文件 → 另存当前页…」存出来的图与屏幕上看到的一致(双页应是一整摊)"
echo "    · 静止 2.5s 后光标是否一起隐藏、动一下就回来"
