#!/bin/bash
# ============================================================================
# probe-graceful-exit.sh —— 「退出链路」取证（⌘Q / 关窗口 / 强杀三条对照）
# ----------------------------------------------------------------------------
# 本脚本管的是**同一个问题的三种答案**：「App 是怎么结束这一次会话的？」
#   graceful → 用户按 ⌘Q（经响应者链发 terminate:）
#   close    → 用户关掉最后一个窗口（performClose:，与点红点 / ⌘W 同一条路）
#   abnormal → 进程被信号直接终结（强杀，作为反向对照）
#
# 为什么"关窗口"要单列一档（2026-09-28 补）：
#   `AppLifecycle` 的注释、`CrashReporter.endSession` 的注释、`ReaderViewModel` 里
#   「真正的释放点是换书 / 关窗」那条，以及设计文档 §5.10.3-② —— **四处**都写着
#   「关窗口 = 正常退出 / 释放」。但全工程**没有实现**
#   `applicationShouldTerminateAfterLastWindowClosed`，而 AppKit 对该**可选**方法的
#   默认值是 false ⇒ 关掉最后一个窗口**不会**退出 App，走不到 `applicationWillTerminate`，
#   `PageStore.teardown()` 也不会有人调（它只挂"换书"）。
#   ⇒ 四句声明没有一句在实现上成立。这一档就是去把这件事测出来，而不是继续把它
#     留在"注释里的承诺"状态。
#
# 为什么 ⌘Q 那一档以前走不到:
#   验优雅退出的常规做法是从外面发 ⌘Q —— `osascript -e 'tell app "Unroll" to quit'`
#   或 `NSRunningApplication.terminate()`。两者都经 **Apple Events**，而本 App 每次
#   重建都是 **ad-hoc 签名**，重建后 TCC 里那条授权就失效了，系统直接拒（实测
#   `-10004`）。这不是 App 缺陷，是没有 Developer ID 就要付的税。
#   于是只剩 `kill -TERM` —— 但信号走的是**异常**分支：进程被直接终结，
#   `applicationWillTerminate` 根本不会被调用，`session.json` 停在 `alive=true`。
#   它证明的恰恰是「异常退出下能被检出」，与「优雅退出会收尾」**方向相反**，
#   两条证据不能互相顶替（见 工程笔记(未随仓库发布) §11.5）。
#
# 怎么绕过的:不去绕 —— 让 **App 自己**发起退出。`DemoDriver` 的 `demo-quit` /
#   `demo-close` 两个场景都经**真实入口**发动作：前者用
#   `NSApp.sendAction(#selector(NSApplication.terminate(_:)), to: nil, from: nil)`
#   （与菜单「退出 Unroll」逐字相同），后者用 `NSWindow.performClose(_:)`
#   （与点红点 / ⌘W 逐字相同）。零授权、可重现。
#   ⚠️ 刻意**不**直接调 `NSApplication.terminate(_:)` / `NSWindow.close()`：
#      那会绕开"菜单有没有接线""窗口委托有没有拦"这两层，而接错线恰恰是这里
#      最该被验到的故障。
#
# ★ 反向对照（本脚本的另一半，比正向那半更重要）
#   「一个从不失败的守卫等于没有守卫，而它的失效方式是无声的」。
#   判据是「`alive=false` + 面包屑末条 `appTerminated`」—— 它**会不会红**？
#   由 `MODE=abnormal` 回答：不给标记文件、正常启动、先**观察到** `alive=true`，
#   再 `kill -TERM`。同样的 App、同样的磁盘、**唯一的差别是退出方式**。
#   若此时判据仍然全绿，说明这套判据根本分辨不出优雅与否 —— 那才是真问题。
#
# 用法:
#   ./Scripts/probe-graceful-exit.sh                  # ⌘Q 正向:App 自己发 terminate:
#   MODE=close ./Scripts/probe-graceful-exit.sh       # 关窗口:App 自己 performClose:
#   MODE=abnormal ./Scripts/probe-graceful-exit.sh    # 反向对照:强杀,断言**必须**红
#   APP=<Debug 版 .app> ./Scripts/probe-graceful-exit.sh
#
# 退出码: 0 = 通过；1 = 不通过；2 = 前置不满足（缺 .app / 缺驱动 / 缺 python3）
#
# ⚠️ 需要 **Debug** 版 App（`DemoDriver` 整个文件在 `#if DEBUG` 里）。默认路径见 APP。
#
# ⚠️ 两个标记文件(`demo-quit` / `demo-close`)是本脚本唯一会留下的危险物:它们一旦
#   残留,用户下次**正常**启动 App,App 起来就会自己退出 / 自己把窗口关掉。所以两道
#   防线:① 一确认驱动认到了场景就立刻删；② trap EXIT 再删一次。两层都要 ——
#   脚本可能被 Ctrl-C 死在一个中间状态。
#
# ⚠️ 反向模式会**故意**把 `alive=true` 留在磁盘上（那正是它要证明的东西）。
#   若不清掉，用户下次启动就会看到一次**假的**「上次异常退出」弹窗。
#   这就是 `reset_session` 必须挂在 trap 上、而不是只写在正向分支里的原因。
#
# ⚠️ 判"进程退没退"只能看**本脚本自己启动的那个 PID**，绝不能用 `pgrep -x Unroll`。
#   2026-09-24 实测撞上：机器上躺着一个**不响应 SIGTERM** 的残留 Unroll 进程
#   （来自 `~/Library/Developer/Xcode/DerivedData/…`，`lsof` 可见它被注入了
#   `libBacktraceRecording` / `libLogRedirect` —— 是上次 `xcodebuild test` 留下的
#   **测试宿主**，连发两次 `kill -TERM` 都收不掉）。
#   用名字判活，这条断言就**永远为假**：把正常状态报成故障，而报错里那句
#   "是不是另一个实例"恰好把人往错的方向指 —— 正是本项目记过的"守卫第二种失效"。
#   所以：启动前快照、启动后取差集，锁定我们自己的 PID，之后一律 `kill -0` 判它。
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Unroll"
VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}-dist}"
# 默认指向 **Debug** 产物（DemoDriver 只在 Debug 里编进去）——
# 这与 verify-ui.sh 默认指向冻结的 Release 产物**相反**，是刻意的：那个脚本验的是
# "发布出去的东西长什么样"，这个脚本验的是"App 自己那条代码路径走不走得通"。
APP="${APP:-$DIST_DIR/DerivedData/Build/Products/Debug/$APP_NAME.app}"
MODE="${MODE:-graceful}"

