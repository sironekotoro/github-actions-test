# github-actions-test

ChatGPT / Issue から投入したタスクを、GitHub Actions 経由で OpenCode（OpenRouter）を起動して処理する **中央 dispatch 基盤** の動作確認リポジトリ。

## 目的

- **どの repository に対するタスクなのかを機械的に保証**し、wrong-repository execution を構造的に防ぐ。
- Issue / `workflow_dispatch` から投入したタスクが確実に agent job まで到達し、失敗時には failure category が明確に分かる。
- GitHub App を使った **target-scoped / short-lived credential** により、許可済みの別 repository へ安全に dispatch できるようにする。

## アーキテクチャ

```text
ChatGPT / ユーザー
  ↓  Issue + label / workflow_dispatch
sironekotoro/github-actions-test
  ↓ authorize actor
  ↓ parse immutable task metadata
  ↓ verify dispatcher checkout identity
  ↓ authorize target repository against allowlist
  ├─ same repo: GITHUB_TOKEN
  └─ cross repo: target-scoped GitHub App installation token
                  ↓ checkout ./target
                  ↓ verify target checkout identity
  ↓ dry-run OR prepare agent/<task_id>
  ↓ OpenCode (fresh session)
  ↓ tests / commit / push / PR in target repo
  ↓ feedback to central Issue
```

詳細:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/CROSS_REPO_DISPATCH.md](docs/CROSS_REPO_DISPATCH.md)
- [docs/RUNBOOK.md](docs/RUNBOOK.md)

## タスク payload

Issue 本文は JSON payload（全体、`json` fenced block、または JSON 1 行）で指定する。

```json
{
  "task_id": "example-001",
  "target_repository": "sironekotoro/github-actions-test",
  "title": "README を確認",
  "prompt": "README.md を読み、repository name を確認してください。",
  "dry_run": false
}
```

Issue に `opencode-run` または `agent:ready` ラベルを付けると実行される。許可 actor 以外による起動は `UNAUTHORIZED_ACTOR` で停止する。

## workflow_dispatch

Actions -> **Agent Dispatch** -> **Run workflow** から `target_repository` / `task_id` / `title` / `prompt` / `dry_run` を指定する。

Cross-repoを初めて試す場合は `dry_run=true` を推奨する。dry-runでは auth / checkout / identity / default branch / prompt build まで検証し、agent / branch / commit / push / PR は実行しない。

## Repository authorization

`config/allowed-repositories.txt` が target allowlist の正本。

- allowlist外 -> `TARGET_REPOSITORY_NOT_ALLOWED`
- cross-repo feature disabled / App未設定 -> `CROSS_REPO_AUTH_UNAVAILABLE`
- checkout identity mismatch -> `REPOSITORY_IDENTITY_MISMATCH`

Cross-repo path は `CROSS_REPO_ENABLED=true` の Actions variable と GitHub App secrets が揃うまで fail-closed。

GitHub Appの最小権限・5分セットアップ手順は [docs/CROSS_REPO_DISPATCH.md](docs/CROSS_REPO_DISPATCH.md) を参照。

## 重要な安全策

- target repository は task metadata + allowlist が正本。prompt本文から変更できない。
- dispatcher checkout と target checkout を別々に identity guard する。
- agent は **1 task = 1 fresh session**。
- main/master に直接 commit しない。`agent/<task_id>` branchを使用。
- duplicate branch / open PR は `TASK_ALREADY_RUNNING` で停止。
- prompt は shell interpolationせず、本文をログへ出さない。
- cross-repo tokenはGitHub App installation tokenで対象repoへ限定し、値をログへ出さない。

## 開発

```bash
bash tests/run-all.sh
npm test
```

CI (`.github/workflows/ci.yml`) が push / PR で実行される。

## インシデント時

`REPOSITORY_IDENTITY_MISMATCH` やその他 failure category が出た場合は [docs/RUNBOOK.md](docs/RUNBOOK.md) を参照。
