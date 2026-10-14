# Contributing / 参与贡献

**中文**

先说清楚现状，免得你有预期落差：**这个项目目前 0 issue、0 PR、1 star。** 收到的主要是 bug 报告，代码贡献很少。所以下面「怎么让你修得快」写得比「怎么提 PR」详细得多。

## 最重要的一件事：先把现状说清楚

提 issue 前，先试一遍：

1. **是不是已知限制？** README 的 [Known limitations](README.md#known-limitations) 列了几条硬限制——加密 7z 读不了、RAR4 未验证、超大 solid 7z 每页约 90 ms。这些**不是 bug**，是系统 `libarchive` 的能力边界，改不动。
2. **是不是版本问题？** 确认用的是最新版 Release（首页徽章链过去）。
3. **是不是 Gatekeeper 拦住了？** 首次打开要在「系统设置 → 隐私与安全性」点「仍要打开」，否则会表现成各种诡异症状。

这三条能挡掉相当一部分报告。

## 提一份有用的 issue

请包含：

| 项 | 为什么需要 |
|---|---|
| 版本 + macOS 版本 | 很多问题跟系统版本强相关 |
| 归档格式（cbz / cbr / cb7 / cbt / 散图目录） | 决定走哪条代码路径 |
| 页数 + 文件体积 | 决定是否落在性能边界上 |
| 你做了什么 / 你以为会发生什么 / 实际发生了什么 | 三段式，比「坏了」有用一百倍 |
| 截图 | 界面问题必附 |

**不要直接附上损坏或加密的样本文件。** 按 [SECURITY.md](SECURITY.md) 的说明描述特征即可。

## 崩溃报告

App 异常退出后，下次启动会问你要不要提交报告——**点确认后也不会联网**，它只是在浏览器里打开一个预填好的 GitHub issue 页面，你确认完再提交。里面只有版本、系统、架构、格式和页数，**没有文件名、没有路径**。

## 想提 PR

**先开 issue 讨论。** 这个项目没有多人协作，PR 直接扔过来大概率不合上下文，讨论一轮成本更低。

如果你确定要提：

1. 从一个干净分支开始，一次改动只做一件事；
2. 提交信息写「改了什么」和「为什么」，别写「fix bug」；
3. **本地跑通测试再推**：

```bash
cd ArchiveKit && swift test      # 纯逻辑，快
```

4. 涉及界面的改动请附截图（改动前后各一）。

### 什么改动我大概率会拒绝

- **引入第三方依赖。** 这是刻意的：零依赖是 App 只有 2.6 MB、能用系统 libarchive 的前提。
- **加书架 / 元数据 / 标签。** 同样刻意——定位是「打开就能读」，不是库管理器。
- **加动图页支持。** 会突破零依赖，也突破沙盒能处理的格式边界。
- **顺手重排代码。** 与改动无关的格式化会把 diff 淹掉。

如果你认为某个决定该推翻，**先开 issue 说服我**，比直接改高效。

## 代码风格

跟仓库现有代码保持一致：

- 注释解释**为什么**，不解释是什么；
- 用户可见文案走 `Localizable.strings`，不硬编码；
- 不做「顺手重构」，重构单独一个 commit；
- `struct archive` 非线程安全，任何持有它的类型都**不能标 Sendable**（详见 [ARCHITECTURE.md](ARCHITECTURE.md)）。

---

**English**

State of the project, up front: **0 issues, 0 PRs, 1 star** so far. Most reports are bugs, so "how to make your report easy to act on" gets more space than "how to submit a PR".

## Before you file

1. **Is it a known limitation?** The README lists hard limits — encrypted 7z can't be read, RAR4 is unverified, very large solid 7z costs ~90 ms per page. Those are **not bugs**; they're boundaries of the system `libarchive`.
2. **Are you on the latest release?** The badge at the top links to it.
3. **Did Gatekeeper block the app?** First launch requires "Open Anyway" in System Settings → Privacy & Security, otherwise symptoms are bizarre.

That catches a large share of reports.

## What makes a report actionable

Include: version + macOS version · archive format (cbz / cbr / cb7 / cbt / image folder) · page count and file size · what you did, what you expected, what actually happened · screenshots for UI issues.

**Don't attach damaged or encrypted sample files.** Describe their characteristics — see [SECURITY.md](SECURITY.md).

## Crash reports

After an abnormal exit the app offers to file a report — accepting still makes **no network request**; it opens a prefilled GitHub issue page in your browser where you read and edit before submitting. It contains version, OS, architecture, format and page counts — **no file names, no paths**.

## Pull requests

**Open an issue first.** With no collaborators, a PR that arrives without context usually won't land.

If you proceed: one branch, one concern per change · explain *what* and *why* in the commit message · **run the tests before pushing**:

```bash
cd ArchiveKit && swift test      # logic only, milliseconds
```

Include before/after screenshots for UI changes.

### Changes I'll likely decline

- **Third-party dependencies.** Deliberate: zero deps is why the app is 2.6 MB and uses the system libarchive.
- **A shelf, metadata, or tags.** Also deliberate — the goal is "open it and read", not a library manager.
- **Animated page support.** Would break both zero-dependency and the format boundary the sandbox allows.
- **Drive-by refactors.** Unrelated reformatting buries the diff.

If you think one of those decisions is wrong, **argue it in an issue first** — far more effective than just changing it.

## Code style

Match what's already here:

- Comments explain *why*, not *what*;
- User-facing strings go through `Localizable.strings`, never hardcoded;
- No drive-by refactors — keep them in a separate commit;
- `struct archive` is not thread-safe, so any type holding it **must not** be marked `Sendable` (see [ARCHITECTURE.md](ARCHITECTURE.md)).