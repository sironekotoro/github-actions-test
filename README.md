# github-actions-test

ChatGPT / Issue から投入したタスクを、GitHub Actions と self-hosted runner 上の隔離 container 経由で coding agent に処理させる **中央 dispatch 基盤** の動作確認リポジトリ。

## 目的

- **どの repository に対するタスクなのかを機械的に保証**し、wrong-repository execution を構造的に防ぐ。
- 非 dry-run の coding agent は必ず `.git` / GitHub mutation credential / host HOME から隔離して実行する。
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
  ↓ .git-free /workspace + read-only /baseline
  ↓ isolated Docker coding agent + repository tests
  ↓ trusted outer patch validation/import
  ↓ reject .github/workflows/** agent diffs
  ↓ trusted commit / push / PR in target repo
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
  ↓ isolated repair agent / tests / checked patch import
  ↓ trusted same-branch push
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
  "runner_mode": "self-hosted",
  "dry_run": false
}
```

`runner_mode` を省略した場合も `self-hosted` が既定。Issue に `opencode-run` または `agent:ready` ラベルを付けると実行される。許可 actor 以外による起動は `UNAUTHORIZED_ACTOR` で停止する。

## workflow_dispatch / runner policy

Actions -> **Agent Dispatch** -> **Run workflow** から `target_repository` / `task_id` / `title` / `prompt` / `dry_run` を指定する。

- `runner_mode=self-hosted`: 既定。coding agent を実行できる唯一の経路。
- `runner_mode=github`: **dry-run 専用**。`dry_run=true` の場合だけ auth / checkout / identity / default branch / prompt build を検証する。
- `runner_mode=github` + `dry_run=false`: `INVALID_PAYLOAD` で fail-closed。GitHub-hosted runner 上で coding agent を直接実行する経路はない。

self-hosted 経路では coding agent と repository tests を Docker の使い捨て・non-root・read-only container に閉じ込め、agent へは target checkout の `.git`、host HOME、SSH、GitHub/App token、Docker socket を渡さない。agent は `/workspace` のみ編集でき、`/baseline` は read-only。trusted outer executor が filesystem diff を patch 化し、parse / applicability / whitespace validation を通した後だけ target checkout へ importする。

Cross-repoを初めて試す場合は `runner_mode=github` + `dry_run=true` または `self-hosted` + `dry_run=true` を推奨する。dry-runでは agent / branch / commit / push / PR は実行しない。

## Repository authorization

`config/allowed-repositories.txt` が target allowlist の正本。

- allowlist外 -> `TARGET_REPOSITORY_NOT_ALLOWED`
- cross-repo feature disabled / App未設定 -> `CROSS_REPO_AUTH_UNAVAILABLE`
- checkout identity mismatch -> `REPOSITORY_IDENTITY_MISMATCH`

Cross-repo path は `CROSS_REPO_ENABLED=true` の Actions variable と GitHub App secrets が揃うまで fail-closed。

GitHub Appの最小権限・セットアップ手順は [docs/CROSS_REPO_DISPATCH.md](docs/CROSS_REPO_DISPATCH.md) を参照。

## Agent / credential profiles

`agent` と `runner_mode` は独立した task fields だが、agent execution は self-hosted isolation 内だけで許可される。API-backed profiles の対応は次のとおり。

| agent | profile | CLI | repository secret | runtime credential |
|---|---|---|---|---|
| `opencode` | `openrouter` | `opencode run --auto --agent build --print-logs -m "$model" "$prompt"` | `OPENROUTER_API_KEY` | `OPENROUTER_API_KEY` |
| `codex` | `openai-api` | `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$prompt"` | `OPENAI_API_KEY` | `CODEX_API_KEY` |
| `claude-code` | `anthropic-api` | `claude -p "$prompt"` | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` |

workflow は選択された秘密値だけを `AGENT_CREDENTIAL_VALUE` として isolated wrapper へ渡し、`run-agent.sh` / adapter が `env -i` の clean environment 内で対応する runtime 名へ変換する。Codex 0.147.0 の headless API auth だけは source secret `OPENAI_API_KEY` を process boundary で `CODEX_API_KEY` に変換する。

他の API key、`GH_TOKEN` / `GITHUB_TOKEN`、host の CLI 認証状態は agent process に入らない。self-hosted image には pinned versions の3 CLIを含める。

`chatgpt-subscription` と `claude-subscription` は将来の安全な credential handoff 用に profile として表現されているが、現在は `AGENT_AUTH_FAILED` で実行前に fail-closedする。host の既存ログイン状態への fallback はない。

## Workflow-file publication policy

Agent Dispatch / Review Repair が生成した `.github/workflows/**` の変更は **自動 publish しない**。

- same-repo: `WORKFLOW_PUSH_AUTH_NOT_CONFIGURED` で fail-closed
- cross-repo: `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED` で fail-closed
- coding agent に workflow-write credential は渡さない
- trusted outer layer にも agent-generated workflow を publish するための `permission-workflows: write` token route は存在しない

workflow変更が必要な場合は、agentの自動PR経路とは分離して、人間または別のtrusted processで内容を確認してから適用する。

## 重要な安全策

- target repository は task metadata + allowlist が正本。prompt本文から変更できない。
- dispatcher checkout と target checkout を別々に identity guard する。
- 非 dry-run agent execution は **self-hosted isolated Docker のみ**。
- agent は **1 task = 1 fresh session**。
- agentへ `.git` / host HOME / SSH / GitHub mutation token / Docker socket を渡さない。
- provider egress は allowlisted API domains に限定する。
- main/master に直接 commit しない。`agent/<task_id>` branchを使用。
- duplicate branch / open PR は `TASK_ALREADY_RUNNING` で停止。
- prompt は shell interpolationせず、本文をログへ出さない。
- returned patch は trusted outer layer が parse / whitespace / applicability を検証する。
- agent-generated `.github/workflows/**` は自動publishしない。
- trusted commit stageでは repository-controlled Git hooksを無効化する。
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

最後のvariableはJSON array。`self-hosted` と専用の `review-repair` labelが必須で、未設定・不正な場合はdispatcherがfail-closedで停止する。長時間のagent処理を `ubuntu-latest` へfallbackする経路はない。self-hosted runnerには必要なlabels、Docker、git、`gh`、`jq` を用意する。coding CLI自体はtrusted Docker imageへpinして構築する。

即時rollbackは `REVIEW_REPAIR_ENABLED=false`。通常のIssue dispatchと既存PRには影響しない。

## 開発

```bash
bash tests/run-all.sh
npm test
```

CI (`.github/workflows/ci.yml`) が push / PR で実行される。

## インシデント時

`REPOSITORY_IDENTITY_MISMATCH` やその他 failure category が出た場合は [docs/RUNBOOK.md](docs/RUNBOOK.md) を参照。

## Cost and runner preflight

Optional Phase A controls can defer paid inference below a protected budget floor and can detect an unavailable self-hosted runner before a live job is created. They are feature-gated for safe rollout; see [`docs/PHASE_A_BUDGET_RUNNER.md`](docs/PHASE_A_BUDGET_RUNNER.md).

## Phase B1: Provider broker (opt-in)

The provider-broker phases add an optional trusted proxy that keeps provider
credentials outside the untrusted agent container. When `PROVIDER_BROKER_ENABLED=true`:

- A dedicated hardened broker container is selected for OpenRouter, OpenAI, or Anthropic
- Provider/admin credentials held by the trusted broker never reach the agent
- The agent receives only an opaque broker capability token
- The broker validates every request against policy (model, path, concurrency, budget)
- Providers with ephemeral credentials clean them up; Anthropic keeps its static key broker-only
- See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for full details

Anthropic production plumbing is intentionally inert: ordinary Claude Dispatch
routes through the conservative spend guard, but the workflow pins
`ANTHROPIC_BROKER_LIVE_ALLOWED=false`. Phase A also continues to return
`PROVIDER_BUDGET_UNKNOWN` for paid Anthropic execution. Enabling real Anthropic
forwarding requires a separate reviewed rollout.
