#!/bin/bash
# Pull Request の作成とチェック待ちを 1 コマンドで行う。
#
#   git pr            push → PR が無ければ作成 → チェック完了まで待つ
#   git pr -m         上に加えて、全チェック成功ならスカッシュマージ → main に戻って pull
#   git pr -w         チェック待ちだけ (push・マージはしない)
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

# このコミットの GitHub Actions (CI / CodeQL / Secrets) がすべて終わるまで待つ。
# ※ gh pr checks は、macOS の実行環境を待っている (まだ始まっていない) チェックを数えないことがあり、
#   先に終わったチェックだけを見て「すべて成功」と判定してしまうため、ワークフローの実行単位で確認する。
HEAD_SHA=$(git rev-parse HEAD)
echo "⏳ チェックの完了を待っています… (${HEAD_SHA:0:7})"
runs() { gh run list --commit "$HEAD_SHA" --limit 50 "$@" 2>/dev/null; }

# 実行が登録されるまで待つ (最大 2 分)
for _ in $(seq 1 24); do
  N=$(runs --json databaseId --jq 'length' || echo 0)
  [ "${N:-0}" -gt 0 ] && break
  sleep 5
done
if [ "${N:-0}" -eq 0 ]; then
  echo "❌ このコミットのチェックが見つかりません: gh pr checks $BRANCH"
  exit 1
fi
sleep 10   # 同時に始まるほかのワークフローも登録されるのを待つ

# すべて終わるまで待つ (最大 40 分)
LAST=""
for _ in $(seq 1 160); do
  STATUS=$(runs --json name,status,conclusion --jq 'sort_by(.name)[] | "  \(.name): \(if .status == "completed" then .conclusion else .status end)"' || true)
  if [ "$STATUS" != "$LAST" ]; then echo "$STATUS"; echo "  ---"; LAST="$STATUS"; fi
  PENDING=$(runs --json status --jq '[.[] | select(.status != "completed")] | length' || echo 1)
  [ "${PENDING:-1}" -eq 0 ] && break
  sleep 15
done

FAILED=$(runs --json conclusion --jq '[.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")] | length' || echo 1)
PENDING=$(runs --json status --jq '[.[] | select(.status != "completed")] | length' || echo 1)
if [ "${PENDING:-1}" -ne 0 ]; then
  echo "❌ 時間内にチェックが終わりませんでした: gh pr checks $BRANCH"
  exit 1
elif [ "${FAILED:-1}" -ne 0 ]; then
  echo "❌ 失敗したチェックがあります: gh pr checks $BRANCH"
  exit 1
fi
echo "✅ すべてのチェックが成功しました"

if [ "$MERGE" -eq 1 ]; then
  gh pr merge "$BRANCH" --squash --delete-branch
  git switch main && git pull --ff-only
  git branch -D "$BRANCH" 2>/dev/null || true
  echo "✅ マージして main を最新にしました"
fi
