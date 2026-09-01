#!/usr/bin/env node
import {
  DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST,
  INPUT_FIXED_MARGIN_TOKENS,
  INPUT_MICRO_USD_PER_TOKEN,
  OUTPUT_MICRO_USD_PER_TOKEN,
  PRICING_VERSION,
  SUPPORTED_MODEL,
  assertSupportedAnthropicShape,
  buildCountTokensBody,
  conservativeInputTokens,
  reserveAnthropicRequest,
  usdToMicroUsd,
} from '../scripts/lib/anthropic-spend-guard.mjs';

let passed = 0;
let failed = 0;
function t(desc, expected, actual) {
  if (String(expected) === String(actual)) { passed++; console.log(`PASS: ${desc}`); }
  else { failed++; console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`); }
}
function throws(desc, fn) {
  try { fn(); failed++; console.log(`FAIL: ${desc} (did not throw)`); }
  catch { passed++; console.log(`PASS: ${desc}`); }
}

function validBody(overrides = {}) {
  return {
    model: SUPPORTED_MODEL,
    max_tokens: 32000,
    stream: true,
    messages: [{ role: 'user', content: 'test' }],
    system: [{ type: 'text', text: 'system' }],
    thinking: { type: 'adaptive' },
    output_config: { effort: 'high' },
    context_management: { edits: [] },
    tools: [{ name: 'Read', description: 'client tool', input_schema: { type: 'object', properties: {} } }],
    metadata: { user_id: 'not-needed-for-count' },
    ...overrides,
  };
}

t('pricing table is pinned to current review date', '2026-09-02', PRICING_VERSION);
t('Sonnet 5 conservative input reserves highest cache-write list rate', 4, INPUT_MICRO_USD_PER_TOKEN);
t('Sonnet 5 output list rate is pinned', 10, OUTPUT_MICRO_USD_PER_TOKEN);
t('default per-request output ceiling is conservative', 4096, DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST);
t('$0.25 converts exactly to integer micro-USD', 250000, usdToMicroUsd('0.25'));
t('six decimal USD precision converts exactly', 1234567, usdToMicroUsd('1.234567'));
throws('more than six decimal places fail closed', () => usdToMicroUsd('0.0000001'));
throws('negative USD fails closed', () => usdToMicroUsd('-1'));

assertSupportedAnthropicShape(validBody());
t('ordinary B3a-style client tool is accepted', true, true);
throws('wrong pricing model fails closed', () => assertSupportedAnthropicShape(validBody({ model: 'claude-opus-5' })));
throws('stream=false fails closed', () => assertSupportedAnthropicShape(validBody({ stream: false })));
throws('fast mode fails closed', () => assertSupportedAnthropicShape(validBody({ speed: 'fast' })));
throws('MCP servers fail closed', () => assertSupportedAnthropicShape(validBody({ mcp_servers: [{ type: 'url', name: 'x', url: 'https://example.test' }] })));
throws('server-side typed tool fails closed', () => assertSupportedAnthropicShape(validBody({ tools: [{ type: 'web_search_20250305', name: 'web_search' }] })));
throws('unnamed toolset fails closed', () => assertSupportedAnthropicShape(validBody({ tools: [{ type: undefined }] })));

const countBody = buildCountTokensBody(validBody());
t('count body keeps exact model', SUPPORTED_MODEL, countBody.model);
t('count body keeps context management', true, Object.hasOwn(countBody, 'context_management'));
t('count body keeps client tools', 1, countBody.tools.length);
t('count body strips max_tokens from free count call', false, Object.hasOwn(countBody, 'max_tokens'));
t('count body strips stream from free count call', false, Object.hasOwn(countBody, 'stream'));
t('count body strips metadata not needed for pricing count', false, Object.hasOwn(countBody, 'metadata'));

t('zero estimate still includes fixed safety margin', INPUT_FIXED_MARGIN_TOKENS, conservativeInputTokens(0));
t('1000 estimate gets 10 percent plus fixed margin', 2124, conservativeInputTokens(1000));
throws('negative count fails closed', () => conservativeInputTokens(-1));

const quarter = usdToMicroUsd('0.25');
let reservation = reserveAnthropicRequest({ body: validBody(), estimatedInputTokens: 1000, remainingMicroUsd: quarter });
t('normal request is admitted', true, reservation.allowed);
t('Claude max_tokens is rewritten below raw 32000 request', true, reservation.outputTokens < 32000);
t('output is capped at configured per-request ceiling', DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST, reservation.outputTokens);
t('rewritten body carries bounded output tokens', reservation.outputTokens, reservation.rewrittenBody.max_tokens);
t('reservation never exceeds remaining budget', true, reservation.reservedMicroUsd <= quarter);
t('remaining budget subtracts reservation exactly', quarter - reservation.reservedMicroUsd, reservation.remainingAfterReservationMicroUsd);

reservation = reserveAnthropicRequest({ body: validBody(), estimatedInputTokens: 100000, remainingMicroUsd: 1000 });
t('insufficient input budget is denied', false, reservation.allowed);
t('budget denial is explicit', 'ANTHROPIC_JOB_BUDGET_EXHAUSTED', reservation.reason);

// Exhaustive-ish deterministic property sweep. Every admitted request must
// reserve no more than the supplied remaining budget and rewrite max_tokens no
// higher than both caller request and trusted per-request ceiling.
let propertyCases = 0;
for (const estimate of [0, 1, 10, 100, 1000, 10000, 50000, 100000, 250000]) {
  for (const remaining of [1, 100, 1000, 10000, 50000, 100000, 250000, 1000000]) {
    for (const requestedOutput of [1, 32, 512, 4096, 8192, 32000]) {
      propertyCases++;
      const result = reserveAnthropicRequest({
        body: validBody({ max_tokens: requestedOutput }),
        estimatedInputTokens: estimate,
        remainingMicroUsd: remaining,
      });
      if (result.allowed) {
        if (!(result.reservedMicroUsd <= remaining)) throw new Error('property failure: reservation over budget');
        if (!(result.outputTokens <= requestedOutput)) throw new Error('property failure: output above request');
        if (!(result.outputTokens <= DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST)) throw new Error('property failure: output above trusted ceiling');
        if (!(result.remainingAfterReservationMicroUsd >= 0)) throw new Error('property failure: negative remaining budget');
      }
    }
  }
}
t('property sweep completed', 432, propertyCases);

// Sequential worst-case reservations never regain budget. This deliberately
// sacrifices utilization for the first fail-safe implementation.
let remaining = quarter;
let admitted = 0;
for (let i = 0; i < 100; i++) {
  const result = reserveAnthropicRequest({ body: validBody(), estimatedInputTokens: 1000, remainingMicroUsd: remaining });
  if (!result.allowed) break;
  admitted++;
  remaining = result.remainingAfterReservationMicroUsd;
}
t('sequential conservative reservations eventually stop', true, admitted > 0 && admitted < 100);
t('sequential budget never becomes negative', true, remaining >= 0);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
