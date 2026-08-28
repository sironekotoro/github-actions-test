# Architecture

## Initial dispatch flow

```
ChatGPT / ユーザー
  ↓  Issue 作成 + label ("opencode-run" / "agent:ready")  or  workflow_dispatch inputs
GitHub Issue / dispatch
  ↓
agent-dispatch.yml route job (ubuntu-latest, GitHub-hosted)
  ↓ runner_mode omitted/github -> Agent Dispatch (GitHub-hosted, ubuntu-latest)
  ↓ runner_mode=self-hosted -> Agent Dispatch (self-hosted Mac, explicit opt-in)
  ↓
authorize-actor.sh        actor allowlist チェック
  ↓
parse-task.mjs            JSON payload → task.json
  ↓
guard-dispatcher-repo.sh  dispatcher checkout identity
  ↓
authorize-target.sh       committed allowlist + same/cross mode
  ↓
same: guard-repo.sh       cross: target-scoped App token + target checkout + guard-target-repo.sh
  ↓
prepare-branch.sh         dirty tree / strict duplicate 検査 → agent/<task_id>
  ↓
run-agent.sh              selected adapter (bounded runtime, bounded retry)
  ↓
classify-workflow-push.sh actual post-agent diff + identity/branch/base validation
  ↓
commit-push-pr.sh         npm test → commit → normal/workflow token push → PR (metadata 付き)
  ↓
post-feedback.sh          Issue コメント + Step summary
```

`runner_mode` は task metadata の `github`（既定）または `self-hosted`。route job
が unknown value を fail-closed で拒否してから別々の job を選択するため、通常経路の
`ubuntu-latest` は動的に self-hosted へ変化しない。self-hosted job は既存の
`REVIEW_REPAIR_RUNNER_LABELS` JSON をそのまま使う（現状は専用 Mac）。OpenCode と
untrusted repository tests は review-repair と同じ隔離 container で実行し、外側だけが
validated patch を import して既存の commit/push/PR logic を実行する。

## Agent and credential matrix

`agent` and `runner_mode` are independent task fields. The dispatcher selects
an adapter by `agent`; no workflow step contains provider-specific execution
logic beyond selecting one credential value. The supported API-backed matrix
is:

| agent | profile | exact invocation | credential visible to the CLI |
|---|---|---|---|
| `opencode` | `openrouter` | `opencode run --print-logs -m "$model" "$prompt"` | `OPENROUTER_API_KEY` |
| `codex` | `openai-api` | `codex exec --skip-git-repo-check "$prompt"` | `OPENAI_API_KEY` |
| `claude-code` | `anthropic-api` | `claude -p "$prompt"` | `ANTHROPIC_API_KEY` |

The Codex and Claude adapters deliberately use their documented
noninteractive forms: `codex exec` and `claude -p`. The model input remains an
OpenRouter-compatible override for the default OpenCode path; Codex and Claude
use their CLI defaults until provider-specific model validation is added.

The workflow resolves the selected secret into one generic
`AGENT_CREDENTIAL_VALUE`. `run-agent.sh` then passes only the selected variable
through `env -i`; unrelated API keys, `GH_TOKEN`/`GITHUB_TOKEN`, host CLI
configuration, and arbitrary inherited variables are absent from the agent
process. Repository tests run after the agent with all API variables and the
generic value unset. No `env $string command` construction is used.

`chatgpt-subscription` and `claude-subscription` remain represented in the
compatibility matrix for a future safe implementation, but fail closed with
`AGENT_AUTH_FAILED` before container or CLI execution. There is no host-auth
fallback. Enabling those profiles requires trusted-host identity, a
temporary per-job credential handoff into the selected container, and cleanup.

The trusted self-hosted image pins `opencode-ai@1.18.16`,
`@openai/codex@0.147.0`, and `@anthropic-ai/claude-code@2.1.165`. The disposable
agent network permits HTTPS CONNECT only to the three provider API domains
needed by the API-backed matrix (`*.openrouter.ai`, `api.openai.com`, and
`api.anthropic.com`). The image has all three CLIs, but runtime execution still
requires the selected API credential and never installs a host fallback.

## Review repair flow

`review-repair.yml` is deliberately separate from initial dispatch and is a
short-lived GitHub-hosted control plane. `review-repair-executor.yml` is the
long-running self-hosted data plane.

