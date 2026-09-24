#!/bin/bash
# ============================================================================
# probe-window-memory.sh —— 窗口尺寸/位置记忆取证（2026-09-24 新增 / 同日晚重写）
# ----------------------------------------------------------------------------
# 这条链路的历史值得完整读一遍 —— 它换过三次答案:
#
#   ① 2026-09-15–09-23 的**声明**：「窗口大小/位置记忆由系统的窗口恢复机制提供」
#      —— 从来没被验过。2026-09-16 更正过一次细节（`setFrameAutosaveName` 那个键
#      从未产生），但结论仍是「记忆是好的，只是记在别处」。
#   ② 2026-09-24 **第一次取证**：同一二进制连启两次，SwiftUI 派生的
#      `NSWindow Frame SwiftUI.…` 键数 **20 → 21 → 22**，每次都新增 ⇒ 键名不复用
#      （那条链里含一次性代码地址 `…(unknown context at $10b1fce30)…`）
#      ⇒ **窗口记忆从来没有生效过**。第二条独立证据：`Saved Application State/`
#      目录**是空的**。那次判据在 `MODE=legacy` 里保留着可重跑。
#   ③ 2026-09-24 晚 **实现自管记忆**（用户拍板方案 A）—— 本脚本重写成现在这样，
#      默认验的是「自管那套**真的**能写、能恢复」。
#
# ★ 默认模式（MODE=memory）的判据 —— **两条互不依赖的断言，缺一不可**:
#   正向：`set` 把窗口挪成一个与默认不同的几何 → 重启 → App 自报的几何**等于它**
#   反向：再 `set` 成**另一套**几何 → 重启 → 必须等于**新的那套**，且**不等于旧的**
#   反向那条是命根子:只有正向时，「回到原处」分不清是记忆生效还是**碰巧一样**，
#   也分不清是「记住了这一套」还是「每次都回到某个固定值」。这正是本项目反复吃过的
#   「一个从不失败的守卫等于没有守卫」。
#
# ★ 为什么让 **App 自己**报数、自己动窗口:
#   外面驱动窗口在这台机器上做不到 —— `System Events` 注入被 TCC 拒（1002），
#   `open --args` 在 macOS 15 上不转发 argv。于是走 DemoDriver 同一条已验证的路:
#   **容器标记文件**（内容即指令，App 读完立刻删）。App 侧见
#   `Unroll/App/UnrollApp.swift` 的 `WindowProbe`（`#if DEBUG`）。
#
# ★★ 启动方式的三个实测结论（2026-09-24 亲手踩完，别再试第二遍）:
#   ① **直接 exec 二进制（`"$APP/Contents/MacOS/Unroll" &`）起不了窗口** ——
#      进程活着、`ps` 看得见，但**窗口永不出现**，于是 `.onAppear` 从不触发、
#      标记文件永远不被读、探针静默空转。现象与「这个 App 不认探针」**一模一样**，
#      是个会把人带偏的假阴性。实测:连挂 10 分钟，`demo-driver.log` 一行没加。
#   ② **不带 `-n` 的 `open -a` 会被既有实例吃掉**：本机就躺着一个同 bundle id 的
#      残留实例（上次 `xcodebuild test` 留下的测试宿主；用名字判活必然误判），
#      `open -a` 会**激活它**而不是起新进程 —— 同样读不到标记。
#   ③ **可行的是 `open -n -a <绝对路径>`**：`-n` 强制新实例、绕过①的陷阱；
#      绝对路径是必须的（相对路径直接报 `Unable to find application named …`）。
#      实测:标记被消费、报告写出 `frame=544,267,960,640`。
#
# ⚠️ 判据只用 **App 自己报出来的实际窗口几何**，**不读我们自己的存储键** ——
#   读自己的键是循环论证（只能证明「写进去了」，证明不了「恢复生效了」）。
#   输出里那行「记忆键=…」只是诊断，而且它**可能滞后**（cfprefsd 有缓存，
#   磁盘上的 plist 不一定最新）。它不参与判定。
#
# ⚠️ 本脚本会**改动开发机上的窗口记忆**（收尾那轮会把它清掉，但清完之后
#   「退出兜底写」可能又把当时窗口的几何填回去）。这是有意的代价:要造出
#   「记录变了」的对照态，除了真的改它没有别的办法。它只碰**我们自己的固定键**
#   `window.frame.v1`（经 App 的 `UserDefaults.removeObject`），不碰别的键。
#
# 用法:
#   ./Scripts/probe-window-memory.sh                    # 默认:验自管记忆（Debug）
#   APP=<别的 .app> ./Scripts/probe-window-memory.sh    # 换目标
#   MODE=legacy ./Scripts/probe-window-memory.sh        # 旧判据:键是否复用（冻结产物）
#
# 退出码: 0 = 通过；1 = 不通过；2 = 前置不满足（缺 .app / 不认探针 / 缺 python3）
#
# ⚠️ 收尾义务（挂在 trap EXIT 上 —— 脚本被 Ctrl-C 死在中间也要执行）:
#   ① 删标记文件与报告文件。标记残留的后果是**下次正常启动也会跑探针**。
#   ② `session.json` 的 `alive` 复位。**只改 `alive`，保留 `suppressedVersion`** ——
#      整条重写会把用户「别再提示我」的选择一起抹掉。
#   ③ **不删**任何 frame 键。留档:2026-09-24 曾用 `defaults delete` 逐键清理，
#      而它会让 cfprefsd 拿缓存**整份重写**该 plist —— 删 3 个键，文件里却少了 6 个。
#      那些键无害（没有代码读它们），而「清理」反而**误伤别的键** —— 正是本项目记过的
#      「守卫把正常状态说成故障、还给出错的修法」。
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Unroll"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}-dist}"
MODE="${MODE:-memory}"

