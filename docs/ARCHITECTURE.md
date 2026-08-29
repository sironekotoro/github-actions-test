# Architecture

## Security invariant

Non-dry-run coding-agent execution is allowed only in the isolated self-hosted Docker path.
GitHub-hosted execution is control-plane / dry-run only and never invokes OpenCode, Codex,
or Claude Code against a writable repository checkout.

Agent-generated `.github/workflows/**` changes are never published automatically. This is
true for same-repository and cross-repository dispatch. There is no workflow-write token
escalation path in Agent Dispatch.

## Initial dispatch flow

```text
ChatGPT / user
  ↓ Issue + label (opencode-run / agent:ready) or workflow_dispatch
Agent Dispatch route job (GitHub-hosted control plane)
  ↓ authorize runner mode from normalized task
  ├─ runner_mode=github + dry_run=true
  │    → auth / checkout / identity / default-branch / prompt inspection only
  │    → no branch, no agent, no commit, no push, no PR
  │
  └─ runner_mode=self-hosted (default)
       → dedicated self-hosted Mac runner
       → authorize actor
       → authorize target against committed allowlist
       → checkout target separately from dispatcher control code
       → prepare agent/<task_id>
       → build trusted pinned agent + egress images
       → stage target as .git-free /baseline and /workspace
       → isolated coding agent + repository tests
       → filesystem-only patch creation
       → trusted patch validation/import
       → publication-policy validation
       → trusted commit / push / PR
       → feedback
```

`runner_mode` accepts only `self-hosted` and `github`.

- omitted value → `self-hosted`
- `self-hosted` → normal execution or dry-run
- `github` → accepted only with `dry_run=true`
- `github` + non-dry-run → `INVALID_PAYLOAD`

The composite action also independently rejects an execution mode other than
`self-hosted`. This prevents a future caller from bypassing the route-level policy.

## Trusted control code vs target code

On the self-hosted path the dispatcher repository checkout remains the source of trusted
control scripts. The same-repository target is checked out separately under `target/`,
just like a cross-repository target. The agent never runs against the dispatcher checkout
that supplies trusted scripts.

The outer executor verifies target identity before staging source for the agent. The
agent receives only:

- writable `/workspace`: `.git`-free target source copy
- read-only `/baseline`: immutable `.git`-free source copy
- read-only generated prompt
- one selected provider credential
- restricted provider egress

The agent does **not** receive:

- target `.git`
- dispatcher `.git`
- GitHub / GitHub App mutation credentials
- host HOME / SSH / Keychain state
- Docker socket
- unrelated provider credentials

The container is non-root, has a read-only root filesystem, drops all capabilities, uses
`no-new-privileges`, and has pids / memory limits. The only writable source mount is
`/workspace`.

## Agent and credential matrix

`agent` and `runner_mode` are independent task fields, but agent execution is possible
only under self-hosted isolation.