```text
same-repo pull_request_review:submitted
  OR scheduled cross-repo scan (one target-scoped App token per allowlisted repo)
  -> hosted dispatcher: feature/config/actor/allowlist/metadata validation
  -> hosted dispatcher: trusted PR start marker (dedupe + bounded reservation)
  -> workflow_dispatch accepted by GitHub; hosted job exits without polling
  -> self-hosted executor: authorize target before credential creation
  -> self-hosted executor: re-fetch review and revalidate reservation/head/SHA
  -> target checkout with persist-credentials:false + double identity guard
  -> resume-review-branch.sh (exact existing branch only)
  -> build-review-prompt.sh (review body delimited as untrusted data)
  -> OpenCode / tests / git diff --check
  -> commit-review-repair.sh (same branch push only; no PR create/merge path)
  -> target PR + source Issue feedback and executor timings
```

Cross-repo reviews are polled by the central default-branch workflow because a
`pull_request_review` event is delivered only to workflows in the repository
that owns the PR. Polling preserves the no-target-workflow architecture and
still uses one target-scoped, short-lived App token per matrix job. One eligible
review is dispatched per target per poll. The poller and dispatcher never wait
for an executor run or an agent process. Its cross-repo App token has contents
read and pull-request write only; contents write is requested only by the
self-hosted executor after it repeats target authorization.

The executor `runs-on` value is exactly
`fromJSON(vars.REVIEW_REPAIR_RUNNER_LABELS)`. The validated JSON label array
must contain `self-hosted` and `review-repair`; missing or malformed
configuration stops dispatch. There is intentionally no hosted fallback.

## Trigger / event

| trigger | 条件 | 備考 |
|---------|------|------|
| `issues: labeled` | label が `opencode-run` または `agent:ready` | Issue 作成だけでは実行しない（Phase 10） |
| `workflow_dispatch` | inputs: target_repository / task_id / title / prompt / runner_mode | 手動投入。runner_mode は既定 github |
| `pull_request_review: submitted` | same-repo + `CHANGES_REQUESTED` | review repair; feature-gated |
| `schedule` / review workflow dispatch | allowlisted cross-repo PR scan | review repair; feature-gated |

job レベルの `if` で label / event を限定。`codex-run` のような他 label では workflow は選択されない（過去の silent-skip を排除）。

## Permissions（最小限）

```yaml
permissions:
  contents: write        # branch push / commit
  issues: write          # Issue へのフィードバックコメント
  pull-requests: write   # PR 作成
```

## Secrets

`OPENROUTER_API_KEY`、`OPENAI_API_KEY`、`ANTHROPIC_API_KEY` は repo secrets として
必要な場合だけ登録する。agent step には選択された一つだけを
`AGENT_CREDENTIAL_VALUE` として渡し、`run-agent.sh` が対応する CLI variable に
変換する。値はログ・summary・prompt・artifactへ出力しない。

### Workflow-file publication credential boundary

GitHub rejects a contents-write `GITHUB_TOKEN` or GitHub App installation token
when it tries to create or update `.github/workflows/**` without the App's
separate **Workflows: write** repository permission. This is why a normal Agent
Dispatch push cannot publish a workflow edit in the current configuration.

For the isolated self-hosted same-repository path, the trusted outer executor
uses `classify-workflow-push.sh` *after* the agent and its tests finish. It
rechecks target/remote identity, `agent/<task_id>` branch, expected base branch,
and every repository-relative diff path. It selects the push credential solely
from the actual Git diff:

| dispatch case | publication behavior |
|---|---|
| same repository, no `.github/workflows/**` diff | existing normal dispatch credential |
| same repository, workflow diff | a short-lived GitHub App installation token with Contents, Pull requests, and Workflows all set to write |
| cross repository, no workflow diff | existing target-scoped App token |
| cross repository, workflow diff | rejected as `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED` |

The late workflow token is requested by `actions/create-github-app-token` only
when the validated same-repository diff requires it. It exists only in the
trusted commit/push step, temporarily replaces the checkout's Git HTTP header
for `git push`, and is removed immediately afterwards. It is never passed to
OpenCode, repository tests in the isolated container, Docker environment or
mounts, task JSON, prompt text, artifacts, logs, or step summaries.

