# Cross-repository agent dispatch

## Status

Cross-repository dispatch is implemented behind `CROSS_REPO_ENABLED` and uses a target-scoped GitHub App installation token. Same-repository dispatch remains available without the App.

Live cross-repo execution is intentionally fail-closed until the App is configured.

> **Privacy boundary:** `sironekotoro/github-actions-test` is a public dispatcher. Workflow inputs, run metadata, step summaries, branch names, and PR links can be publicly visible. Therefore this repository's committed allowlist contains **public targets only**. Do not dispatch tasks to private repositories from this public control plane. If private targets are needed, move/duplicate the dispatcher into a private repository first.

## Architecture

```text
Issue / workflow_dispatch
  -> authorize actor
  -> parse immutable task metadata
  -> verify dispatcher checkout identity
  -> authorize target against config/allowed-repositories.txt
  -> same repo: existing GITHUB_TOKEN path
  -> cross repo:
       GitHub App credential preflight
       -> target-scoped installation token
       -> checkout target into ./target
       -> verify target checkout remote == task target
       -> dry-run OR prepare agent branch
       -> fresh OpenCode session in target cwd
       -> tests / commit / push / target PR
  -> feedback to the originating central issue
```

The prompt is never trusted to select a repository. `target_repository` from the parsed task plus the allowlist is the source of truth.

## Authentication decision

### A. GitHub App installation token — chosen

Advantages:

- short-lived installation token
- can be scoped to one repository at token creation time
- permissions can be constrained to Contents and Pull requests
- not tied to a long-lived personal credential
- no target-side workflow copy is required

### B. Fine-grained PAT

Technically workable but rejected as the primary path because it is long-lived/personal, needs rotation, and increases blast radius relative to a short-lived App token.

### C. `repository_dispatch` + target-side workflow

Good repository-boundary properties, but every target repo needs a maintained workflow and dispatch credential. Rejected for now because the central-runner design can operate without target-side setup.

### D. Cross-repo reusable workflow

Useful for shared workflow logic but does not by itself solve the write-credential boundary for arbitrary target repos. It therefore does not replace the App token requirement.

## Required GitHub App permissions

Install the App only on repositories that should accept agent writes.

Repository permissions:

- **Contents: Read and write** — clone/push agent branch
- **Pull requests: Read and write** — create/check PRs
- **Metadata: Read** — implicit GitHub repository metadata access

Not required: Administration, Actions write, Secrets, Members.

The workflow requests only `contents: write` and `pull-requests: write` on the generated installation token.

## Five-minute operator setup

1. GitHub -> Settings -> Developer settings -> GitHub Apps -> **New GitHub App**.
2. Give the App a private name such as `sironekotoro-agent-dispatch`.
3. Set repository permissions: **Contents: Read and write**, **Pull requests: Read and write**; leave unrelated permissions disabled.
4. Install the App on **Only select repositories**, selecting only approved **public** agent targets for this dispatcher.
5. Generate one private key for the App.
6. In `sironekotoro/github-actions-test` -> Settings -> Secrets and variables -> Actions:
   - repository secret `GH_APP_ID` = App ID
   - repository secret `GH_APP_PRIVATE_KEY` = private key contents
   - keep existing `OPENROUTER_API_KEY`
7. Under Actions variables, set `CROSS_REPO_ENABLED=true`.
8. Run a `workflow_dispatch` with an approved target and `dry_run=true` first.
9. After dry-run passes, run a harmless docs-only task. Do **not** merge the generated E2E PR.

Never paste App credentials into an Issue or task prompt.

## Allowlist

`config/allowed-repositories.txt` is authoritative for this public dispatcher. Entries are canonical `owner/name` values. A task targeting anything else fails with `TARGET_REPOSITORY_NOT_ALLOWED` before a target credential is used.

Current committed targets are deliberately public:

- `sironekotoro/github-actions-test`
- `sironekotoro/zengin-pl`
- `sironekotoro/sironekotoro-blog`

Installing the App is a second independent gate.

### Private targets

Private repository names and task metadata should not be sent through a public dispatcher because Actions run metadata and logs can reveal them. To support private repositories safely, first create a private central dispatcher (or make this dispatcher private), then maintain a private allowlist there and install the same narrowly scoped App only on the required private targets.

## Dry run

Set `dry_run: true` in the task payload or the workflow dispatch input. Dry run performs:

- actor authorization
- target allowlist authorization
- dispatcher identity guard
- App auth/token generation for cross-repo targets
- target checkout
- target identity guard
- default-branch detection
- final prompt construction

It does **not** run OpenCode, create a branch, commit, push, or create a PR.

## Failure categories

Cross-repo specific categories:

- `TARGET_REPOSITORY_NOT_ALLOWED`
- `CROSS_REPO_AUTH_UNAVAILABLE`
- `APP_INSTALLATION_NOT_FOUND`
- `APP_TOKEN_FAILED`
- `TARGET_CHECKOUT_FAILED`
- `TARGET_PERMISSION_DENIED`
- `TARGET_DEFAULT_BRANCH_NOT_FOUND`
- `REPOSITORY_IDENTITY_MISMATCH`
- `TASK_ALREADY_RUNNING`
- `TARGET_PUSH_FAILED`
- `TARGET_PR_CREATE_FAILED`

`CROSS_REPO_AUTH_UNAVAILABLE` plus `LIVE_CROSS_REPO_E2E_BLOCKED_BY_APP_SETUP` means the code path is ready but the GitHub App has not been configured.

## E2E acceptance sequence

1. **Unknown repo:** target an allowlist-excluded repo -> agent must not start.
2. **Wrong checkout:** unit/negative test must produce `REPOSITORY_IDENTITY_MISMATCH` -> agent must not start.
3. **Dry run:** approved target -> auth, checkout, identity, default branch, prompt build only.
4. **Positive public target:** `sironekotoro/zengin-pl`, docs-only file, generated PR left unmerged.
5. **Second default-branch shape:** `sironekotoro/sironekotoro-blog` (`main`), docs-only file, generated PR left unmerged if needed.

## Rollback

Set `CROSS_REPO_ENABLED=false` (or remove the variable). Same-repo dispatch continues to use the existing `GITHUB_TOKEN` path. No target-side workflows need to be removed.
