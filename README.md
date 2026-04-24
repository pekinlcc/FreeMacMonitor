# Free Mac Monitor

[English](#english) · [中文](#中文) · [🌐 Website](https://pekinlcc.github.io/freemacmonitor/)

---

## English

A minimal macOS menu-bar system monitor with a retro CRT / Pip-Boy aesthetic. Pure Swift + AppKit + WebKit, zero third-party dependencies.

### Download & install

**Prebuilt universal binary** (Apple Silicon + Intel, ad-hoc signed — not notarised):

| Method | Command |
|---|---|
| One-line install | `curl -fsSL https://raw.githubusercontent.com/pekinlcc/freemacmonitor/main/scripts/install.sh \| bash` |
| Manual | [Download the latest release](https://github.com/pekinlcc/freemacmonitor/releases/latest), unzip, then drag `Free Mac Monitor.app` into `/Applications`. |

Because the app is not signed with an Apple Developer certificate, Gatekeeper will refuse to open it on first launch. Choose one:

- **Recommended** — run `xattr -cr "/Applications/Free Mac Monitor.app"` in Terminal to strip the quarantine flag, then open normally. The installer script already does this for you.
- In Finder, right-click the app and choose **Open** → **Open** in the dialog.
- Or go to **System Settings → Privacy & Security**, scroll to the blocked-app notice and click **Open Anyway**.

If you prefer building from source, see [Build & run](#build--run) below.

### Features

- **Menu-bar indicator** — a small `>>` icon that turns red when any metric breaches its alert threshold.
- **Live-metrics mode** — right-click the icon and toggle **Show Live Metrics**. The icon becomes a rolling readout that cycles every 3 seconds through:
  ```
  CPU 20%  →  MEM 64%  →  GPU  5%  →  DSK 59%
  ```
  When a threshold is breached the rotation locks onto the offending metric and turns red, so you see the problem within one cycle.
- **Expanding panel** — left-click to open a 320 × 400 Pip-Boy-styled dashboard with live bar charts. Click anywhere outside to collapse.
- **Always-on polling** at 1 Hz — the menu-bar state stays current whether the panel is open or not.
- **Persistent preference** — the live-metrics toggle is stored in `UserDefaults`.

### Requirements

- macOS 13 Ventura or later
- Swift 5.9+ (ships with Xcode 15 / Command Line Tools)

### Build & run

```bash
./build.sh
open "Free Mac Monitor.app"
```

If Gatekeeper blocks the unsigned build:

```bash
xattr -cr "Free Mac Monitor.app" && open "Free Mac Monitor.app"
```

### Right-click menu

| Item | Action |
|---|---|
| Show Live Metrics | Toggles the rotating readout in the menu bar. |
| Quit Free Mac Monitor | Exits the app. |

Left-click opens / closes the dashboard panel.

### Alert thresholds

Compiled-in constants in [`StatusBarController.swift`](Sources/FreeMacMonitor/StatusBarController.swift):

| Metric | Default |
|---|---|
| CPU  | 80% |
| Memory | 80% |
| GPU  | 80% |
| Disk | 85% |

### Regenerating the app icon

The icon is produced by a tiny Core Graphics script:

```bash
swift scripts/make_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset
rm -rf AppIcon.iconset
```

Output: `AppIcon.icns` at the project root, which `build.sh` copies into the bundle.

### Project layout

```
Sources/FreeMacMonitor/
  main.swift                — NSApplication bootstrap (accessory activation policy)
  AppDelegate.swift         — wires up the status bar controller
  StatusBarController.swift — status item, panel, polling, rotation + alert logic
  SystemMetrics.swift       — CPU / memory / GPU / disk sampling via Darwin + IOKit
  Resources/
    index.html / app.js / style.css — Pip-Boy dashboard UI
scripts/
  make_icon.swift           — Core Graphics icon generator
build.sh                    — SPM release build + .app assembly
Info.plist                  — LSUIElement, CFBundleIconFile, identifiers
```

### How it works

- The app runs with `LSUIElement = true` — no Dock icon, no app-switcher entry.
- A single 1 Hz timer drives both the menu-bar render and the (optional) WebKit panel update.
- The dashboard is local HTML (loaded via `WKWebView.loadFileURL`) and receives metric updates through `evaluateJavaScript` calls — simple, no IPC, no server.
- Clicking outside the open panel is caught with `NSEvent.addGlobalMonitorForEvents`, which fires only for events in other apps' windows, avoiding re-toggle races with the status-bar button click.

---

## 中文

极简的 macOS 菜单栏系统监视器，采用复古 CRT / Pip-Boy 风格。纯 Swift + AppKit + WebKit 实现，零第三方依赖。

### 下载与安装

**预编译通用二进制**（Apple Silicon + Intel，使用 ad-hoc 签名 —— 未经 Apple 公证）：

| 方式 | 命令 |
|---|---|
| 一行命令安装 | `curl -fsSL https://raw.githubusercontent.com/pekinlcc/freemacmonitor/main/scripts/install.sh \| bash` |
| 手动下载 | 前往 [Releases 页面](https://github.com/pekinlcc/freemacmonitor/releases/latest) 下载压缩包，解压后把 `Free Mac Monitor.app` 拖到 `/Applications`。 |

由于应用没有使用 Apple Developer 证书签名，首次启动时 Gatekeeper 会拒绝打开。任选其一：

- **推荐** —— 在 Terminal 中执行 `xattr -cr "/Applications/Free Mac Monitor.app"` 去除隔离标记，然后正常打开。一键安装脚本已经帮你做了这一步。
- 在 Finder 中右键应用，选择 **打开** → 在弹窗中再次点击 **打开**。
- 或前往 **系统设置 → 隐私与安全性**，滚动到被拦截的应用提示处，点击 **仍要打开**。

如果你更倾向于从源码编译，请看下方 [编译与运行](#编译与运行)。

### 功能特性

- **菜单栏指示器** —— 一个小小的 `>>` 图标，当任何指标突破预警阈值时会变红。
- **实时指标模式** —— 右键点击图标，切换 **Show Live Metrics**。图标会变成滚动读数，每 3 秒循环显示：
  ```
  CPU 20%  →  MEM 64%  →  GPU  5%  →  DSK 59%
  ```
  当某项指标触发阈值时，滚动会锁定在该指标并显示为红色，一个循环内就能看到问题。
- **展开面板** —— 左键点击可打开 320 × 400 的 Pip-Boy 风格仪表盘，内含实时柱状图。点击外部任意位置即可收起。
- **持续轮询** —— 1 Hz 的采样频率，无论面板是否展开，菜单栏状态始终保持最新。
- **偏好持久化** —— 实时指标开关状态存储在 `UserDefaults` 中。

### 系统要求

- macOS 13 Ventura 或更高版本
- Swift 5.9+（随 Xcode 15 / Command Line Tools 一并提供）

### 编译与运行

```bash
./build.sh
open "Free Mac Monitor.app"
```

如果 Gatekeeper 阻止了未签名的应用：

```bash
xattr -cr "Free Mac Monitor.app" && open "Free Mac Monitor.app"
```

### 右键菜单

| 菜单项 | 功能 |
|---|---|
| Show Live Metrics | 切换菜单栏中的滚动读数显示。 |
| Quit Free Mac Monitor | 退出应用。 |

左键点击可展开 / 收起仪表盘面板。

### 预警阈值

阈值定义在 [`StatusBarController.swift`](Sources/FreeMacMonitor/StatusBarController.swift) 中作为编译期常量：

| 指标 | 默认值 |
|---|---|
| CPU  | 80% |
| 内存 | 80% |
| GPU  | 80% |
| 磁盘 | 85% |

### 重新生成应用图标

图标由一个小型 Core Graphics 脚本生成：

```bash
swift scripts/make_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset
rm -rf AppIcon.iconset
```

输出：位于项目根目录的 `AppIcon.icns`，`build.sh` 会把它复制到应用包中。

### 项目结构

```
Sources/FreeMacMonitor/
  main.swift                — NSApplication 引导（accessory 激活策略）
  AppDelegate.swift         — 装配状态栏控制器
  StatusBarController.swift — 状态项、面板、轮询、滚动与阈值逻辑
  SystemMetrics.swift       — 通过 Darwin + IOKit 采样 CPU / 内存 / GPU / 磁盘
  Resources/
    index.html / app.js / style.css — Pip-Boy 仪表盘 UI
scripts/
  make_icon.swift           — Core Graphics 图标生成脚本
build.sh                    — SPM release 编译 + .app 组装
Info.plist                  — LSUIElement、CFBundleIconFile、标识符
```

### 实现原理

- 应用以 `LSUIElement = true` 运行 —— 无 Dock 图标，也不出现在应用切换器中。
- 单个 1 Hz 定时器同时驱动菜单栏渲染和（可选的）WebKit 面板更新。
- 仪表盘是本地 HTML（通过 `WKWebView.loadFileURL` 加载），指标更新通过 `evaluateJavaScript` 调用发送 —— 简单直接，不需要 IPC，也不需要服务器。
- 通过 `NSEvent.addGlobalMonitorForEvents` 捕获面板外的点击事件，它只会在其他应用的窗口中触发，避免了与状态栏按钮点击之间的重复切换竞态。