# 位置参数一律拒绝。跟 verify-ui.sh 同一个理由：APP= / MODE= 都是**环境变量**，
# 写成位置参数时脚本一个字都不读，于是**静默跑默认值** —— 而这种误导不会报错。
if [ "$#" -gt 0 ]; then
    echo "✗ 不接受位置参数:$*" >&2
    echo "  这两个是环境变量,要写在命令**前面**:" >&2
    echo "    MODE=graceful|close|abnormal APP=<Debug 版 .app> $0" >&2
    exit 2
fi

SUPPORT_DIR="$HOME/Library/Containers/com.gfredr.unroll/Data/Library/Application Support/Unroll"
SESSION="$SUPPORT_DIR/session.json"
CRUMBS="$SUPPORT_DIR/breadcrumbs.log"
# 目录可能还不存在（App 从未在本机跑过，或容器被清理过）—— 不先建好，
# 下面写 session 会报 "No such file or directory"（2026-09-16 实测踩到）
mkdir -p "$SUPPORT_DIR"

CONTAINER_TMP="$HOME/Library/Containers/com.gfredr.unroll/Data/tmp"
DRIVER_LOG="$CONTAINER_TMP/demo-driver.log"
QUIT_FLAG="$CONTAINER_TMP/demo-quit"
CLOSE_FLAG="$CONTAINER_TMP/demo-close"
mkdir -p "$CONTAINER_TMP"

STATUS=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*" >&2; STATUS=1; }
info() { echo "  · $*"; }
head2(){ echo ""; echo "── $* ─────────────────────────────────────"; }

# ---------------------------------------------------------------- 环境自检 --
head2 "环境自检"

if [ ! -d "$APP" ]; then
    bad "找不到被测的 .app:$APP"
    info "本脚本需要 **Debug** 版(驱动只在 #if DEBUG 里)。构建:"
    info "  xcodebuild build -project Unroll.xcodeproj -scheme Unroll \\"
    info "      -configuration Debug -destination 'platform=macOS' \\"
    info "      -derivedDataPath $DIST_DIR/DerivedData"
    exit 2
fi
ok "被测 App:$APP"

case "$MODE" in
graceful) ok "模式:⌘Q 正向(App 自己经响应者链发 terminate:)" ;;
close)    ok "模式:关窗口(App 自己 performClose: 主窗口 —— 与点红点 / ⌘W 同一条路)" ;;
abnormal) ok "模式:反向对照(强杀,断言必须红)" ;;
*) bad "MODE 只能是 graceful / close / abnormal,收到 '$MODE'"; exit 2 ;;
esac

