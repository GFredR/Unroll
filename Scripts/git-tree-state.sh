#!/bin/bash
# ============================================================================
# git-tree-state.sh —— 给 build-app.sh 的侧车提供「提交号 / 分支 / 工作区是否脏」
# ----------------------------------------------------------------------------
# 用法: Scripts/git-tree-state.sh [仓库路径]
# 输出(stdout,三行,可直接 sed 取值):
#   commit=<40 位提交号,或 unknown>
#   branch=<分支名,或 unknown>
#   dirty=<0|1>
# 退出码: 0 正常 / 2 前置不满足(不是 git 仓库)
#
# 为什么单独成一个脚本(2026-09-24):
#   这三行原先内联在 build-app.sh 里,而要证明「未跟踪文件算不算脏」只能**跑完整次
#   archive**(几十秒到几分钟),成本高到没人会去做 —— 于是这道判据从来没被反向
#   测试过。抽出来后 Scripts/test-build-guards.sh 能在一个临时仓库里造出五种树状态,
#   几毫秒把全部分支验一遍。这是本项目反复踩到的那个坑的正面解法:
#   **一个从不失败的守卫等于没有守卫,而它的失效方式是无声的。**
# ============================================================================
set -uo pipefail

REPO="${1:-.}"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "不是 git 仓库: $REPO" >&2
    exit 2
fi

printf 'commit=%s\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'branch=%s\n' "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# ⚠️ dirty 的判据里**不许加 `--untracked-files=no`**(2026-09-24 修掉的一个真空洞)
#
# 原先这里写的是 `git status --porcelain --untracked-files=no`,并且给了一个看上去
# 很正当的理由:「Unroll.xcodeproj 与两个 appex 的 Info.plist 是 xcodegen 生成物,
# 不该因为构建过程重写了它们就把一次干净构建判成脏」。
#
# **那条理由是错的。** 那些文件都在 .gitignore 里,`git status` 本来就不会输出它们
# —— 2026-09-24 实测:仓库里 Unroll.xcodeproj 与 Unroll/Info.plist 都在磁盘上,
# 而 `git status --porcelain` 的输出里匹配 `xcodeproj|Unroll/Info.plist` 的行数是
# **0**。所以那个开关并没有在防它声称要防的东西。
#
# 它唯一真实的后果是**把真正未跟踪的文件也一起藏起来**,而这不是小事:
#   · project.yml 的 sources 是**目录级**的(`- path: Unroll`,不是逐文件列举);
#   · build-app.sh 在编译前会先跑 `Scripts/regen.sh` 重新生成工程。
# 于是「新建一个还没 git add 的 .swift → 直接构建」会把这份代码**编进二进制**,
# 而侧车会诚实地写下 dirty=0 —— 三方判据里最要紧的那条(②)于是形同虚设,
# 产物可以包含任何未提交的代码却声称自己来自一个干净的提交。
#
# 结论:**未跟踪 = 脏**。发布本来就要求「先提交再构建」,这条只会让漏提交更早暴露,
# 不会误伤正常流程(反方向的误伤由 test-build-guards.sh 里那条「只改了被 .gitignore
# 忽略的文件 → dirty=0」的用例守住)。
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    echo "dirty=1"
else
    echo "dirty=0"
fi

exit 0
