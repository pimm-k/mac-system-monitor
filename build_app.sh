#!/bin/bash
# TaskManager.app をビルドして同じフォルダに作成します
#   使い方:  ./build_app.sh        (作成後、自動で起動)
set -euo pipefail
cd "$(dirname "$0")"

APP="TaskManager.app"
echo "▶ リリースビルド中..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/TaskManager"

echo "▶ $APP を作成中..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TaskManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# アイコン (任意): Resources/AppIcon.icns があれば同梱
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# アドホック署名 + Hardened Runtime (コード注入・デバッガのアタッチ等を防ぐ)
codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict "$APP" && echo "▶ 署名を確認しました (Hardened Runtime 有効)"

# Finder/Dock にアイコンの更新を知らせる
touch "$APP"

echo "✅ 完了: $(pwd)/$APP"
echo "   /Applications にドラッグすれば通常のアプリとして使えます。"
open "$APP"