# `session.json` 是 **JSONEncoder 写出来的纯 JSON**，`plutil` 读不了
# （实测报 `Unexpected character {`），所以这里只能是 python3。
# 缺了就报前置不满足，**不做降级** —— 用 sed 硬抠 `"alive":` 能跑通今天，
# 但字段顺序一变就会静默返回"读不到"，而"读不到"在这类脚本里最容易被当成通过。
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
    bad "缺 python3 —— 解析不了 session.json(纯 JSON,plutil 读不了)"
    info "不做降级:静默跳过等于假装验过"
    exit 2
fi
ok "python3 就绪"

# 窗口枚举小工具(编译一次复用)。**只给诊断段用**,所以缺了不算前置不满足 ——
# 但必须**说出来**:诊断段取不到数与"诊断段跑了、结果显示没窗口"是两回事,
# 而两者在输出里长得几乎一样(都是"窗口数 0")。这与 §13.9 那条同族。
WINID=""
if command -v swiftc >/dev/null 2>&1 && [ -f Scripts/winid.swift ]; then
    WINID="/tmp/probe-exit-winid"
    swiftc -O -o "$WINID" Scripts/winid.swift >/dev/null 2>&1 || WINID=""
fi
if [ -n "$WINID" ]; then
    ok "winid 就绪(诊断段用)"
else
    info "缺 swiftc 或 Scripts/winid.swift ⇒ 关窗之后的诊断段取不到窗口数"
    info "  (它**不参与判据**,只记录现象;不影响本脚本的红绿)"
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    info "本机已有 $APP_NAME 在跑,先收掉(否则标记文件会被那个实例吃掉)"
fi