| agent | profile | exact invocation | repository secret | runtime credential |
|---|---|---|---|---|
| `opencode` | `openrouter` | `opencode run --print-logs -m "$model" "$prompt"` | `OPENROUTER_API_KEY` | `OPENROUTER_API_KEY` |
| `codex` | `openai-api` | `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$prompt"` | `OPENAI_API_KEY` | `CODEX_API_KEY` |
| `claude-code` | `anthropic-api` | `claude -p "$prompt"` | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` |

The workflow resolves only the selected secret into `AGENT_CREDENTIAL_VALUE`.
`run-agent.sh` and the adapter then use `env -i` so unrelated secrets and arbitrary
runner environment variables are not inherited by the CLI.

For pinned Codex 0.147.0, the external source contract remains `OPENAI_API_KEY`, while
the adapter translates it only at the Codex child-process boundary to `CODEX_API_KEY`
for ephemeral headless API authentication.

Subscription profiles (`chatgpt-subscription`, `claude-subscription`) remain represented
for future work but fail closed with `AGENT_AUTH_FAILED`. There is no host-auth fallback.

The trusted image pins:

- `opencode-ai@1.18.16`
- `@openai/codex@0.147.0`
- `@anthropic-ai/claude-code@2.1.165`

The egress proxy permits HTTPS CONNECT only to the provider API domains required by this
matrix.

## Patch boundary

Agent completion does not make its working tree trusted. The outer executor computes a
filesystem-only binary patch from `base` to `workspace` and calls the shared
`apply_agent_patch` helper.

Immediately before patch construction, the trusted wrapper scans every filename,
regular file, and symlink target string in the final isolated workspace for the exact
bytes of the selected provider credential. It does not follow symlinks and fails closed as
`AGENT_CREDENTIAL_LEAK_BLOCKED` on a match or scanner error. Agent failure-log tails use
the same exact-literal policy and replace the selected credential with a fixed marker.
This blocks raw credential persistence and publication; it is not complete containment,
because the agent process still receives the key. A local authentication broker/relay
that keeps provider credentials outside the agent process is the long-term fix.

The helper enforces:

1. diff producer status must be 0 or 1
2. no-change and empty-patch cases are classified explicitly
3. baseline `git apply --check -p2`
4. strict `git apply --check --whitespace=error -p2`
5. final `git apply --whitespace=error -p2`
6. `git apply` stderr is not exposed

Durable patch reasons are:

- `NO_CHANGES`
- `EMPTY_PATCH`
- `PATCH_PARSE_FAILED`
- `PATCH_VALIDATION_FAILED`

Repository tests run inside the same isolated container after provider credentials are
unset. The trusted outer commit stage does not re-execute target tests.

## Workflow-file publication policy

Agent-generated `.github/workflows/**` files are prohibited from automatic publication.
This policy is enforced twice:

1. `classify-workflow-push.sh` after patch import and identity/branch validation
2. `commit-push-pr.sh` immediately before staging/commit as defense in depth

Results:

| case | result |
|---|---|
| same repo, ordinary diff | normal trusted commit/push/PR |
| cross repo, ordinary diff | target-scoped App token commit/push/PR |
| same repo, `.github/workflows/**` diff | `WORKFLOW_PUSH_AUTH_NOT_CONFIGURED` fail-closed |
| cross repo, `.github/workflows/**` diff | `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED` fail-closed |

The legacy automatic workflow-write App-token route has been removed. Agent Dispatch no
longer requests `permission-workflows: write`, and there is no `WORKFLOW_PUSH_MODE`
selection. A workflow change must be reviewed and published outside the automated agent
PR path by a human or separate trusted process.

## Trusted commit boundary

Only the outer executor can commit or push. Before commit it rechecks the actual diff and
publication policy. Repository-controlled Git hooks are disabled with
`core.hooksPath=/dev/null` in the trusted commit stage.

The initial agent commit includes immutable metadata trailers and the PR body contains a
base64 task metadata marker. Review Repair later requires the PR author, metadata hash,
target repository, branch, and commit history to agree.

## Review Repair flow

Review Repair remains separate from initial dispatch.

```text
same-repo pull_request_review:submitted
  OR scheduled cross-repo scan
  → GitHub-hosted dispatcher validates feature/config/actor/allowlist/metadata
  → reserve review ID + attempt using trusted bot marker
  → dispatch self-hosted executor and exit
  → executor re-checks kill switch authoritatively
  → authorize target before write credential creation
  → re-fetch PR/review and validate reservation/head SHA
  → checkout exact validated head with persist-credentials:false
  → resume exact existing agent/<task_id> branch
  → isolated .git-free OpenCode repair + tests
  → trusted patch validation/import
  → trusted same-branch non-force push
  → completed/failed marker + timing feedback
```

Review Repair never calls the initial `prepare-branch.sh` duplicate path and never creates
or merges another PR.

### Review Repair invariants

- only `CHANGES_REQUESTED`
- authorized reviewer required
- same PR/base/head repository identity required
- bot-authored Agent Dispatch PR required
- immutable task metadata marker required
- exact `agent/<task_id>` head branch required
- review must target the current head SHA
- exact branch SHA is rechecked before resume and before push
- duplicate review IDs are ignored/rejected
- attempts are bounded by `REVIEW_REPAIR_MAX` (default 3)
- no force push
- no auto-merge
- repository tests and hooks never receive the push credential

## Authorization

### Actor authorization

Issue dispatch requires both the issue author and labeler to be on the actor allowlist.
Manual workflow dispatch requires `github.actor` to be allowed.

### Target authorization

`config/allowed-repositories.txt` is the committed target allowlist. Target identity is
canonicalized to lowercase `owner/name` and checked before cross-repository credential
creation or checkout.

Public dispatcher policy: do not add private target names to the public allowlist.

### Cross-repository credential

Cross-repository normal dispatch uses a short-lived GitHub App installation token scoped
to the one authorized target repository with Contents and Pull requests permissions.
Workflow-file changes remain prohibited; the token request does not ask for Workflows
permission.

## Prompt boundary

Task and review bodies are delimited as untrusted data and cannot override authoritative
instructions.

For isolated initial dispatch, the prompt states that the outer executor already verified
repository identity and that `.git` is intentionally absent. It uses `/baseline` vs
`/workspace` for final whitespace validation instead of repository Git metadata.

For GitHub-hosted dry-run inspection only, the legacy repository Git checks may still be
used because no coding agent is invoked and no mutation follows.

## Duplicate and race protection

Initial dispatch:

- workflow concurrency group
- remote `agent/<task_id>` existence check
- open PR check

Review Repair:

- per-PR dispatcher/executor concurrency groups
- trusted reservation markers
- reviewed head SHA revalidation
- remote SHA recheck immediately before repair commit/push
- commit-history repair marker consistency checks

## Failure classification

Important categories include:

| category | meaning |
|---|---|
| `INVALID_PAYLOAD` | malformed task / unsupported live GitHub-hosted mode |
| `REPOSITORY_IDENTITY_MISMATCH` | expected target/remote/dispatcher mismatch |
| `UNAUTHORIZED_ACTOR` | actor/reviewer not allowlisted |
| `TASK_ALREADY_RUNNING` | duplicate branch/open PR |
| `DIRTY_WORKING_TREE` | unexpected dirty checkout |
| `AGENT_EXECUTOR_UNAVAILABLE` | required isolated executor configuration unavailable |
| `AGENT_CREDENTIAL_LEAK_BLOCKED` | exact selected credential found in final workspace, or scan failed |
| `AGENT_UNKNOWN` | unsupported agent |
| `AGENT_AUTH_FAILED` | selected credential invalid/missing/unsupported |
| `AGENT_UNAVAILABLE` | selected CLI unavailable |
| `AGENT_TIMEOUT` | bounded agent runtime exceeded |
| `MODEL_API_FAILED` | non-auth provider/agent failure after retry policy |
| `AGENT_PATCH_INVALID` | filesystem patch failed trusted validation/import |
| `TEST_FAILED` | repository or diff validation failed |
| `WORKFLOW_PUSH_AUTH_NOT_CONFIGURED` | same-repo agent workflow-file publication blocked |
| `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED` | cross-repo agent workflow-file publication blocked |
| `PUSH_FAILED` / `TARGET_PUSH_FAILED` | trusted push failed |
| `PR_CREATE_FAILED` / `TARGET_PR_CREATE_FAILED` | trusted PR creation failed |
| `REPAIR_*` | review-repair metadata/identity/branch/state/dispatch failures |

## Operator controls

- `CROSS_REPO_ENABLED=true|false`
- `REVIEW_REPAIR_ENABLED=true|false`
- `REVIEW_REPAIR_MAX=1..10`
- `REVIEW_REPAIR_MODEL=...`
- `REVIEW_REPAIR_RUNNER_LABELS=["self-hosted","review-repair",...]`

The self-hosted label set is validated before agent execution. There is no GitHub-hosted
fallback for coding-agent work.
