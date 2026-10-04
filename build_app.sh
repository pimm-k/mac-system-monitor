#!/bin/bash
# TaskManager.app をビルドして同じフォルダに作成します
#   使い方:  ./build_app.sh            (作成後、自動で起動)
#            ./build_app.sh --install  (/Applications に安全にインストールして起動)
#            ./build_app.sh --no-open  (起動しない / CI 用)
set -euo pipefail
cd "$(dirname "$0")"

APP="TaskManager.app"
OPEN_APP=1
INSTALL=0
case "${1:-}" in
  --no-open) OPEN_APP=0 ;;
  --install) INSTALL=1 ;;
esac
[ -n "${CI:-}" ] && OPEN_APP=0

# --- バージョン情報 (VERSION ファイルが唯一の正)
VERSION="$(tr -d ' \n\r' < VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ VERSION の形式が不正です: '$VERSION' (例: 1.2.3)" >&2
  exit 1
fi
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  COMMIT="${COMMIT}-dirty"   # 未コミットの変更を含むビルド
fi

echo "▶ リリースビルド中... (v$VERSION, build $BUILD, $COMMIT)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/TaskManager"

echo "▶ $APP を作成中..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TaskManager"
# 軽量化: デバッグ用のシンボル情報を取り除いてサイズを小さくする
strip -S -x "$APP/Contents/MacOS/TaskManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Info.plist にバージョンを書き込む
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :TMGitCommit string $COMMIT" "$PLIST"

# アイコン
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# アドホック署名 + Hardened Runtime (コード注入・デバッガのアタッチ等を防ぐ)
codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict "$APP" && echo "▶ 署名を確認しました (Hardened Runtime 有効)"

# Finder/Dock にアイコンの更新を知らせる
touch "$APP"

echo "✅ 完了: $(pwd)/$APP  (v$VERSION build $BUILD)"

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications/$APP"
  echo "▶ $DEST にインストール中..."
  # 起動中なら終了させる (起動していないときに quit を送ると逆に起動してしまうので確認してから)
  if pgrep -f "$DEST/Contents/MacOS/TaskManager" >/dev/null 2>&1; then
    osascript -e 'tell application id "local.pim.taskmanager" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -f "$DEST/Contents/MacOS/TaskManager" 2>/dev/null || true
  fi
  # 重要: 既存のアプリに上書きコピー (cp -R) すると、署名のキャッシュと中身が食い違い
  #       "Code Signature Invalid" で起動直後に強制終了される。必ず削除してから新規にコピーする。
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  codesign --verify --strict "$DEST"
  echo "✅ インストールしました: $DEST"
  # バックグラウンド記録 (LaunchAgent) を使っていれば新しいアプリで再起動する
  AGENT="local.pim.taskmanager.recorder"
  if [ -f "$HOME/Library/LaunchAgents/$AGENT.plist" ]; then
    launchctl kickstart -k "gui/$(id -u)/$AGENT" >/dev/null 2>&1 \
      || launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT.plist" >/dev/null 2>&1 || true
    echo "▶ バックグラウンド記録を再起動しました"
  fi
  if [ "$OPEN_APP" = 1 ]; then open "$DEST"; fi
elif [ "$OPEN_APP" = 1 ]; then
  echo "   /Applications に入れるときは ./build_app.sh --install を使ってください。"
  echo "   (cp -R で上書きすると起動できなくなります)"
  open "$APP"
fi
