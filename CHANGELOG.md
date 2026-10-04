# 変更履歴 / Changelog

このプロジェクトの主な変更点を記録します。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョン番号は [セマンティック バージョニング](https://semver.org/lang/ja/) に従います。

- **MAJOR**（1.x.x → 2.0.0）：使い方が大きく変わる・互換性がなくなる変更
- **MINOR**（1.0.x → 1.1.0）：機能の追加
- **PATCH**（1.0.0 → 1.0.1）：バグ修正・小さな改善

## [Unreleased]

### 追加
- アプリ内アップデート：起動時（1 日 1 回）または「アップデートを確認…」で GitHub Releases の新しいバージョンを確認し、ワンクリックで更新・再起動
  - ダウンロード元を github.com に限定し、SHA-256・バンドル ID・バージョン・コード署名を確認してから置き換え（失敗時は元に戻す）

## [2.0.0] - 2026-10-04

### 変更（互換性に影響あり）
- **名前を「タスク マネージャー」から「システムモニター」（System Monitor）に変更**
  - アプリ: `TaskManager.app` → `SystemMonitor.app`（日本語環境では「システムモニター」、英語環境では「System Monitor」と表示）
  - バンドル ID: `local.pim.taskmanager` → `local.pim.systemmonitor`
  - バックグラウンド記録: `local.pim.taskmanager.recorder` → `local.pim.systemmonitor.recorder`
  - 履歴の保存先: `~/Library/Application Support/TaskManager` → `SystemMonitor`
  - 配布ファイル: `TaskManager-vX.Y.Z.dmg` → `SystemMonitor-vX.Y.Z.dmg`
  - リポジトリ: `mac-task-manager` → `mac-system-monitor`（旧 URL は GitHub が自動で転送）

### 追加
- 旧名からの自動引き継ぎ：初回起動時に、設定・履歴データ・バックグラウンド記録を新しい名前へ移行
- `./build_app.sh --install` で、旧名の `TaskManager.app` が残っていれば終了して削除

## [1.4.2] - 2026-10-04

### 改善（軽量化）
- 他ユーザー (root など) のプロセス情報を取る `ps` の実行を、毎秒から 3 秒ごとに（バックグラウンド記録では 30 秒ごと）
- プロセスの実行ファイルのパスをキャッシュし、毎秒の問い合わせを削減
- ウィンドウが見えていないとき（隠す・最小化・他のウィンドウの裏）は、プロセス一覧を取らず、更新間隔も 2 秒以上に
- パフォーマンス・履歴・スタートアップ タブを表示中は、プロセス一覧の取得を 5 秒に 1 回に
- アプリの実行ファイルからデバッグ用のシンボル情報を取り除き、サイズを縮小

## [1.4.1] - 2026-10-04

### 変更
- CPU の論理プロセッサは一覧のみに戻し、CPU 0 から順に並べるように（高性能 / 高効率で分ける表示を廃止）
- 列数「自動」のときは半分ずつ 2 段に並べるように（8 個なら 0〜3 / 4〜7 の 4 列 × 2 段）。2 / 4 / 8 列の指定は従来どおり

## [1.4.0] - 2026-10-04

### 追加
- **表示の拡大**：ウィンドウを大きくすると、文字・グラフ・アイコン・表の列幅が自動で大きくなるように（「オプション」から切り替え可）
- **拡大・縮小**：⌘+ / ⌘− / ⌘0（表示メニュー・「オプション」からも操作可）。設定は次回起動時も保持
- **CPU の論理プロセッサの並べ方**：「高性能 / 高効率で分ける」（例: 8 個 → 高性能 4・高効率 4）と「まとめて表示」を切り替え。列数（自動 / 2 / 4 / 8 列）も選択可能。設定は保持

## [1.3.0] - 2026-10-04

### 追加
- **インストーラー (.dmg)**：Releases に、開いて Applications にドラッグするだけでインストールできる `TaskManager-vX.Y.Z.dmg` を追加（中に初回起動・アップデート・アンインストールの手順書入り）
- `scripts/make_dmg.sh`：手元でも .dmg を作れるように

## [1.2.0] - 2026-10-04

### 追加
- **履歴タブ**：以前の動きを確認できるように
  - 推移グラフ：CPU・メモリ・ディスク・ネットワーク・GPU を 1 時間〜30 日の期間で表示（マウスを乗せるとその時刻の値を表示）
  - アプリの履歴：期間中に各アプリが使った CPU 時間・ディスク量・最大メモリ・動作時間（10 分単位で集計）
  - 高負荷の記録：CPU 80% 以上 / メモリ 90% 以上になったときの上位 5 プロセス
  - 起動・終了ログ：プロセスの起動と終了の時刻
- **バックグラウンド記録**：LaunchAgent でログイン中は常に 5 秒ごとに記録（履歴タブから有効化 / 停止）。無効のときはアプリを開いている間だけ記録
- 履歴の保存期間：5 秒ごとのデータは 24 時間、1 分ごとのまとめ・アプリ別・ログは 30 日
- `./build_app.sh --install` 時に、バックグラウンド記録を新しいアプリで自動再起動

### セキュリティ
- CodeQL による静的解析（Pull Request ごと・毎週）を追加
- gitleaks による秘密情報の検査を追加（GitHub Actions で Pull Request ごと・毎週、手元ではコミット前フック）
- 脆弱性情報の週次チェックの運用と、構成要素の一覧（docs/security/components.md）を追加

### 変更
- README に免責事項と商標についての表記を追加

### 修正
- `release.sh --push` で main とタグを別々に push するように（同時に送ると自動リリースが起動しないことがあるため）

## [1.1.0] - 2026-10-03

### 追加
- 前回開いていたタブ（プロセス / パフォーマンス など）を、次回起動時にそのまま開くように
- パフォーマンス タブで選んでいた項目（CPU / メモリ / ディスク / ネットワーク / GPU）を記憶
- CPU グラフの表示モード（全体の使用率 / 論理プロセッサ）を記憶
- `./build_app.sh --install`：/Applications へ安全にインストール（起動中のアプリの終了・古いアプリの削除・署名確認まで自動）

### 修正
- `/Applications` のアプリに `cp -R` で上書きすると「Code Signature Invalid」で起動直後に強制終了する問題への対策（手順を変更）

## [1.0.0] - 2026-10-03

### 追加
- プロセス タブ：アプリ / バックグラウンド プロセスの分類、子プロセスのグループ化、CPU・メモリ・ディスクのヒートマップ表示
- パフォーマンス タブ：CPU（全体 / 論理プロセッサごと）・メモリ・ディスク・ネットワーク・GPU のリアルタイムグラフ
- スタートアップ アプリ タブ：LaunchAgents / LaunchDaemons の一覧と有効化・無効化
- ユーザー タブ：ユーザー別の使用量とプロセス一覧
- 詳細 タブ：全プロセスの詳細、優先度の変更、プロセス ツリーの終了
- タスクの終了 / 強制終了、新しいタスクを実行、検索、更新速度の変更、常に手前に表示
- ⌘1〜⌘5 でのタブ切り替え
- 専用のアプリアイコン
- アプリ内（サイドバー下部）へのバージョン表示

### セキュリティ
- プロセスの終了・優先度変更の直前に、同じプロセスかを確認する PID 再利用対策
- 管理者権限で実行する前に、実行するコマンドを表示
- Hardened Runtime を有効にして署名
- SECURITY.md（脆弱性の報告方法）を追加

[Unreleased]: https://github.com/pimm-k/mac-system-monitor/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/pimm-k/mac-system-monitor/compare/v1.4.2...v2.0.0
[1.4.2]: https://github.com/pimm-k/mac-system-monitor/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/pimm-k/mac-system-monitor/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/pimm-k/mac-system-monitor/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/pimm-k/mac-system-monitor/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/pimm-k/mac-system-monitor/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/pimm-k/mac-system-monitor/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pimm-k/mac-system-monitor/releases/tag/v1.0.0