case "$MODE" in
memory)
    # 默认 Debug:探针（WindowProbe）只在 `#if DEBUG` 里
    APP="${APP:-$DIST_DIR/DerivedData/Build/Products/Debug/$APP_NAME.app}"
    ;;
legacy)
    # 旧判据默认指向**冻结产物**（历史结论描述的就是用户手里那个二进制）
    APP="${APP:-$DIST_DIR/$APP_NAME.app}"
    ;;
*)
    printf '✗ MODE 只能是 memory 或 legacy（收到:%s）\n' "$MODE" >&2
    exit 2
    ;;
esac

BUNDLE_ID="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: *\([A-Za-z0-9.]*\).*/\1/p' project.yml | head -1)"
BUNDLE_ID="${BUNDLE_ID:-com.gfredr.unroll}"
CONTAINER="$HOME/Library/Containers/${BUNDLE_ID}/Data"
PLIST="$CONTAINER/Library/Preferences/${BUNDLE_ID}.plist"
SUPPORT_DIR="$CONTAINER/Library/Application Support/Unroll"
SESSION="$SUPPORT_DIR/session.json"
TMP_DIR="$CONTAINER/tmp"
MARKER="$TMP_DIR/window-probe"
REPORT_FILE="$TMP_DIR/window-probe-report"
PY="${PYTHON:-python3}"

# 位置参数一律拒绝（APP= / MODE= 都是**环境变量**，写成位置参数会被静默忽略、
# 跑成默认值 —— verify-ui.sh / probe-graceful-exit.sh 都记过这个坑）
if [ "$#" -gt 0 ]; then
    printf '✗ 本脚本不接受位置参数（用环境变量：APP=… MODE=…）: %s\n' "$*" >&2
    exit 2
fi

STATUS=0
ok()    { printf '  ✓ %s\n' "$*"; }
bad()   { printf '  ✗ %s\n' "$*"; STATUS=1; }
info()  { printf '  · %s\n' "$*"; }
head2() { printf '\n── %s ─────────────────────────────────────\n' "$*"; }

mkdir -p "$SUPPORT_DIR" "$TMP_DIR"

APP_PID=""
CLEANED=0

cleanup() {
    [ "$CLEANED" = 1 ] && return 0
    CLEANED=1
    if [ -n "$APP_PID" ]; then
        kill -TERM "$APP_PID" 2>/dev/null
        sleep 0.5
        kill -9 "$APP_PID" 2>/dev/null
    fi
    # 标记文件**必须**删:残留会让下次正常启动也跑探针
    rm -f "$MARKER" "$REPORT_FILE"
    "$PY" - "$SESSION" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    if s.get("alive") is not False:
        s["alive"] = False                      # ⚠️ 只改 alive,保留 suppressedVersion
        json.dump(s, open(sys.argv[1], "w"), separators=(",", ":"))
        print("  · session.json 的 alive 已复位为 false（suppressedVersion 保留）")
except Exception:
    pass
PY
}
trap 'cleanup' EXIT