# ------------------------------------------------------------------ 工具 --
quit_app() {
    for p in $(pgrep -x "$APP_NAME" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
    sleep 2
}

# 快照当前所有叫 Unroll 的 PID —— **只用来取差集**，不用来判活（理由见文件头）
snapshot_pids() { pgrep -x "$APP_NAME" 2>/dev/null | sort | tr '\n' ' '; }

# 本脚本启动的那个进程还活着吗。所有"退没退"的判定必须走这里，
# 这样别的实例在不在、响不响应信号，都与本轮的结论无关。
our_alive() { [ -n "${OUR_PID:-}" ] && kill -0 "$OUR_PID" 2>/dev/null; }

# 复位会话标记:alive=false 且清掉 suppressedVersion。
# 不这么做的话,脚本会给用户留下一次**假的**"上次异常退出"。
# 反向模式尤其依赖它 —— 那一模式**故意**留下 alive=true 作为证据。
reset_session() {
    local boot
    boot="$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+), usec = ([0-9]+).*/\1.\2/')"
    printf '{"alive":false,"version":"%s","build":"%s","bootTime":%s}' \
        "$VERSION" "$VERSION" "$boot" > "$SESSION"
}

cleanup_probe_flags() {
    # 本脚本只清**自己可能造出来**的那两个(它不会 touch 别的 `demo-*` 标记)。
    # ⚠️ "全集"在 `verify-ui.sh` 的 `cleanup_probe_flags` 里 —— 那份清单必须
    #    逐个列全**所有** `demo-*`,**包括本脚本这两个**。2026-09-28 补:此前两边
    #    都没有它们(见 verify-ui.sh 里那段注释记的第二次漏)，而残留的 `demo-close`
    #    比 `demo-quit` 更阴:用户下次正常启动,App 自己把窗口关掉(还不一定退出),
    #    现场看起来像"App 启动就抽风",与标记文件毫无关联。
    # ⚠️ 新增模式时最容易漏的就是这两处:变量加了、清理里忘了加。
    rm -f "$QUIT_FLAG" "$CLOSE_FLAG" 2>/dev/null || true
}

# 收尾时把我们自己启的那个进程清掉(若它还在)。
#
# 为什么必须做 —— 2026-09-28 实测踩到:`MODE=close` **判红**的那一轮,App 被留在
# "进程活着、但没有窗口"的状态里,而脚本就这么退出了。下一轮 `open -a` 会去**激活
# 那个既有实例**而不是起新的(同一个 bundle id),于是表现为"驱动 10 秒没出日志",
# 脚本报的是"被测产物不含驱动" —— 一个**指错方向**的报错,而真因在上一轮。
# 它属于本项目记过的"守卫第二种失效":失败会以另一种症状出现在下一轮。
#
# ⚠️ 只杀 OUR_PID(启动前后取差集锁定的那一个),不用名字一把梭 ——
#    机器上本来就有收不掉的同名残留(见文件头),按名字会误伤。
kill_our_leftover() {
    [ -n "${OUR_PID:-}" ] || return 0
    kill -0 "$OUR_PID" 2>/dev/null || return 0
    kill -TERM "$OUR_PID" 2>/dev/null
    for _ in $(seq 1 12); do
        kill -0 "$OUR_PID" 2>/dev/null || return 0
        sleep 0.25
    done
    kill -9 "$OUR_PID" 2>/dev/null || true
}

trap 'kill_our_leftover; cleanup_probe_flags; reset_session 2>/dev/null || true' EXIT

# 读磁盘状态:一个 python3 进程读两个文件,输出 `key=value` 行
# (与 git-tree-state.sh 同一契约,调用方用 sfield 取值)
read_state() {
    STATE="$(
        "$PY" - "$SESSION" "$CRUMBS" <<'PY' 2>/dev/null
import json, sys

# 「适不适用」与「过不过」要分两层报:文件读不了是**前置**问题,
# 不能跟"字段值不对"混成一句话报给用户(那会把"没测到"说成"测出问题")。
alive = "unreadable"
try:
    with open(sys.argv[1]) as f:
        alive = str(json.load(f).get("alive")).lower()
except Exception:
    alive = "unreadable"

crumbs = 0
last = "none"
launched = 0
try:
    with open(sys.argv[2]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            crumbs += 1
            try:
                name = json.loads(line).get("e")
            except Exception:
                name = "unparsable"
            if name == "appLaunched":
                launched += 1
            last = name
except Exception:
    last = "unreadable"

print("alive=" + alive)
print("crumbs=" + str(crumbs))
print("launched=" + str(launched))
print("last=" + str(last))
PY
    )"
}

# 取值前必须先 read_state(它刷新 STATE)。刻意不做成"自动刷新"的隐式行为:
# 隐式刷新在探测循环里会变成每 0.25 秒起一个 python,而沙箱下起进程是要花钱的。
sfield() { printf '%s\n' "$STATE" | sed -n "s/^$1=//p"; }

# 等进程消失或出现某个日志行。$1 = 秒数上限,$2 = 判据命令(字符串)
wait_until() {
    local limit="$1" probe="$2"
    for _ in $(seq 1 $(( limit * 4 ))); do
        eval "$probe" && return 0
        sleep 0.25
    done
    return 1
}

# 断言:相等 / 不等。反向模式要的是**反向**的期望,所以两个都得有。
expect_eq() {
    if [ "$3" = "$2" ]; then ok "$1 = $3"; else bad "$1 = $3,期望 $2"; fi
}
expect_ne() {
    if [ "$3" != "$2" ]; then ok "$1 = $3(≠ $2)"; else bad "$1 = $3,本应≠ $2"; fi
}

# 关窗之后进程若还在,试着**从外面**把窗口叫回来 —— 走的正是用户点 Dock 图标那条路
# (对已在运行的实例再发一次 open,LaunchServices 转成 reopen 事件)。
#
# ⚠️ 这一段**只记录、不断言**,也不改 STATUS。理由是它问的是一个**设计选择**层面的
#    问题,而不是一条对错:
#      · 若选定语义是「关窗即退出」,那"关完之后还能不能重开"就是个**不该被问到**的
#        问题 —— 拿它当断言,等于把两个互斥的设计选择压进同一条红绿;
#      · 但它恰恰是"要不要选退出"这个决定的**证据**。少了它,"关完就成僵尸"只是推测,
#        而本项目有条规矩:别把推测写成注释。
#    所以它必须跑,但跑出来的结论只用来写文档,不用来判分。
try_reopen_and_report() {
    head2 "诊断(不参与判据):关窗之后还能不能把窗口找回来"
    if [ -z "$WINID" ]; then
        info "缺 winid ⇒ 这一段取不到数。**这不是「没有窗口」,是没测**"
        return 0
    fi
    local before after
    before="$("$WINID" "$APP_NAME" 2>/dev/null | wc -l | tr -d ' ')"
    info "reopen 之前:屏上属于 $APP_NAME 的普通窗口数 = $before"
    open -a "$APP"
    sleep 4
    after="$("$WINID" "$APP_NAME" 2>/dev/null | wc -l | tr -d ' ')"
    info "reopen 之后:屏上属于 $APP_NAME 的普通窗口数 = $after"
    if [ "$before" = "0" ] && [ "$after" = "0" ]; then
        info "⇒ 窗口**没有**回来:关掉窗口之后这个 App 只剩菜单栏与 Dock 图标,"
        info "  没有任何入口能把窗口找回来(菜单的「新建」组已被替换成「打开」,没有 ⌘N)。"
        info "  ⇒ 「关窗即退出」不只是让声明成真,它同时消掉了这个死角。"
    elif [ "$after" -gt "$before" ] 2>/dev/null; then
        info "⇒ 窗口**回来了**:「关窗后驻留」这套语义是自洽的,Dock 点得回来。"
        info "  ⇒ 那么要修的不是「能不能回来」,而是那四句写着「关窗 = 退出 / 释放」的声明本身。"
    else
        info "⇒ 窗口数没变($before → $after) —— 两种可能分不开:本来就有窗口,或没回来。"
        info "  这个结果**不足以支持任何结论**,不要拿它去写文档。"
    fi
}

# ================================================================== 开始 ==
head2 "清场"

quit_app
# `kill -TERM` 是**尽力而为** —— 本机实测存在收不掉的残留(见文件头那段)。
# 收不掉的不影响结论(下面一律按 PID 判定),但必须说出来:
# 不说的话,单看后面的 ✓,"清场成功"这句就是假的。
STALE="$(snapshot_pids)"
if [ -n "$STALE" ]; then
    info "仍有收不掉的 $APP_NAME 进程:$STALE"
    info "  (非本脚本启动 ⇒ 与本轮结论无关;一律按 PID 判定,不按名字)"
fi
# 清掉上一次的痕迹:面包屑是**内存 ring buffer 整体回写**的,不清就会把
# "上次会话的尾巴"当成本次的证据读(2026-09-16 误判过一次,白查一轮代码)
rm -f "$CRUMBS" "$DRIVER_LOG"
reset_session
ok "已清场(breadcrumbs / driver.log 已删,session 复位为 alive=false)"

head2 "启动"

# 启动前先记下"已经有哪些同名进程" —— 启动后靠差集认出**我们自己**启的那个。
# 这一步是必须的,不是防御性编程:本机真的躺着一个收不掉的残留实例(见文件头)。
BEFORE_PIDS="$(snapshot_pids)"

case "$MODE" in
graceful)
    touch "$QUIT_FLAG"
    ok "已放标记:$QUIT_FLAG(场景 demo-quit)"
    ;;
