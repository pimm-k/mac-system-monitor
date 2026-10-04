# 構成要素の一覧（脆弱性チェック用）

脆弱性情報（JVN / NVD / Apple セキュリティアップデート / GitHub Advisory）が出たときに、
このアプリが影響を受けるかを判断するための一覧です。構成を変えたらこのファイルも更新してください。

## 1. アプリが使う macOS の機能

| 構成要素 | 使っている場所 | 使い方 | 主な関連キーワード |
|---|---|---|---|
| libproc (`proc_pidinfo` / `proc_pidpath` / `proc_pid_rusage` / `proc_listallpids`) | `ProcessSampler.swift` / `Utilities.swift` | プロセス情報の読み取りのみ | XNU, kernel, libproc |
| Mach (`host_processor_info` / `host_statistics64`) | `SystemSampler.swift` | CPU・メモリ統計の読み取り | XNU, Mach |
| IOKit (`IOBlockStorageDriver` / `IOAccelerator`) | `SystemSampler.swift` | ディスク・GPU 統計の読み取り | IOKit, AGX, GPU driver |
| SystemConfiguration / `getifaddrs` | `SystemSampler.swift` | ネットワーク統計・IP の読み取り | networking |
| SQLite（macOS 同梱の `libsqlite3`） | `HistoryStore.swift` | 履歴の保存。SQL はすべてプレースホルダで値を渡す | SQLite |
| SwiftUI / AppKit / Swift Charts | `Views/` | 画面表示 | SwiftUI, AppKit |
| LaunchAgent (`launchctl`) | `HistoryRecorder.swift` / `LaunchItems.swift` / `LegacyMigration.swift` | バックグラウンド記録の登録、スタートアップ項目の有効化・無効化 | launchd, launchctl |
| `/usr/bin/osascript`（`do shell script … with administrator privileges`） | `Monitor.swift` | 管理者権限が必要な操作（kill / renice / launchctl） | AppleScript, Authorization, privilege escalation |
| `/bin/ps` / `/bin/kill` / `/usr/bin/renice` | `ProcessSampler.swift` / `Utilities.swift` | 他ユーザーのプロセス情報取得、終了・優先度変更 | ps, setuid |
| `NSWorkspace` / `NSRunningApplication` | `Monitor.swift` | アプリの一覧・終了 | AppKit |

## 2. ビルド・配布

| 構成要素 | 用途 |
|---|---|
| Swift / Xcode Command Line Tools | ビルド |
| `codesign`（アドホック署名 + Hardened Runtime） | 署名 |
| `ditto` / `PlistBuddy` | インストール・Info.plist 編集 |
| `hdiutil` | インストーラー (.dmg) の作成 |

## 3. GitHub Actions

| アクション / ランナー | ワークフロー |
|---|---|
| `actions/checkout@v4` | ci / release / codeql / secrets |
| `github/codeql-action/*@v3` | codeql |
| `ghcr.io/gitleaks/gitleaks:latest`（Docker イメージ） | secrets |
| `macos-15` ランナー | ci / release / codeql |
| `ubuntu-latest` ランナー | secrets |
| `gh` CLI（ランナー同梱） | release |

## 4. 外部ライブラリ（Swift Package）

なし（`Package.swift` に dependencies はありません）。追加した場合はここに追記してください。

## 5. 影響を受けやすい攻撃面（優先して確認する所）

1. **管理者権限での実行**（`osascript` → root）：コマンド組み立てのエスケープ、PID 再利用対策
2. **plist の読み込み**（`~/Library/LaunchAgents` は他アプリからも書き換え可能）：ラベル・パスのエスケープ
3. **SQLite**：プレースホルダ使用の徹底、履歴ファイルの権限（0600）
4. **LaunchAgent**：登録する実行ファイルのパス（/Applications 外だと差し替えられるおそれ）
5. **GitHub Actions**：`permissions` の最小化、アクションのバージョン