# ---------------------------------------------------------------- 工具 ------

# 进程是否还在。用 `ps` 而不是 `kill -0`:这些实例不是本脚本的子进程
# （`open` 交出去的），而**万一**是子进程，僵尸态上 `kill -0` 依然成功 ——
# 那会让「等它退出」永远等不到（本脚本第一版就卡死在这上面）
proc_alive() {
    local st
    st="$(ps -o state= -p "$1" 2>/dev/null)"
    [ -z "$st" ] && return 1
    case "$st" in *Z*) return 1 ;; esac
    return 0
}

pids_now() { pgrep -x "$APP_NAME" 2>/dev/null | tr '\n' ' '; }

# 从报告行里取某段几何（`key=x,y,w,h`）
geo_of() {
    local line="$1" key="$2" rest
    rest="${line#*"${key}"=}"
    printf '%s' "${rest%% *}"
}

# 两个几何是否相等（容差 1pt —— 浮点与 AppKit 的取整不值得让判据变脆）
geo_equal() {
    "$PY" - "$1" "$2" <<'PY'
import sys
try:
    a = [float(v) for v in sys.argv[1].split(",")]
    b = [float(v) for v in sys.argv[2].split(",")]
    same = len(a) == len(b) == 4 and all(abs(x - y) <= 1.0 for x, y in zip(a, b))
except Exception:
    same = False
print("same" if same else "diff")
PY
}

# 诊断用:读我们自己那个键（**可能滞后** —— cfprefsd 有缓存,磁盘 plist 不一定最新）
store_value() {
    "$PY" - "$PLIST" <<'PY'
import json, plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
    v = d.get("window.frame.v1")
    if v is None:
        print("(无记录)")
    else:
        g = json.loads(bytes(v).decode("utf-8"))
        print("%.0f,%.0f,%.0f,%.0f" % (g["x"], g["y"], g["width"], g["height"]))
except Exception as exc:
    print("(读不出:%s)" % exc)
PY
}

# 跑一轮探针:$1 = clear / report / set。结果放进 LAST_REPORT
LAST_REPORT=""
run_case() {
    local want="$1" before p exited
    rm -f "$REPORT_FILE"
    printf '%s' "$want" > "$MARKER"
    before="$(pids_now)"

    open -n -a "$APP" || { LAST_REPORT=""; return 1; }

    # 抓**新出现**的那个 PID（只认差集:机器上本来就躺着一个残留测试宿主）。
    # 抓不到不算致命（报告文件才是主证据），但要如实说
    APP_PID=""
    for _ in $(seq 1 40); do
        for p in $(pgrep -x "$APP_NAME" 2>/dev/null); do
            case " $before " in
            *" $p "*) ;;
            *) APP_PID="$p"; break ;;
            esac
        done
        [ -n "$APP_PID" ] && break
        sleep 0.25
    done

    LAST_REPORT=""
    for _ in $(seq 1 120); do                # 窗口出现时刻不固定 ⇒ 轮询,最多 30s
        if [ -s "$REPORT_FILE" ]; then
            LAST_REPORT="$(<"$REPORT_FILE")"
            break
        fi
        sleep 0.25
    done

    # 等它自己退走:探针收尾都调 terminate,而**落盘就在那一刻**
    # （「退出时兜底写」是三条写入时机之一）—— 没等到退出就不能说这轮验过了
    exited=1
    if [ -n "$APP_PID" ]; then
        for _ in $(seq 1 80); do
            proc_alive "$APP_PID" || { exited=0; break; }
            sleep 0.25
        done
        if [ "$exited" != 0 ]; then
            kill -TERM "$APP_PID" 2>/dev/null
            sleep 0.5
            kill -9 "$APP_PID" 2>/dev/null
        fi
        APP_PID=""
    else
        info "（这一轮没抓到我们自己的 PID —— 报告文件仍是有效证据）"
        sleep 2
    fi
    sleep 0.8                                 # 让写入落到磁盘（cfprefsd 是异步的）
    return "$exited"
}

