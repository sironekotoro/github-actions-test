# B3c Anthropic spend guard research

> Research checkpoint only. This file is on a stale development branch and is
> not a production change. Master remains fail-closed for Claude paid routing.

## Confirmed provider constraints (2026-09-02)

- Claude Platform's Usage & Cost Admin API can report usage/cost by workspace and API key, but it is retrospective reporting, not a synchronous per-request hard cap.
- Claude Platform workspace spend limits are monthly controls configured at the workspace/account level; they are not verified as an atomic per-job cap that the dispatcher can provision before each job.
- Anthropic's Spend Limits API is for Claude Enterprise members, not Claude Platform (Claude Console) organizations, so B3c cannot depend on it for normal Claude API jobs.
- `/v1/messages/count_tokens` is free and accepts the same structured message/tool inputs, but Anthropic documents that the result is an estimate and actual input token usage may differ slightly.
- Claude Sonnet 5 current standard token pricing is $2/MTok base input and $10/MTok output. Prompt-cache writes have higher input rates and must be included conservatively if broker-side estimation is used.
- The current B3b broker correctly refuses non-loopback live Anthropic forwarding unless an explicit trusted-live flag is set.
- Phase A currently maps `agent=claude-code` to provider `anthropic` and returns `PROVIDER_BUDGET_UNKNOWN`, so production routing remains parked rather than starting a paid Claude job.

## Safety conclusion

Do not enable live Anthropic forwarding merely by wiring `ANTHROPIC_API_KEY` into the trusted broker. The Phase B contract requires an authoritative bounded per-job spend policy. A post-hoc usage report or a token-count estimate alone is insufficient to claim an exact hard cap.

## Candidate broker-side guard for further proof

A conservative software cap can be explored without paid inference:

1. Exact-model allowlist, initially one priced model.
2. Reject server-side paid tools and service tiers not covered by the pricing table.
3. Before every paid request, obtain a free token-count estimate using the trusted credential.
4. Apply a conservative input safety margin and the highest applicable cache-write multiplier.
5. Rewrite or reject `max_tokens` so worst-case output cost plus reserved input cost remains within the remaining job allowance.
6. With broker concurrency fixed at 1, reserve the full worst-case amount before forwarding.
7. Parse streamed response usage and release only proven-unused reservation; on malformed/missing usage, retain the full reservation.
8. Keep a secondary workspace/account spend limit as blast-radius protection where available.
9. Keep live forwarding disabled until mock/property tests prove the accounting invariant for every accepted request shape.

This can bound broker-authorized list-price spend conservatively, but because Anthropic documents token counting as an estimate, the project must not describe it as a provider-enforced monetary hard cap unless a stronger provider primitive is found.

## Items still requiring proof

- Whether Claude Platform Admin/OAuth APIs can programmatically mint a new workspace-scoped inference API key and return its secret once, then revoke it after the job. Current Admin API documentation clearly supports listing/updating API keys and workspace/service-account membership, while key creation is documented primarily through Console UI.
- Whether a workspace monthly spend limit can be programmatically set with sufficiently immediate enforcement for a fresh disposable workspace. Current public Admin workspace endpoints expose creation/update/archive and rate-limit reads, not a documented workspace spend-limit setter.
- Exact billed-token/cache accounting fields in Claude Code 2.1.165 streaming responses for all accepted turns.
- Whether Claude Code's 25 declared tools are purely client-side definitions for this path; any Anthropic server-tool use must be denied or separately priced.
- A safe default output-token ceiling that still allows useful coding-agent work under the configured `$0.25` job allowance.

## Production gate

B3c may add plumbing and zero-paid acceptance tests, but the production live flag must remain off until the spend invariant above is resolved and explicitly audited. Any real Anthropic model request requires explicit user acknowledgement of paid API use first.
