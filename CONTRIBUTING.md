# 開発・リリースのルール

## 最初の準備（clone した後に 1 回）

```bash
brew install gitleaks        # 秘密情報の検出ツール
./scripts/setup-hooks.sh     # コミット前に自動で検査するフックを有効化
```

## ブランチ運用（GitHub Flow）

```
main ──●────────●──────────●────── (常にリリースできる状態)
        \      /  \        /
         ●──●─●    ●──●──●
     feature/xxx   fix/yyy
```

- **`main`**：常にビルドが通り、リリースできる状態に保ちます。直接コミットせず、Pull Request 経由でマージします。
- **作業ブランチ**：`main` から作り、終わったら PR を出してマージ → 削除します。

| プレフィックス | 用途 | 例 |
|---|---|---|
| `feature/` | 機能追加 | `feature/network-per-process` |
| `fix/` | バグ修正 | `fix/cpu-graph-overflow` |
| `docs/` | ドキュメントのみ | `docs/readme-screenshots` |
| `chore/` | ビルド・設定・依存関係など | `chore/update-actions` |
| `security/` | 脆弱性の修正 | `security/CVE-2026-12345` |

### 作業の流れ

```bash
git switch main && git pull
git switch -c feature/xxx        # ブランチを作る
# ... 作業・コミット ...
git push -u origin feature/xxx   # GitHub で Pull Request を作成
# CI（自動ビルド）が通ったらマージ
git switch main && git pull && git branch -d feature/xxx
```

## コミットメッセージ（Conventional Commits）

```
<種類>: <内容>
```

| 種類 | 意味 | バージョンへの影響 |
|---|---|---|
| `feat` | 機能追加 | MINOR を上げる |
| `fix` | バグ修正 | PATCH を上げる |
| `perf` | 性能改善 | PATCH |
| `refactor` | 動作を変えないコード整理 | — |
| `docs` | ドキュメント | — |
| `chore` | ビルド・設定など | — |
| `security` | セキュリティ修正 | PATCH（以上） |

例：`feat: プロセスごとのネットワーク使用量を表示` / `fix: メモリグラフが 100% を超える問題を修正`

互換性がなくなる変更は `feat!: ...` のように `!` を付け、MAJOR を上げます。

## 変更履歴（CHANGELOG.md）

ユーザーに影響がある変更をしたら、`CHANGELOG.md` の `[Unreleased]` に書きます。
見出しは `### 追加` / `### 変更` / `### 修正` / `### 削除` / `### セキュリティ` を使います。

## リリース手順

1. `main` に必要な変更がすべてマージされ、`CHANGELOG.md` の `[Unreleased]` が書けていることを確認
2. リリーススクリプトを実行
   ```bash
   ./scripts/release.sh 1.1.0 --push
   ```
   - `VERSION` と `CHANGELOG.md` を更新してコミット
   - `v1.1.0` タグを作成して push
3. GitHub Actions が自動でアプリをビルドし、**Releases** に zip を公開します

バージョン番号は **`VERSION` ファイルが唯一の正**です。手で書き換えず、リリーススクリプトを使ってください。

## main ブランチの保護（リポジトリ管理者向け）

GitHub の **Settings → Rules → Rulesets → New branch ruleset** で以下を設定します。

- Target branches：`main`（Default branch）
- ✅ Restrict deletions
- ✅ Block force pushes
- ✅ Require a pull request before merging
- ✅ Require status checks to pass → `Build (macOS)`・`Analyze (Swift)`・`Secret scan (gitleaks)` を追加

## 外部からの貢献について

本プロジェクトのライセンスでは、作者の許可のない改変を認めていません。
不具合の報告や機能の提案は **Issue** で歓迎します。Pull Request を送りたい場合は、先に Issue で相談してください。
セキュリティ上の問題は [SECURITY.md](SECURITY.md) の手順で報告してください。