close)
    touch "$CLOSE_FLAG"
    ok "已放标记:$CLOSE_FLAG(场景 demo-close)"
    ;;
*)
    # 反向对照**不放**标记:App 就这么正常待着,不驱动任何场景。
    # 这样"优雅与否"的差别被压到唯一一个变量上 —— 退出方式。
    info "未放标记:App 将正常空转,随后被 kill -TERM"
    ;;
esac
open -a "$APP"

# ------------------------------------------------------------ 前提确认 --
# 不做这一步的话,"App 没起来"会被后面的断言算成"验过了" ——
# 这是"空转产生假绿"的经典形态,而它恰好只在这类外部驱动脚本里出现。

head2 "前提确认"

# 锁定**我们自己**启动的那个进程:启动后出现的、启动前不在的那个 PID。
# 之后所有"退没退"都只看它 —— 别的同名进程在不在,与本轮结论无关。
OUR_PID=""
for _ in $(seq 1 60); do            # 上限 15s
    for p in $(pgrep -x "$APP_NAME" 2>/dev/null); do
        case " $BEFORE_PIDS " in
        *" $p "*) ;;                # 启动前就在 ⇒ 不是我们启的,跳过
        *) OUR_PID="$p"; break 2 ;;
        esac
    done
    sleep 0.25
done
if [ -z "$OUR_PID" ]; then
    bad "15 秒内没有出现新的 $APP_NAME 进程 —— 后面前提不成立"
    info "启动前就已存在的同名进程:$BEFORE_PIDS"
    info "  它们不是本脚本启动的,不能拿来顶替"
    exit 2
fi
ok "本脚本启动的进程:PID $OUR_PID"

# 先**观察到** `alive=true` 才有资格谈它后来有没有变成 false。
ALIVE_SEEN=""
for _ in $(seq 1 40); do            # 上限 10s
    read_state
    ALIVE_SEEN="$(sfield alive)"
    [ "$ALIVE_SEEN" = "true" ] && break
    # 进程已经没了就别再干等:那不是"还没写",而是"起不来"
    our_alive || break
    sleep 0.25
