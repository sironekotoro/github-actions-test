# Bounded automatic review repair

## Scope and default state

The review loop updates an existing dispatcher-created PR after an authorized
`CHANGES_REQUESTED` review. It is disabled by default:

```text
REVIEW_REPAIR_ENABLED=false
REVIEW_REPAIR_MAX=3
```

`APPROVED`, `COMMENTED`, arbitrary PR/Issue comments, forks, user-created PRs,
stale reviews, and reviews by actors outside `ACTOR_ALLOWLIST` never start the
agent. The workflow does not auto-merge.

## Event architecture

- Same repository: GitHub's `pull_request_review: submitted` event provides an
  immediate signal.
- Cross repository: the central workflow polls public allowlisted targets every
  ten minutes. GitHub sends review events only to the PR-owning repository, so
  this preserves the existing design in which target repositories do not need
  a dispatcher workflow. Each matrix job obtains an installation token scoped
  to exactly one target repository.

Both signals enter a short GitHub-hosted dispatcher. It checks the feature and
executor configuration, authorizes the review/target, validates provenance,
reserves the review ID and bounded attempt, submits one `workflow_dispatch`
request, and exits as soon as GitHub accepts it. It does not sleep, poll the run,
wait for an agent, checkout a target working tree, or run repair commands.

The separate executor workflow uses only
`fromJSON(vars.REVIEW_REPAIR_RUNNER_LABELS)`. The JSON array must include both
`self-hosted` and `review-repair`, for example:

```text
REVIEW_REPAIR_RUNNER_LABELS=["self-hosted","review-repair","macOS","ARM64"]
```

Missing/invalid labels fail closed. There is no `ubuntu-latest` fallback. The
feature flag is checked in workflow selection and in the parser. The executor
also reads the current repository Actions variable through the GitHub API as its
first step. A queued/manual executor therefore fails closed before checkout,
credential creation, agent execution, or target writes if an administrator has
turned the flag off. This read uses the dedicated
`REVIEW_REPAIR_VARIABLES_TOKEN` secret: a dispatcher-repository fine-grained
PAT with **Variables: read** repository permission (and GitHub's mandatory
Metadata: read). It is never passed to the agent or target checkout, and a
missing/invalid token fails closed. The executor workflow must exist on the
dispatcher's default branch before GitHub accepts a manual dispatch, so live
validation is possible only after this workflow is merged.

## Agent PR provenance

Initial dispatch writes a compact base64 task metadata marker into the bot-owned
PR body and writes its SHA-256 digest into the initial commit trailer. Repair
validation requires all of the following:

Base64 is transport encoding, not encryption. The marker contains the original
task context, so this public dispatcher continues to permit public targets only.

1. open, non-draft PR authored by the recorded dispatcher/App bot principal;
2. target repository is in the committed allowlist;
3. PR base and head repositories equal the target (no forks);
4. head branch is exactly `agent/<immutable task_id>`;
5. base branch equals the target default branch;
6. review commit ID equals the current PR head SHA;
7. metadata digest exists in the agent branch history;
8. reviewer and direct event actor are authorized.

Any mismatch fails closed before the coding agent starts.

## Deduplication and attempt semantics

Before the agent receives review text, the workflow posts a bot-authored hidden
`started` marker containing the GitHub-native review ID and attempt number. A
trusted marker for the same review ID makes all later deliveries no-ops, even if
the prior run failed. This guarantees that the same review is never passed to
the agent twice.

The attempt count is the number of distinct bot-authored `started` markers on
that PR. At the configured maximum (default 3), the workflow posts a clear
`limit` status and starts no agent. A new review ID is required for each new
automatic pass.

Repository/PR concurrency serializes same-repo reviews; cross-repo matrix jobs
serialize dispatch for a target repository. Executor concurrency serializes each
target repository/PR. On start, the executor re-fetches authoritative GitHub
state, re-authorizes its workflow actor, and requires the exact review ID, PR
number, current reviewed head SHA, attempt number, and trusted reservation
marker supplied by the dispatcher. A trusted `executor-started` marker is a
claim: later workflow deliveries for that review become no-ops.
Before pushing, the script checks the remote branch SHA again and uses a normal
non-force push.

## Untrusted review text

The original task context and review body are printed only into a prompt file,
inside explicit untrusted delimiters. Authoritative repository, branch,
credential, no-PR, no-push-by-agent, and no-merge rules precede those delimiters.
The prompt is passed to OpenCode as one quoted argument and is not logged.

Review requests to change repositories, alter allowlists/guards, reveal secrets,
create another PR, push, merge, or override system instructions are ignored.

## Writes and feedback

The repair agent must run `git status --short` and `git diff --check` before it
reports completion, fixing whitespace errors and rerunning the check until it
passes. The trusted outer executor independently validates the returned patch.
The repair commit path runs repository tests when `package.json` is present,
runs `git diff --check`, commits only actual changes, and pushes only
`HEAD:refs/heads/<validated existing branch>`. It contains no PR creation or
merge operation. No-change repairs are recorded by the PR completion marker.

Target PR feedback uses the target token. Source Issue feedback uses the central
`GITHUB_TOKEN`. Cross-repo target writes never use the central token.

Timeline fields record review detection, dispatch acceptance, executor start,
executor finish, attempt number, target/PR, outcome, executor run URL, and agent
runtime. Review text and credentials are not included in comments or summaries.

The self-hosted runner must have Docker available to its non-root runner user,
git, GitHub CLI, `jq`, and a GNU `timeout`-compatible command. The executor
builds trusted images from the dispatcher default-branch checkout, then runs
OpenCode and repository `npm test` in a disposable container. The agent sees
only a `.git`-free copy of the validated target worktree, an immutable prompt,
and `OPENROUTER_API_KEY`; the review-repair path remains OpenCode-only. It does
not receive the host HOME, SSH keys, gh/Codex/OpenCode/Claude configuration,
GitHub/App tokens, the Docker socket, or any other repository. The agent
container is non-root, has a read-only root, temporary HOME/tmp, all Linux
capabilities dropped, and no direct external route. A separate proxy is the
sole egress path and permits HTTPS CONNECT only to the provider API allowlist;
review repair has no OpenAI or Anthropic credential and cannot select those
adapters. The outer executor imports only a checked patch and does not run
target tests or hooks. The API key is unset before repository tests run, and
the container's prompt/log paths are temporary and not uploaded as artifacts.
Target checkout does not persist credentials,
and the target-scoped token is used only for authenticated validated remote
reads and the final non-force push.

## Disable / rollback

Set `REVIEW_REPAIR_ENABLED=false` or remove the variable. Scheduled scans and
same-repo review jobs stop, while normal dispatch and existing PRs remain
unchanged. No branch deletion, workflow removal, or target-side cleanup is
required.
