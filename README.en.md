<p align="center">
  <img src="docs/icon.png" width="160" alt="Icon">
</p>

<h1 align="center">System Monitor for Mac</h1>

<p align="center"><b>システムモニター</b> — mac-system-monitor</p>

<p align="center"><a href="README.md">日本語</a> | English</p>

<p align="center">
  A system monitor for macOS that shows processes, performance, and history — inspired by the Windows Task Manager and built with SwiftUI.
</p>

<p align="center">
  <a href="https://github.com/pimm-k/mac-system-monitor/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/pimm-k/mac-system-monitor"></a>
  <a href="https://github.com/pimm-k/mac-system-monitor/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/pimm-k/mac-system-monitor/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-orange">
  <img alt="License" src="https://img.shields.io/badge/license-Use%20Only%20%2F%20No%20Derivatives-lightgrey">
</p>

---

## Features

| Tab | Description |
|---|---|
| **Processes** | Split into "Apps" and "Background processes". Helper/child processes are grouped under their app with totals (expand with ▶). CPU, memory, and disk are shown with heat-map colors |
| **Performance** | Real-time graphs for CPU (overall / per logical processor), memory (composition bar), disk (active time / transfer rate), network (per adapter, with IP / MAC), and GPU |
| **History** | Look back at past activity: graphs of CPU, memory, disk, network, and GPU (1 hour – 30 days), per-app history (CPU time, disk usage, etc.), top processes at moments of high load, **network alerts**, and process start/exit logs |
| **Startup Apps** | List and enable/disable LaunchAgents / LaunchDaemons |
| **Users** | CPU, memory, and disk usage per user, and that user's processes |
| **Details** | PID, status, user, CPU time, threads, priority, and path of every process. Change priority, end process tree |

- End task / force quit (Delete key supported)
- Run new task (⌘N)
- Switch tabs (⌘1–⌘6), search, change update speed, always on top
- Actions on other users' (e.g. root) processes run with your administrator password after confirmation
- **Suspicious network alerts**: Notification Center alerts for connections to suspicious ports (remote control, Tor, mining, etc.), connections from programs in /tmp or Downloads, connections from unsigned or broken-signature programs, and sustained heavy uploads (see History → Network Alerts for the list and exclusions)
- **English / Japanese**: choose the display language on first launch (default: Use System Setting; not shown when updating). You can change it later in "Options → 言語 / Language" (Japanese / English / Use System Setting; takes effect after restart)
- **In-app updates**: checks for new versions at launch (once a day) or via "System Monitor → Check for Updates…", and updates with one click (hash, signature, etc. are verified before replacing the app)

## Requirements

- macOS 14 (Sonoma) or later
- To build from source: Xcode or the Command Line Tools (`xcode-select --install`)

## Download & Install