The existing App must be installed on `sironekotoro/github-actions-test` with
**Contents: write**, **Pull requests: write**, and **Workflows: write**. The
workflow deliberately does not change App permissions itself. Until an operator
grants that permission, a workflow diff fails before push with
`WORKFLOW_PUSH_AUTH_NOT_CONFIGURED` and explains that agent execution succeeded
but trusted workflow publication is not configured. No broad classic PAT is
used, and the cross-repository App-token request remains unchanged (it does not
ask for Workflows permission).

`runner_mode=github` retains its normal same-repository and cross-repository
paths for ordinary files. Workflow-file publication is intentionally fail-closed
there because it lacks the isolated trusted outer-wrapper boundary; use explicit
`runner_mode=self-hosted` for the supported self-modification path.

## Repository identity guard（中核）

`scripts/guard-repo.sh` が以下を canonical 形式（`owner/name`、小文字、`.git` 除去）で比較:

1. payload の `target_repository`
2. `GITHUB_REPOSITORY`（workflow が走っている repo）
3. checkout 済み `git remote get-url origin`

いずれかが不一致なら `REPOSITORY_IDENTITY_MISMATCH` を failure category に記録し **agent は起動しない**。
agent step は `steps.guard.outputs.result == 'pass'` のときのみ実行される。

## Prompt-side guard（自動挿入）

`scripts/build-agent-prompt.sh` が prompt 冒頭へ以下を自動挿入:

```
TARGET REPOSITORY:
sironekotoro/github-actions-test

You MUST verify before making any changes:
  pwd / git remote -v / git branch / git branch --show-current / git status

If the checked-out repository is NOT the TARGET REPOSITORY above,
STOP WITHOUT MAKING CHANGES and report REPOSITORY_IDENTITY_MISMATCH.

If an AGENTS.md file exists in this repository, read it first and follow it.
```

手入力に依存しない（Phase 4 / 19 / 20）。

Task/review text is delimited as untrusted data. The trusted prompt instructions
also require the agent to run `git status --short` and `git diff --check` before
reporting completion. Any whitespace error, including trailing whitespace
introduced by the task, must be fixed and checked again until
`git diff --check` exits successfully. The trusted outer executor independently
runs `git apply --check --whitespace=error` and rejects invalid returned patches;
it never sanitizes or rewrites them.

## Authorization

- Issue 経由: Issue author **と** label を付けた sender の両方が `ACTOR_ALLOWLIST`（既定 `sironekotoro`）に含まれること。
- dispatch 経由: `github.actor` が含まれること。
- 一致しない場合 `UNAUTHORIZED_ACTOR` で停止（Phase 30）。

## Injection safety

- Issue body / prompt を shell へ直接展開しない。
- `parse-task.mjs` が JSON を解析し `task.json` に保存。
- `run-agent.sh` は prompt をファイルから `PROMPT="$(<file)"` で読み、adapterへ**単一の quoted argument**として渡す。CLI invocationは上記matrixに固定する。
- prompt 本体はログに出力しない（bytes / sha256 / title のみ。Phase 18）。

## Duplicate guard

- `concurrency` group: `agent-dispatch-${{ issue.number || task_id }}`, `cancel-in-progress: false`
- `prepare-branch.sh`: 同名ブランチ `agent/<task_id>` が origin に存在、または open PR が存在すれば `TASK_ALREADY_RUNNING` で停止（Phase 11）。

Review repair never calls `prepare-branch.sh`. `resume-review-branch.sh` is a
separate narrow path that requires the exact existing `agent/<task_id>` PR head
branch and reviewed head SHA. Before invoking the agent, a bot-authored PR
comment records the immutable review ID and attempt number. Any trusted marker
for that review ID prevents re-delivery. Three distinct started markers exhaust
the default bound.

## Failure classification