done
if [ "$ALIVE_SEEN" != "true" ]; then
    # 两种原因分开报 —— 它们要的修法完全相反:
    # 前者是"会话没写",后者是"进程根本没活着",混成一句话会把人指向错的地方
    if our_alive; then
        bad "启动后 session.json 的 alive 不是 true(读到 '$ALIVE_SEEN')"
        info "会话没开始 ⇒ 后面「变成 false」无从谈起,就此止步"
    else
        bad "进程 PID $OUR_PID 起来之后又没了,而会话标记始终没写成 true"
        info "这是**启动失败**(崩溃 / 被拦下),不是退出链路的结论"
    fi
    info "session.json:$(cat "$SESSION" 2>/dev/null || echo '(读不到)')"
    exit 2
fi
ok "已观察到 alive=true(会话已开始)"

# ================================================================ 退出 ==
head2 "退出"

# 两个终结型模式(⌘Q / 关窗口)共用这一整段:等驱动认到场景 → 立刻删标记 → 等进程自己退。
# 合起来写是刻意的:它俩的**失败形态逐字相同**(都是"约定该退出却没退"),抄两份必然漂移 ——
# 而这类脚本漂移时是静默的(两边的判据看上去都还在),正是本项目记过的"守卫第二种失效"。
if [ "$MODE" != "abnormal" ]; then
    if [ "$MODE" = "graceful" ]; then
        SCENE="demo-quit";  FLAG="$QUIT_FLAG";  WAY="⌘Q(经响应者链发 terminate:)"
    else
        SCENE="demo-close"; FLAG="$CLOSE_FLAG"; WAY="关窗口(performClose: 主窗口)"
    fi
    info "本模式约定的退出路径:$WAY"

    # 等驱动认到场景。这一段同时是**产物是否含驱动**的判据:
    # DemoDriver 挂在视图 onAppear 上,App 一起来就会写第一行。
    if ! wait_until 10 "grep -qF 'scene=$SCENE' '$DRIVER_LOG' 2>/dev/null"; then
        if [ -f "$DRIVER_LOG" ]; then
            bad "驱动起来了但没进入 $SCENE 场景(日志里没有 scene=$SCENE)"
            info "标记文件在不在:$([ -f "$FLAG" ] && echo 在 || echo 不在)"
            info "日志尾部:"
            tail -5 "$DRIVER_LOG" | sed 's/^/      /'
            exit 1
        fi
        bad "10 秒内没有出现驱动日志 —— 被测产物不含驱动(仅 DEBUG 编译)"
        info "当前 APP=$APP"
        exit 2
    fi
    ok "驱动已进入 $SCENE 场景"
    # 安全网第一层:驱动已经把场景读进内存了(activeScene 只在 onAppear 时读一次),
    # 此刻删掉标记不影响本次运行,但能保证"脚本无论怎么死,用户下次启动不会自杀"。
    rm -f "$FLAG"
    ok "标记已删(安全网第一层)"

    # 等进程自己退。**同时盯那两条"自证行"** —— 它们一旦出现,就说明约定的退出路径
    # 没生效,这时该立刻报错,而不是干等到超时(超时看不出是哪一种坏)。
    #
    # ⚠️ 两类自证行必须**分开**:它们要的处置完全相反 ——
    #   · `close: FATAL 没有可见的主窗口可关` 是**前提**不成立(窗口还没画出来),
    #     此时**什么都没测到**,报"关窗没退出"就是冤枉;
    #   · `quit: FATAL` / `close: ALIVE` 是**结论性**故障(动作发出去了,进程还在)。
    #   混成一个标志位,前提失败会被写成"测出一条缺陷" —— 这正是本项目反复记的那类错。
    PREMISE=0
    BROKEN=0
    for _ in $(seq 1 120); do            # 上限 30s
        if grep -qF 'close: FATAL' "$DRIVER_LOG" 2>/dev/null; then PREMISE=1; break; fi
        if grep -qE 'quit: FATAL|close: ALIVE' "$DRIVER_LOG" 2>/dev/null; then BROKEN=1; break; fi
        our_alive || break
        sleep 0.25
    done
    sleep 0.3                            # 让最后一次落盘落完

    if [ "$PREMISE" = "1" ]; then
        bad "驱动报「没有可见的主窗口可关」—— 本场景的**前提**不成立,本轮什么都没测到"
        grep -F 'close:' "$DRIVER_LOG" | sed 's/^/      /'
        info "这不是「关窗没退出」那个结论 —— 是窗口还没画出来就开始关了"
        our_alive && kill -TERM "$OUR_PID" 2>/dev/null   # 别把它留给下一轮
        exit 2
    fi
    if [ "$BROKEN" = "1" ]; then
        bad "日志里出现了「动作已发出但进程仍在」的自证行:"
        grep -E 'quit: FATAL|close: ALIVE' "$DRIVER_LOG" | sed 's/^/      /'
        if [ "$MODE" = "close" ]; then
            info "⇒ 关掉最后一个窗口之后进程还活着。工程里没有"
            info "  applicationShouldTerminateAfterLastWindowClosed,而 AppKit 对它的默认是 false"
        else
            info "⇒ terminate: 没被响应者链接住(或 NSApp 为 nil)"
        fi
    fi
    if our_alive; then
        if [ "$MODE" = "close" ]; then
            bad "30 秒后 PID $OUR_PID 仍在 —— **关掉最后一个窗口没有让 App 退出**"
        else
            bad "30 秒后 PID $OUR_PID 仍在 —— terminate: 没有生效"
        fi
        info "判据只认本脚本启动的那个进程;机器上别的同名进程与本条无关"
        # 进程还在 ⇒ 那个问题才有意义:**它还能不能把窗口找回来?** 只记录,不断言。
        if [ "$MODE" = "close" ]; then
            try_reopen_and_report
        fi
    else
        ok "本脚本启动的进程已退出(PID $OUR_PID)"
    fi

    # 「驱动把动作发出去了」这条证据 —— 两个模式各有一句，**在调用之前**写下的那句
    # （理由见 DemoDriver 里的注释:关窗可能同步终结进程,之后写不到）。
    ACT_SEEN=0
    if [ "$MODE" = "close" ]; then
        grep -qF 'close: performClose' "$DRIVER_LOG" 2>/dev/null && ACT_SEEN=1
        expect_eq "驱动已走到 performClose 那一步(日志)" "1" "$ACT_SEEN"
    else
        grep -qF 'quit: sendAction(terminate:) now' "$DRIVER_LOG" 2>/dev/null && ACT_SEEN=1
        expect_eq "驱动已走到 sendAction 那一步(日志)" "1" "$ACT_SEEN"
    fi