1. Download **`SystemMonitor-vX.Y.Z.dmg`** from [Releases](https://github.com/pimm-k/mac-system-monitor/releases/latest)
2. Open the .dmg and **drag System Monitor to "Applications"**
3. The first time only: if macOS blocks the app, go to System Settings → Privacy & Security and click **Open Anyway**

> The app is not notarized by Apple, so step 3 is needed once. You can verify the download with the `.sha256` file: `shasum -a 256 -c SystemMonitor-vX.Y.Z.dmg.sha256`

## Migrating from "Task Manager" (v1.x)

In v2.0.0 the app was renamed to System Monitor (`SystemMonitor.app`). The first time you launch the new app, the following are migrated automatically:

- Settings (last opened tab, zoom, CPU view, etc.)
- History data (`~/Library/Application Support/TaskManager` → `SystemMonitor`)
- Background recording (re-registered under the new name if you used it)

After that you can delete the old `TaskManager.app` (`./build_app.sh --install` removes it automatically).

## Build & Run

```bash
git clone https://github.com/pimm-k/mac-system-monitor.git
cd mac-system-monitor

# Run right away
swift run

# Build the .app and install it to /Applications
./build_app.sh --install
```

> ⚠️ Overwriting an existing `/Applications/SystemMonitor.app` with `cp -R` breaks the code signature and the app will crash at launch. Use `--install`, or delete the old app before copying.

> Apps you build on your own Mac launch without any warning.

## Project Structure

```
Sources/SystemMonitor/
├── SystemMonitorApp.swift    … Entry point
├── Data/
│   ├── Monitor.swift         … Periodic updates, history, end task, etc.
│   ├── ProcessSampler.swift  … Process info via libproc
│   ├── SystemSampler.swift   … CPU / memory / disk (IOKit) / network / GPU
│   ├── HistoryStore.swift    … History database (SQLite)
│   ├── HistoryRecorder.swift … History recording & background recording (LaunchAgent)
│   ├── NetWatch.swift        … Suspicious network detection & notifications
│   ├── Updater.swift         … In-app updates (GitHub Releases)
│   ├── LegacyMigration.swift … Migration from the old TaskManager name (v1.x)
│   └── LaunchItems.swift     … Reading and toggling LaunchAgents / Daemons
├── Views/                    … Screens for each tab
├── Util/Utilities.swift      … Formatting, sysctl, shell execution
└── Util/Localization.swift   … Translation (L("日本語")) and language switching
scripts/release.sh            … Release (version bump, CHANGELOG, tag)
scripts/make_dmg.sh           … Build the installer (.dmg)
scripts/check-l10n.py         … Check for missing English translations
.github/workflows/            … CI (build) and Release (publish)
VERSION                       … Version number (single source of truth)
Resources/
├── Info.plist
├── en.lproj/Localizable.strings … English strings (key = original Japanese)
├── AppIcon.icns
└── icon/                     … Icon source and generator script
```

## About History Recording

- Clicking "Record in Background" on the History tab registers a LaunchAgent (`local.pim.systemmonitor.recorder`) that records every 5 seconds while you are logged in. macOS will show a "Background Items Added" notification.
- When disabled, history is recorded only while the app is open.
- Location: `~/Library/Application Support/SystemMonitor/history.sqlite` (readable and writable only by you). **Nothing is sent anywhere.**
- Retention: 5-second data for 24 hours; 1-minute summaries, per-app usage, and logs for 30 days. Old data is deleted automatically; the database stays around tens of MB.
- To stop or delete: use "Stop Background Recording" and "…" → "Delete History…" (you can choose which types to delete) on the History tab.

## Limitations

- Details of other users' (root) processes cannot be read due to macOS permissions, so their CPU time and memory come from `ps` (thread count shows "—").
- Per-process network and GPU usage are not shown because there is no public API.
- Start/exit logs compare snapshots every 5 seconds, so processes that exit within 5 seconds may be missed.
- "Login Items" registered with SMAppService cannot be listed via API, so a button opens System Settings instead.
- The app uses features that are incompatible with App Sandbox, so it is not distributed on the Mac App Store.

## Versioning

- Version numbers follow [Semantic Versioning](https://semver.org/) and are managed in the `VERSION` file (also shown at the bottom of the sidebar).
- See [CHANGELOG.md](CHANGELOG.md) for changes and [CONTRIBUTING.md](CONTRIBUTING.md) for development and release steps (both in Japanese).

## Security

No external libraries are used. The only network traffic is checking for and downloading updates from GitHub over HTTPS; recorded history and other data are never sent anywhere. In addition to GitHub CodeQL and secret scanning, gitleaks checks for secrets before each commit and in GitHub Actions. Actions that require administrator privileges show the exact command and are confirmed with the standard macOS authentication dialog. See [SECURITY.md](SECURITY.md) for details and for how to report a vulnerability.

## License

You may use the app and redistribute it unmodified freely, but **modifying it or distributing modified versions is prohibited**. See [LICENSE](LICENSE) for details.

## Disclaimer & Trademarks

- This is an independent personal project and is not affiliated with, endorsed by, or sponsored by Microsoft Corporation.
- The app was **developed independently with reference to** the features and usability of the Windows Task Manager. No Microsoft source code, icons, images, or other assets are used.
- The app was named "Task Manager" (TaskManager) up to v1.x and was renamed to "System Monitor" in v2.0.0.
- Microsoft and Windows are registered trademarks or trademarks of Microsoft Corporation in the United States and other countries.
- macOS and Mac are trademarks of Apple Inc., registered in the U.S. and other countries.
- Other company and product names are trademarks or registered trademarks of their respective owners.
