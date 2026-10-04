#!/bin/bash
# Git フック (.githooks/) を有効にする。clone した後に 1 回だけ実行する。
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
echo "✅ Git フックを有効にしました (.githooks/)"
git config alias.pr '!./scripts/pr.sh'
echo "✅ git pr コマンドを使えるようにしました (PR 作成とチェック待ち)"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "⚠️  gitleaks が入っていません。次のコマンドでインストールしてください:"
  echo "    brew install gitleaks"
fi
