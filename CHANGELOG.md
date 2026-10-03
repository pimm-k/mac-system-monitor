# 変更履歴 / Changelog

このプロジェクトの主な変更点を記録します。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョン番号は [セマンティック バージョニング](https://semver.org/lang/ja/) に従います。

- **MAJOR**（1.x.x → 2.0.0）：使い方が大きく変わる・互換性がなくなる変更
- **MINOR**（1.0.x → 1.1.0）：機能の追加
- **PATCH**（1.0.0 → 1.0.1）：バグ修正・小さな改善

## [Unreleased]

### セキュリティ
- CodeQL による静的解析（Pull Request ごと・毎週）を追加
- gitleaks による秘密情報の検査を追加（GitHub Actions で Pull Request ごと・毎週、手元ではコミット前フック）
- 脆弱性情報の週次チェックの運用と、構成要素の一覧（docs/security/components.md）を追加

### 変更
- README に免責事項と商標についての表記を追加

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

[Unreleased]: https://github.com/pimm-k/mac-task-manager/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/pimm-k/mac-task-manager/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pimm-k/mac-task-manager/releases/tag/v1.0.0
