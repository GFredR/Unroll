#!/bin/bash
# ============================================================================
# probe-graceful-exit.sh —— 「优雅退出」链路取证（2026-09-24 新增）
# ----------------------------------------------------------------------------
# 这条链路此前**在本机从来没被走到过**，于是它长期只是文档里的一句承诺。
#
# 为什么以前走不到:
#   验优雅退出的常规做法是从外面发 ⌘Q —— `osascript -e 'tell app "Unroll" to quit'`
#   或 `NSRunningApplication.terminate()`。两者都经 **Apple Events**，而本 App 每次
#   重建都是 **ad-hoc 签名**，重建后 TCC 里那条授权就失效了，系统直接拒（实测
#   `-10004`）。这不是 App 缺陷，是没有 Developer ID 就要付的税。
#   于是只剩 `kill -TERM` —— 但信号走的是**异常**分支：进程被直接终结，
#   `applicationWillTerminate` 根本不会被调用，`session.json` 停在 `alive=true`。
#   它证明的恰恰是「异常退出下能被检出」，与「优雅退出会收尾」**方向相反**，
#   两条证据不能互相顶替（见 工程笔记(未随仓库发布) §11.5）。
#
# 怎么绕过的:不去绕 —— 让 **App 自己**发起退出。`DemoDriver` 的 `demo-quit` 场景
#   经**响应者链**发 `terminate:`（`NSApp.sendAction(#selector(NSApplication.terminate(_:)),
#   to: nil, from: nil)`），与菜单里那个「退出 Unroll」项逐字相同。零授权、可重现。
#   ⚠️ 刻意**不**直接调 `NSApplication.terminate(_:)`：那会绕开"菜单有没有接上线"
#      这一层，而菜单接错线恰恰是这里最该被验到的故障。
#
# ★ 反向对照（本脚本的另一半，比正向那半更重要）
#   「一个从不失败的守卫等于没有守卫，而它的失效方式是无声的」。
#   本脚本的判据是「`alive=false` + 面包屑末条 `appTerminated`」—— 它**会不会红**？
#   由 `MODE=abnormal` 回答：不给标记文件、正常启动、先**观察到** `alive=true`，
#   再 `kill -TERM`。同样的 App、同样的磁盘、**唯一的差别是退出方式**。
#   若此时判据仍然全绿，说明这套判据根本分辨不出优雅与否 —— 那才是真问题。
#
# 用法:
#   ./Scripts/probe-graceful-exit.sh                  # 正向:App 自己发 terminate:
#   MODE=abnormal ./Scripts/probe-graceful-exit.sh    # 反向对照:强杀,断言**必须**红
#   APP=<Debug 版 .app> ./Scripts/probe-graceful-exit.sh
#
# 退出码: 0 = 通过；1 = 不通过；2 = 前置不满足（缺 .app / 缺驱动 / 缺 python3）
#
# ⚠️ 需要 **Debug** 版 App（`DemoDriver` 整个文件在 `#if DEBUG` 里）。默认路径见 APP。
#
# ⚠️ `demo-quit` 标记文件是本脚本唯一会留下的危险物：它一旦残留，用户下次**正常**
#   启动 App，App 起来就自己退出。所以两道防线：① 一确认驱动认到了场景就立刻删；
#   ② trap EXIT 再删一次。两层都要 —— 脚本可能被 Ctrl-C 死在一个中间状态。
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
    echo "    MODE=graceful|abnormal APP=<Debug 版 .app> $0" >&2
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
graceful) ok "模式:正向(App 自己经响应者链发 terminate:)" ;;
abnormal) ok "模式:反向对照(强杀,断言必须红)" ;;
*) bad "MODE 只能是 graceful 或 abnormal,收到 '$MODE'"; exit 2 ;;
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
    # ⚠️ **DemoDriver.Scene 加一个 case → 本行就必须加一个文件名**。
    #    这里只列本脚本用得上的那个:其余的 `demo-*` 归 verify-ui.sh 管,
    #    两边各删各的会互相踩(一个脚本收尾时把另一个正在等的标记删掉)。
    rm -f "$QUIT_FLAG" 2>/dev/null || true
}

trap 'cleanup_probe_flags; reset_session 2>/dev/null || true' EXIT

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

