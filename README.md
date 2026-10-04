<p align="center">
  <img src="docs/icon.png" width="160" alt="アイコン">
</p>

<h1 align="center">mac-task-manager</h1>

<p align="center">
  Windows の「タスク マネージャー」風のシステムモニターを macOS 向けに SwiftUI で作ったアプリです。<br>
  A Windows Task Manager–style system monitor for macOS, built with SwiftUI.
</p>

<p align="center">
  <a href="https://github.com/pimm-k/mac-task-manager/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/pimm-k/mac-task-manager"></a>
  <a href="https://github.com/pimm-k/mac-task-manager/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/pimm-k/mac-task-manager/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-orange">
  <img alt="License" src="https://img.shields.io/badge/license-Use%20Only%20%2F%20No%20Derivatives-lightgrey">
</p>

---

## 機能

| タブ | 内容 |
|---|---|
| **プロセス** | 「アプリ」と「バックグラウンド プロセス」に分けて表示。アプリはヘルパー/子プロセスをまとめて合計表示（▶ で展開）。CPU・メモリ・ディスクはヒートマップ色付き |
| **パフォーマンス** | CPU（全体 / 論理プロセッサごと）・メモリ（構成バー）・ディスク（アクティブ時間 / 転送速度）・ネットワーク（アダプター別、IP / MAC 表示）・GPU のリアルタイムグラフ |
| **履歴** | 以前の動きを確認。CPU・メモリ・ディスク・ネットワーク・GPU の推移グラフ（1 時間〜30 日）、アプリの履歴（CPU 時間・ディスク量など）、高負荷になった瞬間の上位プロセス、プロセスの起動・終了ログ |
| **スタートアップ アプリ** | LaunchAgents / LaunchDaemons の一覧と有効化・無効化 |
| **ユーザー** | ユーザー別の CPU・メモリ・ディスク使用量と、そのユーザーのプロセス |
| **詳細** | 全プロセスの PID・状態・ユーザー・CPU 時間・スレッド・優先度・パス。優先度の変更、プロセス ツリーの終了 |

- タスクの終了 / 強制終了（Delete キー対応）
- 新しいタスクを実行（⌘N）
- タブ切り替え（⌘1〜⌘6）、検索、更新速度の変更、常に手前に表示
- root など他ユーザーのプロセスの操作は、確認後に管理者パスワードで実行

## 動作環境

- macOS 14 (Sonoma) 以降
- Xcode または Command Line Tools（`xcode-select --install`）

## ダウンロード・インストール

