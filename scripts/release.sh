#!/bin/bash
# 新しいバージョンをリリースします
#   使い方: ./scripts/release.sh 1.1.0          (コミットとタグを作成)
#           ./scripts/release.sh 1.1.0 --push   (作成後に GitHub へ push まで行う)
#
# 事前に CHANGELOG.md の [Unreleased] に変更内容を書いておいてください。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_URL="https://github.com/pimm-k/mac-task-manager"
NEW="${1:-}"
PUSH=0
[ "${2:-}" = "--push" ] && PUSH=1

die() { echo "❌ $*" >&2; exit 1; }

# --- 入力チェック
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "バージョンを X.Y.Z 形式で指定してください (例: ./scripts/release.sh 1.1.0)"
CUR="$(tr -d ' \n\r' < VERSION)"
TAG="v$NEW"

# --- バージョンが上がっているか (semver で比較)
ver_gt() {
  IFS=. read -r a1 a2 a3 <<< "$1"; IFS=. read -r b1 b2 b3 <<< "$2"
  (( a1 > b1 )) && return 0; (( a1 < b1 )) && return 1
  (( a2 > b2 )) && return 0; (( a2 < b2 )) && return 1
  (( a3 > b3 ))
}
ver_gt "$NEW" "$CUR" || die "新しいバージョン ($NEW) は現在 ($CUR) より大きくしてください"

# --- リポジトリの状態チェック
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "main ブランチで実行してください (現在: $BRANCH)"
[ -z "$(git status --porcelain)" ] || die "コミットされていない変更があります。先にコミットしてください"
git rev-parse "$TAG" >/dev/null 2>&1 && die "タグ $TAG はすでに存在します"

# --- [Unreleased] に内容があるか
NOTES="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
[ -n "$NOTES" ] || die "CHANGELOG.md の [Unreleased] が空です。変更内容を書いてください"

# --- CHANGELOG を更新
TODAY="$(date +%Y-%m-%d)"
python3 - "$NEW" "$CUR" "$TODAY" "$REPO_URL" <<'PY'
import sys, re
new, cur, today, url = sys.argv[1:5]
p = "CHANGELOG.md"
s = open(p, encoding="utf-8").read()
s = s.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{new}] - {today}\n", 1)
s = re.sub(r"^\[Unreleased\]: .*$",
           f"[Unreleased]: {url}/compare/v{new}...HEAD\n[{new}]: {url}/compare/v{cur}...v{new}",
           s, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY

echo "$NEW" > VERSION

# --- コミットとタグ
git add VERSION CHANGELOG.md
git commit -q -m "chore(release): $TAG"
git tag -a --cleanup=verbatim "$TAG" -m "Release $TAG" -m "$NOTES"

echo "✅ $TAG を作成しました ($CUR → $NEW)"
echo
echo "リリースノート:"
echo "$NOTES" | sed 's/^/  /'
echo

if [ "$PUSH" = 1 ]; then
  git push origin main --follow-tags
  echo "🚀 push しました。GitHub Actions がビルドして Releases に公開します。"
else
  echo "GitHub に公開するには:"
  echo "  git push origin main --follow-tags"
fi
