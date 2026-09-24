#!/bin/bash
# ============================================================================
# check-file-associations.sh —— 校验 .app 的文件关联声明(导出 UTI + 文档类型)
# ----------------------------------------------------------------------------
# 用法: Scripts/check-file-associations.sh <Unroll.app 路径>
# 退出码: 0 通过 / 1 有缺失(对应格式装完无法双击打开) / 2 前置不满足(不是 .app)
#
# 为什么单独成一个脚本(2026-09-24):
#   这段校验原先内联在 build-app.sh 里,**只能靠跑完整次 archive 才触发** ——
#   所以它从来没被反向测试过。而它恰恰是那类最沉默的故障唯一的拦截点:
#   漏声明一个 UTI,装完看着一切正常,双击 .cbz 没反应,也没有任何报错。
#   抽出来后 Scripts/test-build-guards.sh 用一个 /tmp 里的假 .app + 变异过的
#   Info.plist 就能把每条分支注入一遍,不再需要真实构建。
#
# 校验的是**具体标识符在不在**,不是数量。2026-09-16 复查发现的问题:原先只卡
# 「UTI ≥ 4 且文档类型 ≥ 5」的数量下限,而自 2026-09-14 新增裸 .rar / .7z 关联后
# 实际已是 6 / 7 —— 此时若 cbz 声明被误删而 rar/7z 还在,计数为 5,照样通过。
# 这正是这道防线本该拦住的沉默故障,于是四条漫画格式改成逐个点名。
# 文档类型则保留一条**宽松**数量下限,只负责拦「整张关联表塌掉」。
# ============================================================================
set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
    echo "用法: $(basename "$0") <Unroll.app 路径>" >&2
    exit 2
fi

INFO="$APP/Contents/Info.plist"
if [ ! -f "$INFO" ]; then
    echo "不是 .app(找不到 $INFO)" >&2
    exit 2
fi

PB=/usr/libexec/PlistBuddy

UTI_LIST="$($PB -c 'Print :UTExportedTypeDeclarations' "$INFO" 2>/dev/null || true)"
UTI_COUNT="$(printf '%s\n' "$UTI_LIST" | grep -c 'UTTypeIdentifier' || true)"
DOC_COUNT="$($PB -c 'Print :CFBundleDocumentTypes' "$INFO" 2>/dev/null | grep -c 'CFBundleTypeName' || true)"
# 缩进两格是为了跟 build-app.sh 其余输出对齐 —— 本脚本是它构建日志里的一段。
echo "  文件关联: 导出 UTI ${UTI_COUNT:-0} 个 / 文档类型 ${DOC_COUNT:-0} 个"

MISSING_UTI=""
for U in cbz cbr cb7 cbt; do
    # 用 grep -c(读到 EOF)而不是 grep -q(命中即退):后者配上 pipefail 会在
    # printf 收到 SIGPIPE 时把整条管道判失败,于是**每个** UTI 都报"缺失",
    # 变成一次纯属虚构的构建失败(与 build-app.sh 里 codesign 那处是同一类坑)
    U_HITS="$(printf '%s\n' "$UTI_LIST" | grep -c "UTTypeIdentifier = com.gfredr.unroll.$U\$" || true)"
    if [ "${U_HITS:-0}" -eq 0 ]; then MISSING_UTI="$MISSING_UTI $U"; fi
done
if [ -n "$MISSING_UTI" ]; then
    echo "  ✗ 缺导出 UTI 声明:$MISSING_UTI —— 装完无法双击打开对应格式" >&2
    exit 1
fi

if [ "${DOC_COUNT:-0}" -lt 5 ]; then
    echo "  ✗ 文档类型声明过少($DOC_COUNT 个)—— 至少需 cbz/cbr/cb7/cbt + zip Alternate" >&2
    exit 1
fi

exit 0
