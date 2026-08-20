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

The feature flag is checked both in workflow selection and in the parser.

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
serialize all repairs for a target repository. Before pushing, the script checks
the remote branch SHA again and uses a normal non-force push.

## Untrusted review text

The original task context and review body are printed only into a prompt file,
inside explicit untrusted delimiters. Authoritative repository, branch,
credential, no-PR, no-push-by-agent, and no-merge rules precede those delimiters.
The prompt is passed to OpenCode as one quoted argument and is not logged.

Review requests to change repositories, alter allowlists/guards, reveal secrets,
create another PR, push, merge, or override system instructions are ignored.

## Writes and feedback

The repair commit path runs repository tests when `package.json` is present,
runs `git diff --check`, commits only actual changes, and pushes only
`HEAD:refs/heads/<validated existing branch>`. It contains no PR creation or
merge operation. No-change repairs are recorded by the PR completion marker.

Target PR feedback uses the target token. Source Issue feedback uses the central
`GITHUB_TOKEN`. Cross-repo target writes never use the central token.

## Disable / rollback

Set `REVIEW_REPAIR_ENABLED=false` or remove the variable. Scheduled scans and
same-repo review jobs stop, while normal dispatch and existing PRs remain
unchanged. No branch deletion, workflow removal, or target-side cleanup is
required.
