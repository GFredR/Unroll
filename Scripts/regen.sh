#!/bin/bash
# ============================================================================
# regen.sh —— 从 project.yml 重新生成 Unroll.xcodeproj 与 Unroll/Info.plist
# ----------------------------------------------------------------------------
# 何时跑:改了 project.yml(加文件/改配置/改 scheme)之后。
# 产物:Unroll.xcodeproj、Unroll/Info.plist —— 均为生成物,已被 .gitignore 排除。
# 注意:生成后若 Xcode 已打开工程,会提示重新加载;包解析弹窗选「Cancel」
#       即可保持本地路径引用(DLNACast/ClipSync 同款注意事项)。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "❌ 未安装 xcodegen,先执行: brew install xcodegen"
    exit 1
fi

xcodegen generate
echo "✅ 已重新生成 Unroll.xcodeproj(如 Xcode 正开着,请点 Reload)"
