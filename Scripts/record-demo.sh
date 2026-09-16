#!/bin/bash
# AI-Generated | 可修改
# record-demo.sh —— 录制 README 的演示 GIF
# ============================================================================
# 做法:用 DEBUG 版 App 的演示驱动(DemoDriver,-demoScript/标记文件触发)
#       自动翻页,同时用 screencapture 只录「Unroll 窗口所在的矩形」。
#
# 为什么不用 osascript/CGEvent 注入按键:那需要「辅助功能」授权,属于系统安全
# 边界,不该去绕。让 App 自己驱动 ViewModel 反而零授权、每次录出来一模一样。
#
# 为什么不用 screencapture -l(窗口捕获):实测它只对「静态截图」有效,视频录制
# (-v/-V)会**静默忽略** -l 改录全屏 —— 那样会拍进整个桌面,不可接受。
#
# 前置:
#   1) swift Scripts/gen_demo_sample.swift   生成演示样本(仓库外 Unroll-demo/)
#   2) swift build / xcodebuild 构出 **Debug** 版(演示驱动仅 DEBUG 编译)
#   3) ffmpeg
#
# 跑法(需要非沙箱 —— 要 killall/screencapture/defaults):
#   bash Scripts/record-demo.sh
#   可选环境变量: UNROLL_APP / UNROLL_SAMPLE / GIF_WIDTH / GIF_FPS
# ============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${UNROLL_APP:-$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Unroll-*/Build/Products/Debug/Unroll.app 2>/dev/null | head -1)}"
SAMPLE="${UNROLL_SAMPLE:-$REPO/../Unroll-demo/demo.cbz}"
OUT_DIR="$REPO/docs"
GIF_WIDTH="${GIF_WIDTH:-960}"
GIF_FPS="${GIF_FPS:-12}"
BUNDLE_ID="com.gfredr.unroll"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
TMPDIR_APP="$CONTAINER/tmp"
DURATION="${DURATION:-10}" # 录制时长(演示序列本体约 8.3s,余量留给封面静止)

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. 前置检查 -----------------------------------------------------------
command -v ffmpeg >/dev/null || die "缺少 ffmpeg(brew install ffmpeg)"
[ -n "$APP" ] && [ -d "$APP" ] || die "找不到 Debug 版 App;先构建,或用 UNROLL_APP 指定"
[ -f "$SAMPLE" ] || die "找不到演示样本 $SAMPLE;先跑 swift Scripts/gen_demo_sample.swift"
[ -f "$REPO/Scripts/winid.swift" ] || die "缺少 Scripts/winid.swift(窗口定位)"
mkdir -p "$OUT_DIR"
say "App    : $APP"
say "样本   : $SAMPLE"

# --- 1. 现场保护:备份 App 偏好(演示会改窗口尺寸,收尾要还原) --------------
PREFS_BAK="$(mktemp -t unroll-prefs)"
defaults export "$BUNDLE_ID" "$PREFS_BAK" 2>/dev/null || true
restore() {
    [ -s "$PREFS_BAK" ] && defaults import "$BUNDLE_ID" "$PREFS_BAK" >/dev/null 2>&1 || true
    rm -f "$PREFS_BAK"
}
trap restore EXIT

# --- 2. 退出旧实例 + 复位会话(否则可能录进「上次异常退出」弹窗) ------------
killall Unroll 2>/dev/null || true
sleep 1
if [ -f "$CONTAINER/Library/Application Support/Unroll/session.json" ]; then
    python3 - "$CONTAINER/Library/Application Support/Unroll/session.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d["alive"] = False
p.write_text(json.dumps(d))
PY
fi
mkdir -p "$TMPDIR_APP"
rm -f "$TMPDIR_APP/demo-driver.log"

# --- 3. 放演示标记 + 启动(一次 open 同时给样本;参数走标记文件不走 argv) ----
touch "$TMPDIR_APP/demo-enabled"
say "启动 App 并打开样本…"
open -a "$APP" "$SAMPLE"