# ---------------------------------------------------------------- legacy ----

py_keys() {
    "$PY" - "$PLIST" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
print(len([k for k in d if k.startswith("NSWindow Frame SwiftUI")]))
PY
}

run_legacy() {
    head2 "legacy:键是否复用（旧判据）"
    info "目标:$APP"
    [ -f "$PLIST" ] || { bad "找不到容器 plist:$PLIST（App 至少被启动过一次才会有）"; exit 2; }
    local n0 n1 n2 round before p
    n0="$(py_keys)"
    info "基线 frame 键数:$n0"
    for round in 1 2; do
        before="$(pids_now)"
        rm -f "$MARKER" "$REPORT_FILE"
        open -n -a "$APP" || { bad "open 失败"; exit 2; }
        for _ in $(seq 1 60); do
            for p in $(pgrep -x "$APP_NAME" 2>/dev/null); do
                case " $before " in
                *" $p "*) ;;
                *) APP_PID="$p"; break ;;
                esac
            done
            [ -n "$APP_PID" ] && break
            sleep 0.25
        done
        sleep 6
        if [ -n "$APP_PID" ]; then
            kill -TERM "$APP_PID" 2>/dev/null
            sleep 1
            kill -9 "$APP_PID" 2>/dev/null
        fi
        APP_PID=""
        sleep 1
        if [ "$round" = 1 ]; then n1="$(py_keys)"; else n2="$(py_keys)"; fi
        info "第 ${round} 轮启动后 frame 键数:${n1}"
    done
    if [ "$n1" -gt "$n0" ] && [ "$n2" -ge "$n1" ]; then
        ok "每轮启动都**新增** frame 键（${n0} → ${n1} → ${n2}）⇒ 键名不复用"
        info "⇒ 系统读不到「上次」⇒ 那条路记不住 —— 「自管记忆」的前提仍然成立"
        exit 0
    fi
    bad "frame 键在启动之间**被复用了**（${n0} → ${n1} → ${n2}）"
    info "⇒「系统那条路记不住」这条结论**已过期**（SwiftUI 改了键名规则?）"
    info "   要去核:Unroll/Core/WindowGeometry.swift 头部、UnrollApp.swift 的 WindowChrome 注释"
    exit 1
}

[ "$MODE" = "legacy" ] && run_legacy

# ---------------------------------------------------------------- memory ----

head2 "前置"
[ -d "$APP" ] || { bad "找不到 App:$APP"; exit 2; }
[ -x "$APP/Contents/MacOS/$APP_NAME" ] || { bad "App 里没有可执行文件"; exit 2; }
command -v "$PY" >/dev/null 2>&1 || { bad "缺 python3"; exit 2; }
[ -f "$PLIST" ] || info "容器 plist 还不存在（首次启动后会生成）—— 诊断行会显示读不出，不影响判定"
ok "App:$APP"
info "记忆键（诊断，可能滞后）:$(store_value)"

head2 "① 起点:清掉记忆 → 读实际几何（这就是「没有记录」时的默认）"
run_case clear || info "（clear 档没能确认自己退出）"
if [ -z "$LAST_REPORT" ]; then
    bad "没有任何报告 —— **该 .app 不认探针**"
    info "探针（WindowProbe）只在 2026-09-24 之后的 **Debug** 构建里:"
    info '  export PATH="/usr/local/bin:$PATH"'
    info '  xcodebuild -project Unroll.xcodeproj -scheme Unroll -configuration Debug \'
    info '    -destination "platform=macOS" -derivedDataPath ../Unroll-dist/DerivedData build'
    exit 2
fi
case "$LAST_REPORT" in *"mode=clear"*) ok "clear 档已执行:${LAST_REPORT}" ;;
*) bad "报告内容与指令不符:${LAST_REPORT}"; exit 2 ;;
esac

run_case report || info "（report 档没能确认自己退出）"
BASE="$(geo_of "$LAST_REPORT" frame)"
[ -n "$BASE" ] || { bad "报告里没有 frame=:${LAST_REPORT}"; exit 2; }
ok "无记录时的几何（BASE）:${BASE}"