if [ "$MODE" = "graceful" ]; then
    touch "$QUIT_FLAG"
    ok "已放标记:$QUIT_FLAG(场景 demo-quit)"
else
    # 反向对照**不放**标记:App 就这么正常待着,不驱动任何场景。
    # 这样"优雅与否"的差别被压到唯一一个变量上 —— 退出方式。
    info "未放标记:App 将正常空转,随后被 kill -TERM"
fi
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

if [ "$MODE" = "graceful" ]; then
    # 等驱动认到场景。这一段同时是**产物是否含驱动**的判据:
    # DemoDriver 挂在视图 onAppear 上,App 一起来就会写第一行。
    if ! wait_until 10 "grep -qF 'scene=demo-quit' '$DRIVER_LOG' 2>/dev/null"; then
        if [ -f "$DRIVER_LOG" ]; then
            bad "驱动起来了但没进入退出场景(日志里没有 scene=demo-quit)"
            info "标记文件在不在:$([ -f "$QUIT_FLAG" ] && echo 在 || echo 不在)"
            info "日志尾部:"
            tail -5 "$DRIVER_LOG" | sed 's/^/      /'
            exit 1
        fi
        bad "10 秒内没有出现驱动日志 —— 被测产物不含驱动(仅 DEBUG 编译)"
        info "当前 APP=$APP"
        exit 2
    fi
    ok "驱动已进入 demo-quit 场景"
    # 安全网第一层:驱动已经把场景读进内存了(activeScene 只在 onAppear 时读一次),
    # 此刻删掉标记不影响本次运行,但能保证"脚本无论怎么死,用户下次启动不会自杀"。
    rm -f "$QUIT_FLAG"
    ok "标记已删(安全网第一层)"

    # 等进程自己退。**同时盯 FATAL 那行** —— 它一旦出现就说明 terminate: 没被
    # 响应者链接住,这时该立刻报错,而不是干等到超时(超时看不出是哪一种坏)。
    QUIT_FATAL=0
    for _ in $(seq 1 120); do            # 上限 30s
        if grep -qF 'quit: FATAL' "$DRIVER_LOG" 2>/dev/null; then QUIT_FATAL=1; break; fi
        our_alive || break
        sleep 0.25
    done
    sleep 0.3                            # 让最后一次落盘落完

    if [ "$QUIT_FATAL" = "1" ]; then
        bad "日志里出现了 'quit: FATAL 已发出 terminate: 但进程仍然活着'"
        info "⇒ terminate: 没被响应者链接住(或 NSApp 为 nil) —— 这正是本场景要抓的故障"
    fi
    if our_alive; then
        bad "30 秒后 PID $OUR_PID 仍在 —— terminate: 没有生效"
        info "判据只认本脚本启动的那个进程;机器上别的同名进程与本条无关"
    else
        ok "本脚本启动的进程已退出(PID $OUR_PID)"
    fi

    SEND_SEEN=0
    grep -qF 'quit: sendAction(terminate:) now' "$DRIVER_LOG" 2>/dev/null && SEND_SEEN=1
    expect_eq "驱动已走到 sendAction 那一步(日志)" "1" "$SEND_SEEN"
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

if [ "$MODE" = "graceful" ]; then
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
if [ -f "$QUIT_FLAG" ]; then
    echo "           ⚠️ demo-quit 标记还在 —— 必须删掉,否则用户下次启动 App 会自杀"
else
    echo "           demo-quit 标记已清"
fi
echo ""

# ⚠️ 本脚本**没有覆盖**的一条分支:"关窗口"。
#   `UnrollApp.swift` 的注释写着「⌘Q / 关窗口写 alive = false」,但全工程
#   **没有实现** `applicationShouldTerminateAfterLastWindowClosed`(Grep 零匹配),
#   而 AppKit 对该可选方法的默认是 false ⇒ 关掉最后一个窗口**不会**退出 App,
#   也就走不到 `applicationWillTerminate`。所以那句话对"关窗口"这半截是**存疑**的,
#   已登记待办;要验它得先补一个「关窗口」场景(同样可由 DemoDriver 驱动)。
echo "未覆盖(如实登记):「关窗口」分支。代码里没有 applicationShouldTerminateAfterLastWindowClosed,"
echo "  按 AppKit 默认关掉最后一个窗口不会退出 App —— 见本脚本末尾注释。"
echo ""

exit "$STATUS"
