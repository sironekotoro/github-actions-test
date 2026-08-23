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

Review repair is a separate, feature-gated path:

```text
authorized CHANGES_REQUESTED review
  ├─ same repo: pull_request_review event
  └─ cross repo: central allowlist poll + target-scoped App token
  ↓ GitHub-hosted dispatcher: authorize + validate + reserve review ID/attempt
  ↓ asynchronously dispatch one executor request, then exit without waiting
  ↓ self-hosted executor: revalidate current metadata / bot / head SHA
  ↓ resume the existing agent/<task_id> branch
  ↓ repair agent / tests / git diff --check / same-branch push
  ↓ record result; never create or merge another PR
```

詳細:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/CROSS_REPO_DISPATCH.md](docs/CROSS_REPO_DISPATCH.md)
- [docs/REVIEW_REPAIR.md](docs/REVIEW_REPAIR.md)
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

Actions -> **Agent Dispatch** -> **Run workflow** から `target_repository` / `task_id` / `title` / `prompt` / `dry_run` を指定する。`runner_mode` は未指定または `github` なら従来どおり GitHub-hosted `ubuntu-latest` を使う。`self-hosted` は明示 opt-in の実験経路で、現在は `REVIEW_REPAIR_RUNNER_LABELS` に設定された Mac runner のみを選択する。

`runner_mode` は Issue の task JSON にも指定できる。受理値は `github` と `self-hosted` のみで、未知の値は agent を開始せず `INVALID_PAYLOAD` で停止する。self-hosted 経路では OpenCode と repository test を Docker の使い捨て・non-root・read-only container に閉じ込め、agent へは .git、host HOME、SSH、GitHub/App token、Docker socket を渡さない。commit / push / PR 作成だけは既存どおり trusted outer executor が行う。

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
- review repairは `CHANGES_REQUESTED` のみを扱い、review本文をuntrusted inputとして明示的に区切る。
- initial dispatchのduplicate guardは維持し、repair専用pathだけが検証済みの既存PR branchを再開する。
- PR/branch/head SHA/base/default branch/bot principal/task metadata hashが一致しなければrepair agentを起動しない。
- 同じreview IDは一度だけagentへ渡し、1 PRあたり既定3回で停止する。auto-mergeは行わない。

## Review repair operator controls

Review repairは既定で無効。Actions repository variableを明示設定したときだけ動く。

```text
REVIEW_REPAIR_ENABLED=true   # enable; missing/false disables the whole loop
REVIEW_REPAIR_MAX=3          # optional, accepted range 1..10
REVIEW_REPAIR_MODEL=...      # optional model override
REVIEW_REPAIR_RUNNER_LABELS=["self-hosted","review-repair"]
```

最後のvariableはJSON array。`self-hosted` と専用の `review-repair` labelが必須で、
未設定・不正な場合はdispatcherがfail-closedで停止する。長時間のagent処理を
`ubuntu-latest` へfallbackする経路はない。self-hosted runnerには必要なlabels、
OpenCode、Node/npm、git、`gh`、`jq`、GNU `timeout`互換コマンドを事前に用意する。

即時rollbackは `REVIEW_REPAIR_ENABLED=false`。通常のIssue dispatchと既存PRには影響しない。

## 開発

```bash
bash tests/run-all.sh
npm test
```

CI (`.github/workflows/ci.yml`) が push / PR で実行される。

## インシデント時

<!-- self-hosted-final-validation-20260823b -->
