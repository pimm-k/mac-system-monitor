#!/bin/bash
# Pull Request の作成とチェック待ちを 1 コマンドで行う。
#
#   git pr            push → PR が無ければ作成 → チェック完了まで待つ
#   git pr -m         上に加えて、全チェック成功ならスカッシュマージ → main に戻って pull
#   git pr -w         チェック待ちだけ (gh pr checks --watch と同じ)
#
# (git pr は ./scripts/setup-hooks.sh 実行後に使えます。直接 ./scripts/pr.sh でも可)
set -euo pipefail
cd "$(dirname "$0")/.."

MERGE=0; WATCH_ONLY=0
case "${1:-}" in
  -m|--merge) MERGE=1 ;;
  -w|--watch) WATCH_ONLY=1 ;;
  "") ;;
  *) echo "使い方: git pr [-m | -w]"; exit 1 ;;
esac

command -v gh >/dev/null || { echo "❌ gh が必要です: brew install gh"; exit 1; }
BRANCH=$(git branch --show-current)
[ "$BRANCH" != "main" ] || { echo "❌ main では使えません。作業ブランチに切り替えてください"; exit 1; }

if [ "$WATCH_ONLY" -eq 0 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️  コミットされていない変更があります (push されるのはコミット済みの分だけです)"
  fi
  git push -u origin "$BRANCH"
  if ! gh pr view "$BRANCH" >/dev/null 2>&1; then
    gh pr create --fill --base main
  fi
fi

# PR を作った直後は GitHub にチェックがまだ登録されていないことがあるので、出てくるまで待つ (最大 2 分)
for _ in $(seq 1 24); do
  if gh pr checks "$BRANCH" 2>&1 | grep -q "no checks reported"; then
    sleep 5
  else
    break
  fi
done

echo "⏳ チェックの完了を待っています…"
if gh pr checks "$BRANCH" --watch --interval 10 --fail-fast; then
  echo "✅ すべてのチェックが成功しました"
else
  echo "❌ 失敗したチェックがあります: gh pr checks $BRANCH"
  exit 1
fi

if [ "$MERGE" -eq 1 ]; then
  gh pr merge "$BRANCH" --squash --delete-branch
  git switch main && git pull --ff-only
  git branch -D "$BRANCH" 2>/dev/null || true
  echo "✅ マージして main を最新にしました"
fi
