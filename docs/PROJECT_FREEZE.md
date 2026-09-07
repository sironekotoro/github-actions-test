# Project Freeze

## Status

**This project is indefinitely frozen as of 2026-09-08.**

The freeze point is `master` commit `92745245ee6c6318039d7ad21a9e2de66fcdcc65` (merge of PR #175, "Wire Anthropic broker into ordinary Agent Dispatch").

This is not an abandonment or a declaration of failure. The purpose is to preserve the value of the current implementation, stop adding maintenance surface, and keep the repository in a state that can be understood and resumed later if a clear need appears.

The project is frozen because an independently maintained AI-agent execution platform has become expensive to reason about and maintain, while platform capabilities such as ChatGPT Work, Codex, and comparable hosted agent products are evolving very quickly. At this point the project will not continue toward feature completeness merely for its own sake.

Development should be reconsidered only if a concrete requirement appears that cannot be satisfied reasonably by platform-provided capabilities and that clearly justifies owning this infrastructure.

## Freeze policy

While frozen:

- do not add new agent features, routing modes, providers, runners, or automation loops;
- do not merge old experimental branches merely to "finish" previously planned work;
- do not perform large refactors or cleanup-only rewrites;
- do not delete code or workflows simply because they appear unused;
- preserve the current trusted/untrusted boundaries and fail-closed behavior;
- treat existing roadmap issues as historical context or **resume candidates**, not active TODO items;
- make only narrowly scoped maintenance/security fixes when a real defect affects the preserved state.

The freeze does not require disabling currently configured workflows. Feature-gated/scheduled workflows may remain present so the architecture is preserved. If operational cost or noise later requires disabling a workflow, do that as a separate, explicit operational change rather than as part of feature development.

## Current implementation state

### Completed / substantially implemented

The following capabilities are present on `master` at the freeze point.

- **Central Agent Dispatch** from Issue / `workflow_dispatch`, with actor authorization, immutable task parsing, target allowlisting, repository identity checks, branch preparation, feedback, and normalized failure categories.
- **Self-hosted isolated execution** as the only non-dry-run coding path. The coding agent runs in a hardened disposable Docker container with a `.git`-free writable `/workspace` and read-only `/baseline`.
- **Trusted / untrusted separation**: GitHub mutation credentials, target `.git`, host HOME, SSH, Keychain state, Docker socket, and unrelated provider credentials are kept outside the agent container.
- **Same-repository and cross-repository dispatch plumbing**, including target-scoped short-lived GitHub App credentials for authorized cross-repository operations and explicit target identity checks.
- **Multi-agent abstraction** for `opencode`, `codex`, and `claude-code`, with explicit API credential profiles and fail-closed unsupported subscription profiles.
- **Bounded agent runtime / timeout handling**, retries, and normalized failure categories such as `AGENT_TIMEOUT`, `MODEL_API_FAILED`, `AGENT_AUTH_FAILED`, and `AGENT_PATCH_INVALID`.
- **Trusted patch boundary** using a shared `apply_agent_patch` path, explicit no-change/empty/parse/validation reasons, strict whitespace validation, and suppressed `git apply` diagnostics.
- **Credential leak guard** that scans the final workspace for the selected provider credential before patch publication.
- **Workflow publication fail-close**: agent-generated `.github/workflows/**` changes are not automatically published.
- **Review Repair** as a separate feature-gated flow. It resumes the same validated PR branch after an authorized `CHANGES_REQUESTED` review, revalidates metadata/head SHA, uses the isolated agent path, pushes only to the existing branch, bounds attempts, and never creates/merges a replacement PR.
- **Phase A budget / runner preflight components**, feature-gated for safe rollout.
- **Provider broker framework** that moves real provider credentials into a trusted broker and gives the agent only an opaque capability when broker mode is enabled. OpenRouter/OpenAI/Anthropic broker-related components exist on `master`.
- **Anthropic conservative spend-guard plumbing and trusted local-mock E2E support**. Ordinary Claude broker plumbing is merged, while production live Anthropic forwarding remains intentionally disabled.
- **Operational documentation and runbooks** for architecture, cross-repository dispatch, Review Repair, Phase A controls, immediate notifications, and incident handling.

### Verified paths at freeze time

Evidence available at the freeze point:

- Current `master` CI run #511 (`33808668049`) completed successfully on commit `92745245ee6c6318039d7ad21a9e2de66fcdcc65`.
- CI executed `bash tests/run-all.sh` and repository `npm test`; both CI steps completed successfully.
- PR #176 added trusted ordinary Claude broker E2E coverage against local mocks; PR #178 fixed its mock-network path and was merged before the freeze commit.
- The repository continues to show successful scheduled/control-plane workflow activity after the freeze commit, including the notification gateway and Review Repair dispatcher. This confirms the workflow files remain syntactically loadable/executable, but does not imply that every optional live provider path is production-approved.

The freeze work itself intentionally does not perform paid model/provider calls.

## Known constraints and unresolved items

These are **not active TODOs**. They are preserved as resume candidates or known limitations.

### Provider / model integration

- **Real Anthropic / Claude paid production forwarding is not enabled.** The production workflow pins `ANTHROPIC_BROKER_LIVE_ALLOWED=false`, and Phase A still treats paid Anthropic budget state as unknown/fail-closed. Issue #165 records the remaining B3c live-pilot design/approval boundary.
- `chatgpt-subscription` and `claude-subscription` profiles are represented but deliberately fail closed. There is no host-login fallback into the container.
- The broader Phase B parent (#121) remains open. Broker infrastructure is substantially implemented, but the project is not declaring every provider/profile combination fully production-validated.
- Automatic agent/model selection and broader broker/routing policy should be reconsidered only if a future requirement justifies them.

### Hosted / runner expansion

- **Phase C (#122)** safe GitHub-hosted live isolated fallback is not implemented. GitHub-hosted execution remains control-plane / dry-run only.
- **Phase D (#123)** additional self-hosted runner capacity and local-model fallback are not implemented as a completed product feature.
- Current self-hosted execution still depends operationally on the configured compatible runner and Docker environment.

### Repository / cross-repository operations

- `master` is **not branch-protected** at the freeze point (`protected=false`). Issue #106 records the desired PR + required-CI protection policy. This is an administrative hardening candidate, not an application feature.
- GitHub App installation / production E2E for `sironekotoro-blog` remains incomplete (#105).
- Historical E2E/task issues remain in the repository. They should be read as test records unless explicitly reopened as part of a future resume decision.

### Historical patch-diagnostics work

Older patch-diagnostics issues (#42 through #70 and related PR attempts) record a long sequence of experiments and regressions. Their intended production behavior is already represented in the current `master` architecture (`apply_agent_patch`, durable reasons, strict validation). Do not restart those historical issue chains merely because the issues remain open; first inspect the current implementation and CI state.

## Reusable components

The following pieces are likely to be useful independently even if this repository is never completed as a general AI-agent platform.

### Self-hosted runner pattern

- dedicated self-hosted execution labels;
- Docker-based disposable runtime;
- bounded runtime and cleanup;
- host credential material kept outside the untrusted process;
- clear separation between GitHub-hosted control plane and self-hosted executor.

### Agent Dispatch control plane

- Issue / manual-dispatch task ingestion;
- immutable task metadata;
- actor and target authorization;
- same-repo / cross-repo target handling;
- target-scoped GitHub App token use;
- structured failure categories and feedback.

### Trusted / untrusted execution boundary

- `.git`-free agent workspace;
- read-only baseline + writable workspace;
- no GitHub mutation token in the agent;
- no host HOME / SSH / Keychain / Docker socket;
- `env -i` clean child environment;
- selected credential only;
- trusted outer patch validation/import/commit/push/PR ownership.

### Review Repair

- `CHANGES_REQUESTED` as the explicit human approval/correction signal;
- authorized reviewer validation;
- immutable PR/task metadata checks;
- same-branch continuation rather than replacement PR creation;
- head-SHA and race revalidation;
- bounded attempts;
- no force push and no auto-merge.

### Timeout / recovery mechanics

- bounded agent runtime;
- normalized timeout/failure categories;
- separation of initial dispatch and review-repair recovery paths;
- asynchronous dispatcher/executor split for long-running repair work.

### Provider / model broker pieces

- provider/profile abstraction;
- explicit agent/profile compatibility rather than exposing all credentials;
- trusted provider broker with opaque per-job capability;
- model/path/concurrency/budget policy enforcement;
- restricted egress topology;
- conservative spend-guard components;
- explicit live-enable gates rather than silent direct-key fallback.

These components should be copied only with their associated security invariants; extracting a helper without its trust-boundary assumptions may invalidate the original safety design.

## Resume candidates

If the project is ever resumed, reconsider these only in response to a concrete requirement:

1. **Anthropic live pilot**: decide whether a paid Claude API path is still needed; re-audit current Anthropic APIs/pricing/spend controls before touching the existing live gate.
2. **Platform-vs-custom decision**: first verify whether ChatGPT Work, Codex, or another platform now satisfies the requirement without this infrastructure.
3. **Branch protection**: if the repository becomes active again, protect `master` and require CI before resuming feature changes.
4. **Provider broker completion**: only extend/production-validate provider profiles that are actually needed.
5. **Phase C hosted fallback**: reconsider only if self-hosted availability is a real operational blocker.
6. **Phase D runner/local fallback**: reconsider only if multiple runners or local inference deliver measurable value.
7. **Subscription credential handoff**: revisit only with a current, documented, narrow credential mechanism; never reuse assumptions from the freeze date without revalidation.
8. **Cross-repository production targets**: revalidate GitHub App installation and allowlists target by target before live use.

## First step if resuming

Do **not** begin by implementing the oldest open issue.

Start with a fresh audit of:

1. this document and `README.md`;
2. current platform capabilities (especially ChatGPT Work / Codex and equivalent hosted agents);
3. current `master` CI and dependency/tool versions;
4. the security invariants in `docs/ARCHITECTURE.md`;
5. the single concrete requirement that cannot be met without custom infrastructure.

Only after that audit should an old issue be reopened or a new implementation issue be created.

## Freeze verification record

Freeze baseline:

- branch: `master`
- commit: `92745245ee6c6318039d7ad21a9e2de66fcdcc65`
- open PRs at freeze preparation: none
- latest baseline CI on that commit: **PASS**
- infrastructure test suite: **PASS** in CI
- repository unit tests: **PASS** in CI
- branch protection: **not enabled** (known issue #106)

The documentation-only freeze PR should run the same CI again. Any failure introduced by platform/environment drift should be recorded as a freeze-time known issue rather than expanded into new feature development, unless it is an obvious safe maintenance fix.