1. [Releases](https://github.com/pimm-k/mac-task-manager/releases/latest) から **`TaskManager-vX.Y.Z.dmg`** をダウンロード
2. ダウンロードした .dmg を開き、**TaskManager を「Applications」にドラッグ**
3. 初回だけ、起動がブロックされたら「システム設定」→「プライバシーとセキュリティ」→「**このまま開く**」で許可

> Apple の公証（notarization）を受けていないため、初回のみ 3 の操作が必要です。改ざんされていないかは `.sha256` で確認できます：`shasum -a 256 -c TaskManager-vX.Y.Z.dmg.sha256`

## ビルドと実行

```bash
git clone https://github.com/pimm-k/mac-task-manager.git
cd mac-task-manager

# すぐに動かす
swift run

# .app を作成して /Applications にインストール
./build_app.sh --install
```

> ⚠️ `cp -R` で既存の `/Applications/TaskManager.app` に上書きすると、署名が食い違って起動直後に強制終了します。必ず `--install` を使うか、古いアプリを削除してからコピーしてください。

> 自分の Mac でビルドしたアプリは、そのまま警告なしで起動できます。

## プロジェクト構成

```
Sources/TaskManager/
├── TaskManagerApp.swift      … エントリーポイント
├── Data/
│   ├── Monitor.swift         … 定期更新・履歴・終了などの操作
│   ├── ProcessSampler.swift  … libproc でプロセス情報を取得
│   ├── SystemSampler.swift   … CPU / メモリ / ディスク(IOKit) / ネットワーク / GPU
│   └── LaunchItems.swift     … LaunchAgents / Daemons の読み込みと切り替え
├── Views/                    … 各タブの画面
└── Util/Utilities.swift      … 書式・sysctl・シェル実行
scripts/release.sh            … リリース (バージョン更新・CHANGELOG・タグ作成)
scripts/make_dmg.sh           … インストーラー (.dmg) の作成
.github/workflows/            … CI (自動ビルド) と Release (自動公開)
VERSION                       … バージョン番号 (唯一の正)
Resources/
├── Info.plist
├── AppIcon.icns
└── icon/                     … アイコン原画と生成スクリプト
```

## 履歴の記録について

- 履歴タブの「バックグラウンドで記録する」を押すと、LaunchAgent（`local.pim.taskmanager.recorder`）が登録され、ログイン中は常に 5 秒ごとに記録します。macOS から「バックグラウンド項目が追加されました」という通知が出ます。
- 無効のときは、アプリを開いている間だけ記録します。
- 記録先：`~/Library/Application Support/TaskManager/history.sqlite`（本人のみ読み書きできる権限）。**外部には一切送信しません。**
- 保存期間：5 秒ごとのデータは 24 時間、1 分ごとのまとめ・アプリ別使用量・ログは 30 日。古いものは自動で削除され、容量は数十 MB 程度です。
- 停止・削除：履歴タブの「バックグラウンド記録を停止」と「…」→「すべての履歴を削除」から行えます。

## 制限事項

- 他ユーザー（root）のプロセスは macOS の権限上、詳細を取得できないため CPU 時間・メモリを `ps` から取得しています（スレッド数は「—」表示）。
- プロセスごとのネットワーク・GPU 使用量は公開 API がないため表示していません。
- 起動・終了ログは 5 秒ごとの比較で記録するため、5 秒未満で終了したプロセスは記録されないことがあります。
- 「ログイン項目」（SMAppService で登録されたもの）は一覧取得 API がないため、システム設定を開くボタンで対応しています。
- App Sandbox と両立しない機能を使っているため、Mac App Store では配布していません。

## バージョン管理

- バージョン番号は [セマンティック バージョニング](https://semver.org/lang/ja/) に従い、`VERSION` ファイルで管理しています（アプリのサイドバー下部にも表示）。
- 変更履歴は [CHANGELOG.md](CHANGELOG.md)、開発とリリースの手順は [CONTRIBUTING.md](CONTRIBUTING.md) をご覧ください。

## セキュリティ

ネットワーク通信なし・外部ライブラリなしの構成です。GitHub の CodeQL・Secret scanning に加え、コミット前と GitHub Actions で gitleaks による秘密情報の検査を行っています。管理者権限が必要な操作は、実行するコマンドを表示したうえで macOS 標準の認証ダイアログで確認します。詳しくは [SECURITY.md](SECURITY.md) をご覧ください。脆弱性の報告も SECURITY.md の手順でお願いします。

## ライセンス

使用・無改変での再配布は自由ですが、**改変および改変版の配布は禁止**です。詳しくは [LICENSE](LICENSE) をご覧ください。

## 免責事項・商標について

- 本プロジェクトは個人制作のアプリであり、Microsoft Corporation とは一切関係がなく、同社による承認・提携・後援を受けたものではありません。
- 本アプリは Windows の「タスク マネージャー」の機能や使い勝手を**参考にして独自に開発**したものです。Microsoft のソースコード、アイコン、画像などの素材は一切使用していません。
- 「タスク マネージャー」という呼び名は、Windows の同名機能を参考にした説明的な名称です。
- Microsoft、Windows は、米国 Microsoft Corporation の米国およびその他の国における登録商標または商標です。
- macOS、Mac は、米国およびその他の国で登録された Apple Inc. の商標です。
- その他、記載されている会社名・製品名は、各社の商標または登録商標です。

*This is an independent project and is not affiliated with, endorsed by, or sponsored by Microsoft Corporation. Windows is a registered trademark of Microsoft Corporation in the United States and other countries. macOS and Mac are trademarks of Apple Inc.*