else
    # 反向对照:同一份 App、同一份磁盘,只把"退出方式"换成强杀。
    # `kill -TERM` 走的是异常分支 —— `applicationWillTerminate` 不会被调用,
    # 于是会话标记应当**停在** alive=true,面包屑里不该有 appTerminated。
    #
    # ⚠️ 只杀**我们自己启动的那个 PID**,不用 quit_app 一把梭:
    #    一把梭会让"到底杀到了没"说不清(机器上还有别的同名进程),
    #    而反向对照的全部价值就在于**每个变量都是确定的**。
    kill -TERM "$OUR_PID" 2>/dev/null
    for _ in $(seq 1 40); do our_alive || break; sleep 0.25; done
    if our_alive; then
        # 连 SIGTERM 都收不掉 ⇒ "异常退出"根本没发生,这个对照不成立
        bad "PID $OUR_PID 不响应 SIGTERM —— 反向对照的前提不成立,本轮结论无效"
        exit 2
    fi
    ok "已 kill -TERM 收掉 PID $OUR_PID(异常退出)"
    sleep 0.3
fi

# ============================================================ 磁盘判据 ==
head2 "磁盘判据"

read_state
ALIVE="$(sfield alive)"
LAST="$(sfield last)"
LAUNCHED="$(sfield launched)"
CRUMBS_N="$(sfield crumbs)"

info "session.json:$(cat "$SESSION" 2>/dev/null || echo '(读不到)')"
info "breadcrumbs.log 末条:$(tail -1 "$CRUMBS" 2>/dev/null || echo '(读不到)')"

# 反空转:这份面包屑必须是**本次会话**写的。否则读到的可能是残留文件,
# 而残留文件恰好长得"像那么回事"——那才是最难查的一类假绿。
if [ "$LAUNCHED" -ge 1 ] 2>/dev/null; then
    ok "面包屑里有 appLaunched ×$LAUNCHED(这份文件是本次会话写的)"
else
    bad "面包屑里没有 appLaunched(共 $CRUMBS_N 条)—— 读到的不是本次会话,后续断言不成立"
fi

# 两个终结型模式的判据**逐字相同**(关窗 = 退出,与 ⌘Q 没有区别)——
# 这正是本次要立的规矩:两种入口、一套收尾。
if [ "$MODE" != "abnormal" ]; then
    expect_eq "session.json 的 alive" "false" "$ALIVE"
    expect_eq "面包屑末条事件" "appTerminated" "$LAST"