# --- 4. 等演示真正开始(同步点用驱动日志的 "run start",比 sleep 可靠) ----
LOG="$TMPDIR_APP/demo-driver.log"
say "等演示开始…"
for _ in $(seq 1 250); do
    [ -f "$LOG" ] && grep -q "run start" "$LOG" && break
    sleep 0.1
done
grep -q "run start" "$LOG" 2>/dev/null || die "演示没启动起来;看日志 $LOG"
grep -q "fullscreen toggled" "$LOG" || say "⚠️  没看到全屏标记,可能录到窗口模式"

# --- 5. 录制(App 已全屏 → 整屏就是 App 内容,不含桌面) --------------------
RAW="$OUT_DIR/demo-raw.mov"
rm -f "$RAW"
say "录制 ${DURATION}s…"
screencapture -x -V "$DURATION" "$RAW"
[ -s "$RAW" ] || die "录制失败"

# --- 6. 转 GIF(两级调色板,别用默认 —— 默认会糊) -------------------------
GIF="$OUT_DIR/demo.gif"
say "转 GIF(宽 $GIF_WIDTH / $GIF_FPS fps)…"
# 本机右下角常驻一块 macOS「辅助功能控制面板」(AssistiveControl Panel,80x71)。
# 全屏录制会把它录进去;它正好落在页面的黑边区域里,所以用同色方块盖掉即可 ——
# 视觉上完全无痕(那里本来就是纯黑)。
# 不需要覆盖时:COVER_CORNER=0 bash Scripts/record-demo.sh
VF="fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos"
if [ "${COVER_CORNER:-1}" = "1" ]; then
    VF="$VF,drawbox=x=iw*0.92:y=ih*0.85:w=iw*0.08:h=ih*0.15:color=black:t=fill"
fi
VF="$VF,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"
ffmpeg -y -v error -i "$RAW" -vf "$VF" -loop 0 "$GIF"

# --- 7. 抽两帧留作备用静态素材 --------------------------------------------
# 时间点按演示时间轴(封面停 1.6s,之后每页 0.9s;双页跨页在 4.3s 之后)。
# 输出到**仓库之外**,和演示样本作伴 —— 这两张是副产品,README 并不引用,
# 放进 docs/ 只会让仓库多出几百 KB 而没人用。
STILL_DIR="$(dirname "$SAMPLE")/stills"
mkdir -p "$STILL_DIR"
STILL_VF="scale=1600:-1:flags=lanczos"
if [ "${COVER_CORNER:-1}" = "1" ]; then
    STILL_VF="$STILL_VF,drawbox=x=iw*0.92:y=ih*0.85:w=iw*0.08:h=ih*0.15:color=black:t=fill"
fi
ffmpeg -y -v error -ss 5.8 -i "$RAW" -vf "$STILL_VF" -frames:v 1 "$STILL_DIR/shot-spread.png" || true
ffmpeg -y -v error -ss 2.0 -i "$RAW" -vf "$STILL_VF" -frames:v 1 "$STILL_DIR/shot-single.png" || true

rm -f "$RAW"

# --- 8. 收尾:退出 App、摘掉标记、还原偏好 ---------------------------------
killall Unroll 2>/dev/null || true
sleep 1
rm -f "$TMPDIR_APP/demo-enabled"
if [ -f "$CONTAINER/Library/Application Support/Unroll/session.json" ]; then
    python3 - "$CONTAINER/Library/Application Support/Unroll/session.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d["alive"] = False
p.write_text(json.dumps(d))
PY
fi

say "完成:"
ls -lh "$GIF" 2>/dev/null | awk '{print "  " $9 "  " $5}'
say "备用静态帧: $STILL_DIR"
say "演示驱动日志(排查用): $TMPDIR_APP/demo-driver.log"