head2 "② 正向:挪成一套别的几何 → 重启 → 看是否回到它"
run_case set || info "（set 档没能确认自己退出）"
T1="$(geo_of "$LAST_REPORT" actual)"
[ -n "$T1" ] || { bad "报告里没有 actual=:${LAST_REPORT}"; exit 2; }
ok "set 之后窗口实际几何（T1）:${T1}"

if [ "$(geo_equal "$BASE" "$T1")" = "same" ]; then
    bad "T1 与 BASE 相同（${T1}）—— **判据没有区分度**"
    info "此时「重启回到原处」这句话不构成证据。多半是 set 档没真的改动窗口，先修探针"
    exit 2
fi
ok "T1 ≠ BASE ⇒ 本判据**有区分度**（先证这个，再看下面的绿）"

run_case report || info "（report 档没能确认自己退出）"
AGAIN="$(geo_of "$LAST_REPORT" frame)"
[ -n "$AGAIN" ] || { bad "报告里没有 frame=:${LAST_REPORT}"; exit 2; }
if [ "$(geo_equal "$AGAIN" "$T1")" = "same" ]; then
    ok "重启后几何（AGAIN）= ${AGAIN} ⇒ **与 T1 一致:记忆生效**"
else
    bad "重启后几何（AGAIN）= ${AGAIN} ≠ T1（${T1}）⇒ 记忆**没有被恢复**"
    info "   要查两处:① 落盘那一步（didMove / 退出兜底）有没有执行;"
    info "   ② 恢复那一步有没有被 SwiftUI 随后的布局覆盖 —— WindowProbe 的 report 档"
    info "      刻意多等 0.8s 就是为了看见②（那个等待不是随手写的）"
fi

head2 "③ 反向对照:换成**第三套**几何 → 重启 → 必须跟着变，且不许还是 T1"
run_case set || info "（set 档没能确认自己退出）"
T2="$(geo_of "$LAST_REPORT" actual)"
[ -n "$T2" ] || { bad "报告里没有 actual=:${LAST_REPORT}"; exit 2; }
ok "第二次 set 之后窗口实际几何（T2）:${T2}"
if [ "$(geo_equal "$T1" "$T2")" = "same" ]; then
    bad "T2 与 T1 相同（${T2}）—— 这一轮造不出对照态，先修探针"
    exit 2
fi

run_case report || info "（report 档没能确认自己退出）"
AGAIN2="$(geo_of "$LAST_REPORT" frame)"
[ -n "$AGAIN2" ] || { bad "报告里没有 frame=:${LAST_REPORT}"; exit 2; }
if [ "$(geo_equal "$AGAIN2" "$T2")" = "same" ]; then
    ok "重启后几何（AGAIN2）= ${AGAIN2} ⇒ 跟着**当前**记录走"
else
    bad "重启后几何（AGAIN2）= ${AGAIN2} ≠ T2（${T2}）⇒ 恢复的不是当前记录"
fi
if [ "$(geo_equal "$AGAIN2" "$T1")" = "same" ]; then
    bad "AGAIN2 **等于 T1**（${AGAIN2}）—— 说明它记住的是「某一套固定几何」而不是当前记录"
    info "   ⇒ 上面那条绿不成立:判据分辨不出「记忆」与「固定值」"
else
    ok "AGAIN2 ≠ T1（${T1}）⇒ 不是「每次都回到某个固定值」，而是**真的跟着记录走**"
fi

head2 "收尾:把记忆清掉（之后「退出兜底写」可能又把当时几何填回去 —— 无害）"
run_case clear || info "（clear 档没能确认自己退出）"

head2 "结论"
printf '  BASE  （无记录）  %s\n' "$BASE"
printf '  T1    （set #1）  %s\n' "$T1"
printf '  AGAIN （重启）    %s   ← 必须等于 T1\n' "$AGAIN"
printf '  T2    （set #2）  %s\n' "$T2"
printf '  AGAIN2（重启）    %s   ← 必须等于 T2、且不等于 T1\n' "$AGAIN2"
if [ "$STATUS" = 0 ]; then
    ok "自管窗口记忆:**能写、能恢复、跟着记录走**（正向 + 反向对照都成立）"
else
    bad "有断言未通过 —— 见上面的 ✗"
fi
exit "$STATUS"