else
    # 反向对照:断言**必须**红。全绿就说明这套判据分辨不出优雅与否,
    # 那比"测出一条失败"严重得多 —— 它意味着那个正向结论是白给的。
    expect_eq "session.json 的 alive(反相应保持 true)" "true" "$ALIVE"
    expect_ne "面包屑末条事件(反相不该是 appTerminated)" "appTerminated" "$LAST"
fi

# ================================================================ 结论 ==
head2 "结论"

if [ "$MODE" = "graceful" ]; then
    if [ "$STATUS" -eq 0 ]; then
        echo "  ✓ 优雅退出链路成立:App 经响应者链发 terminate: → applicationWillTerminate →"
        echo "    alive=false + 面包屑末条 appTerminated。这条链路此前在本机从未被走到过。"
    else
        echo "  ✗ 有断言未通过 —— 优雅退出的收尾没有发生。"
    fi
elif [ "$MODE" = "close" ]; then
    if [ "$STATUS" -eq 0 ]; then
        echo "  ✓ 关窗口也走同一条收尾:performClose: 主窗口 → applicationWillTerminate →"
        echo "    alive=false + 面包屑末条 appTerminated。"
        echo "    ⇒ 那四处「关窗 = 退出 / 释放」的声明**从注释变成了实现**,并被一条判据钉住。"
    else
        echo "  ✗ 关掉最后一个窗口之后 App 没有退出 ⇒「关窗 = 正常退出」在实现上不成立,"
        echo "    那四句声明是错的。修法见本脚本文件头;修完必须回来重跑这一档。"
    fi
else
    if [ "$STATUS" -eq 0 ]; then
        echo "  ✓ 反向对照成立:换成强杀之后,同两条断言**当场变红**"
        echo "    (alive 停在 true、末条不是 appTerminated) ⇒ 正向那两个判据不是白给的。"
    else
        echo "  ✗ 反向对照失败:强杀之下判据竟然仍然是绿的 —— **这套判据是瞎的**。"
        echo "    它分辨不出优雅退出与异常退出,因此正向那条结论不成立。"
    fi
fi
echo ""
if our_alive; then
    echo "残留检查:PID $OUR_PID 仍在跑 —— 需处理"
else
    echo "残留检查:本脚本启动的进程(PID $OUR_PID)已不在"
fi
LEFT="$(snapshot_pids)"
if [ -n "$LEFT" ]; then
    echo "           另发现同名进程:$LEFT(非本脚本启动,已忽略)"
fi
if [ -f "$QUIT_FLAG" ] || [ -f "$CLOSE_FLAG" ]; then
    echo "           ⚠️ 标记文件还在 —— 必须删掉,否则用户下次启动 App 会自己退出 / 自己关窗"
    [ -f "$QUIT_FLAG" ]  && echo "             · $QUIT_FLAG"
    [ -f "$CLOSE_FLAG" ] && echo "             · $CLOSE_FLAG"
else
    echo "           demo-quit / demo-close 两个标记都已清"
fi
echo ""

# 本脚本**仍然没有覆盖**的退出入口(如实登记,免得下次又把它们当成"验过了")。
# ⚠️ 2026-09-28 起"关窗口"不在这张单子上了 —— 它已经由 MODE=close 真跑并判据化。
#    这正是本章的意义:**"未覆盖"这张清单是会缩短的**,每缩一条都得说清是被什么替代的。
#
#   ① 真实**按键事件**本身:⌘Q 与 ⌘W 走的都是直接调 action / `performClose`,
#      没有经 CGEvent 真按一下 —— 那需要辅助功能授权(TCC),重建签名后即失效
#      (实测报 -10004 / 1002)。验到的是"那两个 action 的落点与收尾",
#      不是"键位绑定对不对"。键位绑定归 `UnrollTests/MenuStructureTests.swift`
#      (30 处 keyEquivalent 断言)与系统默认菜单管 —— 两件事别混。
#   ② **注销 / 重启**:macOS 会让 App 走 `applicationShouldTerminate` 再退。
#      它与用户主动退出**不是同一条路**(可能被 App 拦下、也可能被系统超时强杀),
#      本机没验过 —— 要验得真注销一次,不在自动化范围内。
echo "未覆盖(如实登记):① 真实按键事件(⌘Q / ⌘W 走的是 action,不是 CGEvent);"
echo "  ② 注销 / 重启时的 applicationShouldTerminate 分支。"
echo ""

exit "$STATUS"
