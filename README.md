**English** | [简体中文](README.zh-CN.md)

# Unroll / 开卷

A lightweight, native **macOS comic archive reader**. Double-click a `.cbz / .cbr / .cb7 / .cbt` file and start reading — no extraction, no library, no traces left behind. **Fully open source and free.**

Reading a comic shouldn't require unpacking it first. Most archive tools make you extract to a temp folder, then open an image viewer, and then clean up afterwards — for a 500 MB archive that's half a gigabyte of disk churn just to read page 1. Unroll streams pages straight out of the archive instead.

## Features

- **Reads straight from the archive** — nothing is ever extracted to disk, no thumbnail database is built, no "library" is imported. Open a file, read it, quit.
- **Zero third-party dependencies** — it uses the `libarchive` (BSD-2) that already ships with macOS. The entire app is under 1 MB.
- **A single sequential scanner** — pages are pulled through one streaming pass, so page 200 costs about the same as page 1. The naive alternative (reopening the archive per page) degrades quadratically on solid 7z archives: measured **71× slower** at 150 pages, and getting worse as the archive grows.
- **Page cache with a pixel budget** — at most 8 full-resolution pages and 200 M pixels are kept in memory. Evicted pages are demoted to a 1600 px thumbnail rather than dropped outright, so scrubbing back is instant instead of a re-decode.
- **Single page & two-page spreads, including right-to-left (manga)** — spreads advance two pages at a time; flipping the reading direction only mirrors the spread and never moves your position.
- **Keyboard-first** — every action is reachable without touching the mouse.
- **HUD overlay** — filename, page number and a progress bar; fades out 2.5 s after you stop moving.
- **Recent documents** — the last 10 archives, remembered with security-scoped bookmarks so the sandbox can reopen them. The menu lists file names only.
- **Encrypted archives are handled honestly** — detected up front, reported clearly, never a crash. See below.
- **Native SwiftUI, macOS 14+, sandboxed, and with no network permission at all.**

## Supported formats

| Extension | Container | Status |
| --- | --- | --- |
| `.cbz` / `.zip` | ZIP | ✅ verified with fixtures |
| `.cb7` / `.7z` | 7z, including solid archives | ✅ verified with fixtures |
| `.cbt` / `.tar` | TAR | ✅ verified with fixtures |
| `.cbr` | RAR 5 | ✅ **verified against real-world samples** |
| `.cbr` | RAR 4 (older archives) | ⚠️ untested — no sample on hand; `libarchive` supports RAR 4, so it should work, but it has not been confirmed |
| any | encrypted | 🚫 detected and explained; **not** decrypted in v1 |

When an archive holds no images, or the file is damaged or isn't an archive at all, you get a specific message rather than an empty window.

## Encrypted archives

There are three distinct cases, and they are reported differently because the underlying truth is different:

- **Header-encrypted** — even the file listing is encrypted. The archive can't be opened at all, so you're told that directly.
- **Fully encrypted** — the contents are encrypted. Unroll says so and points out that v1 has no password prompt.
- **Partially encrypted** — some pages are locked. Those pages get an "encrypted" placeholder card while the remaining ones stay readable, so an archive with two locked pages is still worth opening.

One case deserves an explicit warning: for **encrypted 7z**, the system `libarchive` cannot decrypt content *at all* — not even with the correct password. That is a limitation of the library macOS ships, not a policy choice by this app, and the message says so rather than asking you for a password that could never work. Encrypted ZIP and RAR go through the same honest path: detected, explained, not decrypted.

**v1 has no password entry box.** If you need to read an encrypted archive, decrypt it with another tool first.

## Install

**Requires macOS 14 Sonoma or later.**