| category | 発生時 |
|----------|--------|
| `INVALID_PAYLOAD` | JSON 解析不能 / 必須フィールド欠落 |
| `REPOSITORY_IDENTITY_MISMATCH` | target と actual/remote の不一致 |
| `UNAUTHORIZED_ACTOR` | actor が allowlist 外 |
| `TASK_ALREADY_RUNNING` | duplicate（ブランチ/PR 存在） |
| `DIRTY_WORKING_TREE` | agent 開始時に作業ツリーが汚れている |
| `CHECKOUT_FAILED` | branch 作成 / checkout 失敗 |
| `AGENT_START_FAILED` | opencode 未導入・起動失敗 |
| `AGENT_PATCH_INVALID` | agent 完了後に返された patch が trusted validation/import を通過しない |
| `MODEL_API_FAILED` | opencode が非ゼロ終了（transient retry 消化後） |
| `AGENT_TIMEOUT` | timeout 強制終了（exit 124） |
| `TEST_FAILED` | npm test / diff --check 失敗 |
| `PUSH_FAILED` / `PR_CREATE_FAILED` | push / PR 作成失敗 |
| `WORKFLOW_PUSH_AUTH_NOT_CONFIGURED` | agent succeeded, but same-repo workflow publication lacks the required trusted App permission/token |
| `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED` | cross-repo diff changes `.github/workflows/**`; this capability is intentionally not enabled |
| `REPAIR_METADATA_INVALID` | PR marker/task/review metadata malformed or outside input bounds |
| `REPAIR_PR_IDENTITY_MISMATCH` | PR target/head/dispatcher/bot principal mismatch |
| `REPAIR_BRANCH_MISMATCH` | head/base/default branch or reviewed SHA mismatch |
| `REPAIR_LIMIT_REACHED` | configured per-PR repair attempt limit reached |
| `REPAIR_STATE_WRITE_FAILED` | review ID start/final marker could not be persisted |
| `REPAIR_EXECUTOR_UNAVAILABLE` | self-hosted executor labels missing or unsafe |
| `REPAIR_EXECUTOR_DISPATCH_FAILED` | GitHub did not accept executor workflow dispatch |
| `REPAIR_EXECUTOR_REQUEST_INVALID` | executor identifiers/ref/SHA failed input validation |

単一の `exit 1` ではなく、`$RUNNER_TEMP/failure_category` に category を書き、Issue コメント・summary で報告する（Phase 16）。

## Model configuration

- 既定: `openrouter/deepseek/deepseek-v4-flash`
- `OPENROUTER_MODEL`（workflow env / dispatch input `model`）で上書き可能。workflow の編集なしで変更できる（Phase 8）。
- 大規模な model routing は作らない。

## Runtime / cost guard

- Initial Issue dispatch remains unchanged: job `timeout-minutes: 30`、agent step
  は `AGENT_MAX_RUNTIME`（既定 10 分）を `timeout` で強制。
- Review hosted control-plane jobs are bounded to 3–5 minutes and only scan,
  validate, reserve, and submit `workflow_dispatch`.
- The review executor is self-hosted, bounded to 45 minutes, and retains the
  agent runtime limit. OpenCode auto-install is disabled there; the runner must
  be provisioned before enabling the feature.
- `AGENT_MAX_ATTEMPTS`（既定 2）。429 / rate limit / network 系の transient のみ bounded retry。logic failure は retry しない（Phase 34 / 35）。
- agent は 1 task = 1 fresh session（Phase 39）。

## Default branch

`master` 固定にしない。`scripts/lib/repo.sh::detect_default_branch` が origin/HEAD → GitHub API → プローブ（master/main）の順に検出。zengin-pl 等の `master` repo でも動作（Phase 14 / Test 5-6）。

## Root cause of the old `No jobs were run`

過去構成では `codex-issue-worker.yml`（`if: label == 'codex-run'`）と `opencode-hosted-poc.yml`（`if: label == 'opencode-run'`）が **同じ `issues: labeled` イベント** を購読していた。`opencode-run` label で起動すると Codex worker は job レベルの `if` で **silent-skip** され、成果物の無い「skipped」run（= 実質 `No jobs were run`）が残った。

対策:
- 旧 2 workflow を削除し `agent-dispatch.yml` へ一本化。
- label 条件を job レベルで明示し、不適合 label では workflow 自体が選択されない。
- 失敗時は必ず failure category を出す。

## Remaining risks

- API-backed agent は provider API に依存。モデル停止・API非ゼロ終了時は `MODEL_API_FAILED`、timeout時は `AGENT_TIMEOUT` になる。
- GitHub-hosted runner の IP は可変（repo が public の場合、他者の workflow 利用は actor allowlist で防ぐ）。
- Cross-repo review detection is polling, so repair start can lag by up to the
  schedule interval. It never broadens the App token to multiple target repos.
- A dispatched executor workflow can remain queued if no matching self-hosted
  runner is online. The hosted dispatcher has already exited; operators must
  monitor the executor run and runner fleet separately.
- PR state markers are auditable GitHub-native comments. A maintainer who can
  delete those comments can alter attempt accounting; branch concurrency and
  commit trailers still prevent simultaneous mutation and duplicate successful
  pushes.
