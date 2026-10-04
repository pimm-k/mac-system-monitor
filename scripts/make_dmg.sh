#!/bin/bash
# ドラッグ＆ドロップでインストールできる .dmg を作る
#   使い方: ./scripts/make_dmg.sh            (先に ./build_app.sh --no-open で SystemMonitor.app を作っておく)
#   出力:   SystemMonitor-v<バージョン>.dmg と .sha256
set -euo pipefail
cd "$(dirname "$0")/.."

APP="SystemMonitor.app"
VERSION="$(tr -d ' \n\r' < VERSION)"
NAME="SystemMonitor-v${VERSION}"
DMG="${NAME}.dmg"
VOLNAME="システムモニター ${VERSION}"

[ -d "$APP" ] || { echo "❌ $APP がありません。先に ./build_app.sh --no-open を実行してください" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 中身: アプリ / Applications へのショートカット / はじめにお読みください
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/はじめにお読みください.txt" <<TXT
システムモニター (System Monitor) for Mac v${VERSION}

■ インストール
  「システムモニター」のアイコンを、右の「Applications」フォルダにドラッグしてください。

■ 初めて起動するとき
  このアプリは Apple の公証 (notarization) を受けていないため、最初はブロックされます。
  1. 「アプリケーション」フォルダの システムモニター を開く（ブロックの表示が出たら閉じる）
  2. 「システム設定」→「プライバシーとセキュリティ」を開く
  3. 下の方の「"システムモニター" は開いていません」の横にある「このまま開く」を押す

■ 旧名「タスク マネージャー」(TaskManager.app, v1.x) を使っていた場合
  新しいシステムモニターを初めて起動すると、設定・履歴・バックグラウンド記録が自動で引き継がれます。
  引き継ぎ後、古い TaskManager.app はゴミ箱に入れて構いません。

■ アップデート
  古いシステムモニターを終了してから、同じようにドラッグして「置き換える」を選んでください。

■ アンインストール
  1. アプリの「履歴」タブで「バックグラウンド記録を停止」を押す（有効にしている場合）
  2. 「アプリケーション」フォルダの システムモニター をゴミ箱へ
  3. 履歴データも消す場合: ~/Library/Application Support/SystemMonitor を削除

詳しくは https://github.com/pimm-k/mac-system-monitor
TXT

rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
shasum -a 256 "$DMG" > "$DMG.sha256"

echo "✅ 作成しました: $(pwd)/$DMG"
cat "$DMG.sha256"