Download `Unroll-<version>.dmg` from [Releases](https://github.com/GFredR/Unroll/releases), open it, and drag `Unroll.app` into **Applications**.

The build is ad-hoc signed (no paid Apple Developer account), so macOS Gatekeeper may block the first launch. Either of these works:

```bash
xattr -dr com.apple.quarantine /Applications/Unroll.app
```

or **right-click** `Unroll.app` → **Open** → confirm.

Once installed, `.cbz / .cbr / .cb7 / .cbt` files open in Unroll on double-click. Plain `.zip` is only offered inside the Open panel — Unroll never takes over the system's default handler for ZIP.

## Build & run

Requirements: the latest Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# 1. Generate the Xcode project (project.yml is the single source of truth;
#    re-run it after changing that file — the generated project is not committed)
./Scripts/regen.sh

# 2. Open and run (scheme: Unroll)
open Unroll.xcodeproj

# 3. Logic-only tests: no app launch, milliseconds
cd ArchiveKit && swift test
```

To produce a distributable build (Universal 2: arm64 + x86_64) and a DMG:

```bash
./Scripts/build-app.sh     # → ../Unroll-dist/Unroll.app
./Scripts/make-dmg.sh      # → ../Unroll-dist/Unroll-1.0.0.dmg
```

Both scripts write outside the repository on purpose — keeping `.app`, `.dmg` and DerivedData out of the source tree keeps Xcode and Spotlight from crawling them on every open.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Open… |
| `⌘1` / `⌘2` | Single page / two-page spread |
| `⇧⌘L` / `⇧⌘R` | Left-to-right / right-to-left (manga) |
| `⇧⌘↑` | Back to cover |
| `←` / `→` | Previous / next page — follows the reading direction |
| `Space` `↓` `Page Down` `End` | Next page |
| `Page Up` `Home` | Previous page |
| Click left / right half of the window | Previous / next page (mirrored in right-to-left mode) |
| Double-click | Toggle 1× ⇄ 2× zoom |
| Pinch | Zoom continuously between 1× and 8× |
| Scroll wheel / trackpad | Page through the archive while unzoomed; zooms out of the way once magnified |

## Privacy

This app has **no network entitlement**, so the sandbox makes network access impossible rather than merely unused. There is no telemetry, no analytics, no account, and no "anonymous usage data".

Crash reporting is **opt-in and manual**. If the app was killed or quit abnormally, the next launch asks once whether you want to file a bug report — and the app still makes no network request: it hands a pre-filled GitHub issue draft to your browser, where you can read and edit everything before deciding to submit. The draft contains the version, OS, architecture, archive format, page counts and a short breadcrumb trail of what the reader was doing. It contains **no file names and no paths** — breadcrumb values are restricted by construction to a small character set, so a path cannot leak into them even by accident.

## Known limitations

- **No password entry** for encrypted archives (v1).
- **RAR 4 is unverified** — RAR 5 has been tested against real samples; RAR 4 has not.
- **Very large solid 7z archives** cost roughly 90 ms of LZMA2 decompression per page. Prefetching is designed to hide that, but jumping far ahead in a huge solid archive has a real, visible cost.
- **Not notarized** — ad-hoc signing only, hence the first-launch Gatekeeper step above.
- **macOS only in v1.** The archive engine is kept as a standalone SwiftPM package (`ArchiveKit`) specifically so an iOS / iPadOS build can reuse it later.

## Project layout

```
Unroll/
├── Unroll/
│   ├── App/        # Entry point, menus, app lifecycle
│   ├── Features/   # Reader: view, view model, HUD
│   ├── Core/       # Page store & cache, design system, recents, diagnostics
│   └── Resources/  # en / zh-Hans strings, asset catalog
├── ArchiveKit/     # Local SwiftPM package — archive reading, zero UI (reusable)
├── UnrollTests/            # App-hosted unit tests
├── UnrollLogicTests/       # Fast logic-only tests
├── Scripts/        # regen / build-app / make-dmg
└── project.yml     # xcodegen source of truth
```

## Support this project

Unroll is **fully open source and free.** If it saved you some time or a subscription, buy me a coffee:

1. Scan the QR code below with WeChat.
2. Any amount is welcome — it's the thought that counts.

![WeChat Pay QR code](assets/donate-wechat.png)

## License

MIT — see [LICENSE](LICENSE). Use, modify, and redistribute freely, for personal or commercial projects.
