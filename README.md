# Free Mac Monitor

A minimal macOS menu-bar system monitor with a retro CRT / Pip-Boy aesthetic. Pure Swift + AppKit + WebKit, zero third-party dependencies.

## Features

- **Menu-bar indicator** — a small `>>` icon that turns red when any metric breaches its alert threshold.
- **Live-metrics mode** — right-click the icon and toggle **Show Live Metrics**. The icon becomes a rolling readout that cycles every 3 seconds through:
  ```
  CPU 20%  →  MEM 64%  →  GPU  5%  →  DSK 59%
  ```
  When a threshold is breached the rotation locks onto the offending metric and turns red, so you see the problem within one cycle.
- **Expanding panel** — left-click to open a 320 × 400 Pip-Boy-styled dashboard with live bar charts. Click anywhere outside to collapse.
- **Always-on polling** at 1 Hz — the menu-bar state stays current whether the panel is open or not.
- **Persistent preference** — the live-metrics toggle is stored in `UserDefaults`.

## Requirements

- macOS 13 Ventura or later
- Swift 5.9+ (ships with Xcode 15 / Command Line Tools)

## Build & run

```bash
./build.sh
open "Free Mac Monitor.app"
```

If Gatekeeper blocks the unsigned build:

```bash
xattr -cr "Free Mac Monitor.app" && open "Free Mac Monitor.app"
```

## Right-click menu

| Item | Action |
|---|---|
| Show Live Metrics | Toggles the rotating readout in the menu bar. |
| Quit Free Mac Monitor | Exits the app. |

Left-click opens / closes the dashboard panel.

## Alert thresholds

Compiled-in constants in [`StatusBarController.swift`](Sources/FreeMacMonitor/StatusBarController.swift):

| Metric | Default |
|---|---|
| CPU  | 80% |
| Memory | 80% |
| GPU  | 80% |
| Disk | 85% |

## Regenerating the app icon

The icon is produced by a tiny Core Graphics script:

```bash
swift scripts/make_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset
rm -rf AppIcon.iconset
```

Output: `AppIcon.icns` at the project root, which `build.sh` copies into the bundle.

## Project layout

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

## How it works

- The app runs with `LSUIElement = true` — no Dock icon, no app-switcher entry.
- A single 1 Hz timer drives both the menu-bar render and the (optional) WebKit panel update.
- The dashboard is local HTML (loaded via `WKWebView.loadFileURL`) and receives metric updates through `evaluateJavaScript` calls — simple, no IPC, no server.
- Clicking outside the open panel is caught with `NSEvent.addGlobalMonitorForEvents`, which fires only for events in other apps' windows, avoiding re-toggle races with the status-bar button click.
