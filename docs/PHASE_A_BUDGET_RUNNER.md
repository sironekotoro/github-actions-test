# Phase A: Provider budget gate, billing alerts, and runner routing

Phase A adds a trusted control-plane preflight before paid agent inference. It does not weaken the isolated agent boundary and it does not re-enable GitHub-hosted live coding agents.

## Rollout defaults

Both gates are opt-in so merging the code does not strand existing jobs before the new control-plane credentials are configured:

- `PROVIDER_BUDGET_GATE_ENABLED=false`
- `RUNNER_ROUTER_ENABLED=false`

Enable each variable only after its required secret/configuration is present.

## Budget policy

Defaults:

- `PROVIDER_BALANCE_WARN_USD=0.50`
- `PROVIDER_BALANCE_HARD_FLOOR_USD=0.25`
- `PROVIDER_JOB_MAX_USD=0.25`

`PROVIDER_BALANCE_HARD_FLOOR_USD` is the protected amount that a paid job must leave untouched. In Phase A, `PROVIDER_JOB_MAX_USD` also acts as a required per-job reserve because the preflight cannot yet enforce an in-flight provider spend cap. A paid task starts only when the observable available amount is at least `hard_floor + job_reserve`. With the defaults, paid inference therefore does not start below `$0.50`, preserving the requested `$0.25` floor plus a `$0.25` job reserve.

`job_spendable_usd = max(0, available - hard_floor)`. The reported per-job cap is bounded by both `PROVIDER_JOB_MAX_USD` and spendable funds. Phase B broker enforcement will make that cap authoritative during inference; until then, Phase A uses the same configured value conservatively as a start-time reserve.

Budget state also fails closed when it cannot be established safely. `warning` does not block when the full reserve is still available; `blocked` and `unknown` never start paid inference.

### OpenRouter

Required secrets when the budget gate is enabled for OpenCode:

- `OPENROUTER_API_KEY` (existing inference key)
- `OPENROUTER_MANAGEMENT_KEY` (management-only key for the credits endpoint)

The preflight uses the official account credits endpoint plus current-key `limit_remaining`, and takes the most conservative available value. No completion/model request is made.

### OpenAI / Codex API

Required:

- secret `OPENAI_ADMIN_KEY`
- variable `OPENAI_MONTHLY_BUDGET_USD`

OpenAI does not expose an exact prepaid-credit balance endpoint used by this implementation. The gate therefore uses the official organization Costs API and computes `configured monthly budget - current UTC-month reconciled costs`. Missing/invalid admin access or budget is `PROVIDER_BUDGET_UNKNOWN` and fails closed when the gate is enabled.

### Anthropic / Claude Code

Phase A intentionally returns `PROVIDER_BUDGET_UNKNOWN` for paid Anthropic API execution because no exact cash-balance source is relied upon yet. When the budget gate is enabled, Claude Code API tasks are deferred rather than guessed. This can be extended with a reviewed budget-envelope adapter later.

## Billing email

Budget states are deduplicated with one open dispatcher-repository issue per provider/state. A transition to a new state closes the previous alert. Recovery closes outstanding alerts. Therefore workflow retries do not send a new email every time.

Variables:

- `BILLING_EMAIL_ENABLED=true`
- `BILLING_ALERT_EMAIL_TO`
- `BILLING_SMTP_HOST`
- `BILLING_SMTP_PORT` (default 587)
- `BILLING_SMTP_FROM`
- `BILLING_SMTP_STARTTLS` (default true)
- `BILLING_SMTP_SSL` (default false)
- optional `BILLING_ALERT_RECOVERY_EMAIL=true`

Secrets:

- `BILLING_SMTP_USER`
- `BILLING_SMTP_PASSWORD`

The mail contains provider/state/observed amount/protected floor/required job reserve/task/run/alert URL only. It never includes an API key, authorization header, prompt, patch, or model response. Email failure is recorded as `BILLING_ALERT_FAILED` on the GitHub billing alert; already-blocked inference stays blocked.

## Runner router

Set `RUNNER_ROUTER_ENABLED=true` only after configuring secret `RUNNER_STATUS_TOKEN`. The token should be a dedicated fine-grained credential with repository **Administration: read** only, sufficient for `GET /repos/{owner}/{repo}/actions/runners`.

The router matches the existing `REVIEW_REPAIR_RUNNER_LABELS` set:

- compatible online + idle: run immediately;
- compatible online + busy: create the self-hosted job and let GitHub queue it rather than paying for fallback;
- no compatible online runner: defer with `RUNNER_UNAVAILABLE`;
- missing token/API failure/invalid status: defer with `RUNNER_STATUS_UNKNOWN`.

Additional self-hosted PCs can be added later by registering the same capability labels. No workflow redesign is required for machines that satisfy the same isolation contract.

## Ordinary Agent Dispatch waiting semantics

When live execution is deferred, no coding agent starts and no paid inference occurs. For issue-triggered tasks the workflow removes the ready label, adds `agent:waiting-budget` or `agent:waiting-runner`, and posts a resume instruction. After correcting the condition, add `agent:ready` again. A later successful run removes waiting labels.

## Review Repair waiting semantics

Review Repair checks runner and OpenRouter budget before reserving an attempt. A deferred repair consumes **no repair attempt**. Scheduled cross-repo polling naturally retries on the next scan after conditions recover.

## Security boundary

Management/admin billing credentials, runner-status credentials, and SMTP credentials exist only in trusted GitHub-hosted control-plane steps. They are never passed to the coding-agent composite/container or repository-test container. Existing `.git` isolation, frozen-patch-before-tests, workflow-publication fail-close, and no-auto-merge invariants remain unchanged.
