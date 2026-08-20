# Architecture

## Initial dispatch flow

```
ChatGPT / ユーザー
  ↓  Issue 作成 + label ("opencode-run" / "agent:ready")  or  workflow_dispatch inputs
GitHub Issue / dispatch
  ↓
agent-dispatch.yml (ubuntu-latest, GitHub-hosted)
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
run-agent.sh              opencode run (OpenRouter, bounded runtime, bounded retry)
  ↓
commit-push-pr.sh         npm test → commit → push → PR (metadata 付き)
  ↓
post-feedback.sh          Issue コメント + Step summary
```

## Review repair flow

`review-repair.yml` is deliberately separate from initial dispatch.

```text
same-repo pull_request_review:submitted
  OR scheduled cross-repo scan (one target-scoped App token per allowlisted repo)
  -> feature flag gate
  -> CHANGES_REQUESTED + authorized reviewer
  -> bot-authored dispatcher metadata marker
  -> target/head/base/branch/current head SHA validation
  -> metadata SHA-256 trailer validation against branch history
  -> trusted PR start marker for review-id deduplication/attempt count
  -> resume-review-branch.sh (existing branch only)
  -> build-review-prompt.sh (review body delimited as untrusted data)
  -> OpenCode / tests / git diff --check
  -> commit-review-repair.sh (same branch push only; no PR create/merge path)
  -> target PR + source Issue feedback
```

Cross-repo reviews are polled by the central default-branch workflow because a
`pull_request_review` event is delivered only to workflows in the repository
that owns the PR. Polling preserves the no-target-workflow architecture and
still uses one target-scoped, short-lived App token per matrix job. One eligible
review is handled per target per poll.

## Trigger / event

| trigger | 条件 | 備考 |
|---------|------|------|
| `issues: labeled` | label が `opencode-run` または `agent:ready` | Issue 作成だけでは実行しない（Phase 10） |
| `workflow_dispatch` | inputs: target_repository / task_id / title / prompt | 手動投入 |
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

`OPENROUTER_API_KEY` は repo secret（sironekotoro/github-actions-test）に登録。
`run-agent.sh` の環境変数としてのみ注入し、ログ・summary には出力しない（Phase 7 / 33）。

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

## Authorization

- Issue 経由: Issue author **と** label を付けた sender の両方が `ACTOR_ALLOWLIST`（既定 `sironekotoro`）に含まれること。
- dispatch 経由: `github.actor` が含まれること。
- 一致しない場合 `UNAUTHORIZED_ACTOR` で停止（Phase 30）。

## Injection safety

- Issue body / prompt を shell へ直接展開しない。
- `parse-task.mjs` が JSON を解析し `task.json` に保存。
- `run-agent.sh` は prompt をファイルから `PROMPT="$(<file)"` で読み、**単一の quoted argument** として `opencode run ... "$PROMPT"` に渡す（Phase 31 / 32）。
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
| `MODEL_API_FAILED` | opencode が非ゼロ終了（transient retry 消化後） |
| `AGENT_TIMEOUT` | timeout 強制終了（exit 124） |
| `TEST_FAILED` | npm test / diff --check 失敗 |
| `PUSH_FAILED` / `PR_CREATE_FAILED` | push / PR 作成失敗 |
| `REPAIR_METADATA_INVALID` | PR marker/task/review metadata malformed or outside input bounds |
| `REPAIR_PR_IDENTITY_MISMATCH` | PR target/head/dispatcher/bot principal mismatch |
| `REPAIR_BRANCH_MISMATCH` | head/base/default branch or reviewed SHA mismatch |
| `REPAIR_LIMIT_REACHED` | configured per-PR repair attempt limit reached |
| `REPAIR_STATE_WRITE_FAILED` | review ID start/final marker could not be persisted |

単一の `exit 1` ではなく、`$RUNNER_TEMP/failure_category` に category を書き、Issue コメント・summary で報告する（Phase 16）。

## Model configuration

- 既定: `openrouter/deepseek/deepseek-v4-flash`
- `OPENROUTER_MODEL`（workflow env / dispatch input `model`）で上書き可能。workflow の編集なしで変更できる（Phase 8）。
- 大規模な model routing は作らない。

## Runtime / cost guard

- job `timeout-minutes: 30`、agent step は `AGENT_MAX_RUNTIME`（既定 10 分）を `timeout` で強制。
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

- `opencode run` はモデル API に依存。モデル停止時は `MODEL_API_FAILED` になる。
- GitHub-hosted runner の IP は可変（repo が public の場合、他者の workflow 利用は actor allowlist で防ぐ）。
- Cross-repo review detection is polling, so repair start can lag by up to the
  schedule interval. It never broadens the App token to multiple target repos.
- PR state markers are auditable GitHub-native comments. A maintainer who can
  delete those comments can alter attempt accounting; branch concurrency and
  commit trailers still prevent simultaneous mutation and duplicate successful
  pushes.
