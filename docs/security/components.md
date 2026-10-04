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
| `URLSession`（HTTPS）/ GitHub REST API / CryptoKit (SHA-256) | `Updater.swift` | 最新リリースの確認と zip のダウンロード・ハッシュ検証 | URLSession, TLS, CryptoKit |
| `/usr/bin/ditto` / `/usr/bin/codesign --verify` / `/usr/bin/xattr` / `/bin/bash`（生成スクリプト） | `Updater.swift` | 更新ファイルの展開・署名確認・アプリの置き換えと再起動 | ditto, codesign, Gatekeeper |
| `/usr/sbin/lsof` / Security (`SecStaticCode`) | `NetWatch.swift` | 接続一覧の取得、通信しているプログラムの署名確認 | lsof, Code Signing |
| UserNotifications | `NetWatch.swift` / `SystemMonitorApp.swift` | 怪しい通信の通知 | UserNotifications |

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
6. **アプリ内アップデート**：ダウンロード元ホストの制限（リダイレクト含む）、SHA-256・バンドル ID・バージョン・`codesign --verify` の確認、置き換えスクリプトのパスのエスケープ。※ .sha256 は同じ Release から取得するため「改ざん検出」ではなく「破損検出」。真正性は HTTPS と GitHub アカウントの保護（2 段階認証）に依存
7. **lsof の出力解析**（`NetWatch.swift`）：プロセス名・アドレスの文字列をそのまま信用しない（表示と通知本文のみに使い、コマンドには渡さない）
