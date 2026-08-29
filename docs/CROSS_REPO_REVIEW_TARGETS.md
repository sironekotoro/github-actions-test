# Cross-repo Review Repair target scope

Scheduled cross-repo Review Repair intentionally uses a narrower target list than ordinary Agent Dispatch.

- `config/allowed-repositories.txt` controls repositories that may be targeted by Agent Dispatch.
- `config/review-repair-targets.txt` controls repositories polled by the scheduled cross-repo Review Repair dispatcher.
- Every review-repair polling target must also be present in the ordinary dispatch allowlist.

Add a repository to `review-repair-targets.txt` only after the dispatcher GitHub App is installed on that repository and automated Review Repair is intended there. This prevents an allowlisted-but-not-yet-installed repository from making every scheduled polling run fail while preserving fail-closed authorization for actual dispatches.

Current production polling target:

- `sironekotoro/zengin-pl`

`sironekotoro/sironekotoro-blog` remains ordinary-dispatch allowlisted but is not polled until the GitHub App is installed there.
