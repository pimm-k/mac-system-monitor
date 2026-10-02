# セキュリティポリシー / Security Policy

## 脆弱性の報告 / Reporting a Vulnerability

脆弱性を見つけた場合は、**公開の Issue には書かず**、GitHub の非公開報告機能から連絡してください。

1. このリポジトリの **Security** タブを開く
2. **Report a vulnerability** をクリック
3. 再現手順・影響・環境（macOS のバージョンなど）を記入

内容を確認のうえ、できるだけ早く返信します。修正が公開されるまでは、内容を公開しないようお願いします。

Please **do not open a public issue**. Use GitHub's private vulnerability reporting
(**Security** tab → **Report a vulnerability**) and include steps to reproduce, impact,
and your macOS version.

## 対象バージョン / Supported Versions

| バージョン | サポート |
|---|---|
| 最新のリリース | ✅ |
| それ以前 | ❌ |

## このアプリのセキュリティ設計 / Security Design

- **ネットワーク通信なし**：外部への送信・テレメトリ・自動アップデートは一切行いません。
- **履歴データはローカルのみ**：プロセス名・パス・ユーザー名・使用量を `~/Library/Application Support/TaskManager/history.sqlite` に保存します。フォルダは 0700、ファイルは 0600 の権限で作成し、30 日を過ぎたデータは自動で削除します。アプリからいつでも全削除できます。
- **バックグラウンド記録は任意**：LaunchAgent は利用者が明示的に有効にしたときだけ登録し、優先度を下げて（Nice 10・低優先 I/O）動作します。root 権限は使いません。
- **外部ライブラリなし**：Apple 標準フレームワークのみを使用しています。
- **コマンド実行**：`/bin/ps`・`/bin/launchctl`・`/usr/bin/osascript` などをフルパスで、シェルを介さずに起動します。
- **管理者権限**：必要な操作のたびに macOS 標準の認証ダイアログを表示します。実行するコマンドは事前にダイアログで表示され、アプリはパスワードを扱いません。常駐する特権ヘルパーはインストールしません。
- **入力のエスケープ**：plist から読み込んだ値はシェル用・AppleScript 用にエスケープしてから使用します。
- **PID 再利用対策**：プロセスを終了・変更する直前に、一覧に表示していたプロセスと同一か（実行ファイルのパス）を確認します。管理者権限での実行時も、実行直前に再確認します。
- **Hardened Runtime**：`build_app.sh` で Hardened Runtime を有効にして署名します。
- **App Sandbox は未使用**：プロセスの終了や LaunchDaemons の操作に必要なため、意図的に無効です。
