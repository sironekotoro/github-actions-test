#!/usr/bin/env node
import http from 'node:http';
import {
  SUPPORTED_MODEL,
  buildCountTokensBody,
  reserveAnthropicRequest,
  usdToMicroUsd,
} from '../scripts/lib/anthropic-spend-guard.mjs';

// Entirely local contract test: admission must finish before a cost-bearing
// Messages request shape can be emitted.
let passed = 0;
let failed = 0;
function t(desc, expected, actual) {
  if (String(expected) === String(actual)) { passed++; console.log(`PASS: ${desc}`); }
  else { failed++; console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`); }
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

const state = { countRequests: [], messageRequests: [] };
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://mock');
  if (req.method === 'POST' && url.pathname === '/v1/messages/count_tokens' && url.search === '?beta=true') {
    const json = await readJson(req);
    state.countRequests.push({ headers: req.headers, json });
    const body = JSON.stringify({ input_tokens: 12000, context_management: { original_input_tokens: 12500 } });
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    res.end(body);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/messages' && url.search === '?beta=true') {
    const json = await readJson(req);
    state.messageRequests.push({ headers: req.headers, json });
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
    return;
  }
  res.writeHead(404).end();
});

function post(port, path, body) {
  return new Promise((resolve, reject) => {
    const raw = Buffer.from(JSON.stringify(body));
    const req = http.request({
      hostname: '127.0.0.1', port, path, method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': String(raw.length),
        'x-api-key': 'fake-trusted-provider-key',
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'claude-code-20250219,context-management-2025-06-27,effort-2025-11-24',
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.end(raw);
  });
}

const requestBody = {
  model: SUPPORTED_MODEL,
  max_tokens: 32000,
  stream: true,
  messages: [{ role: 'user', content: [{ type: 'text', text: 'local integration test' }] }],
  system: [{ type: 'text', text: 'trusted system prompt', cache_control: { type: 'ephemeral', ttl: '1h' } }],
  thinking: { type: 'adaptive' },
  output_config: { effort: 'high' },
  context_management: { edits: [] },
  tools: [{ name: 'Read', description: 'client tool', input_schema: { type: 'object', properties: {} } }],
  metadata: { user_id: 'metadata-is-not-needed-for-counting' },
};

const PORT = 27300;
await new Promise((resolve) => server.listen(PORT, '127.0.0.1', resolve));
try {
  const countBody = buildCountTokensBody(requestBody);
  let response = await post(PORT, '/v1/messages/count_tokens?beta=true', countBody);
  t('free token-count mock succeeds', 200, response.status);
  const countResult = JSON.parse(response.body);
  t('token-count estimate is received', 12000, countResult.input_tokens);
  t('one count request is made before inference', 1, state.countRequests.length);
  t('no Messages request exists before budget admission', 0, state.messageRequests.length);
  t('count request omits raw max_tokens', false, Object.hasOwn(state.countRequests[0].json, 'max_tokens'));
  t('count request preserves context management', true, Object.hasOwn(state.countRequests[0].json, 'context_management'));
  t('count request preserves client tool schemas', 1, state.countRequests[0].json.tools.length);

  let remaining = usdToMicroUsd('0.25');
  const reservation = reserveAnthropicRequest({
    body: requestBody,
    estimatedInputTokens: countResult.input_tokens,
    remainingMicroUsd: remaining,
  });
  t('request is admitted under local $0.25 allowance', true, reservation.allowed);
  t('raw Claude max_tokens is reduced to trusted ceiling', 4096, reservation.outputTokens);
  t('reservation remains within allowance', true, reservation.reservedMicroUsd <= remaining);
  remaining = reservation.remainingAfterReservationMicroUsd;

  response = await post(PORT, '/v1/messages?beta=true', reservation.rewrittenBody);
  t('rewritten Messages mock succeeds', 200, response.status);
  t('exactly one paid-shape message follows successful admission', 1, state.messageRequests.length);
  t('provider sees exact trusted model', SUPPORTED_MODEL, state.messageRequests[0].json.model);
  t('provider sees rewritten bounded max_tokens', 4096, state.messageRequests[0].json.max_tokens);
  t('provider sees stream=true', true, state.messageRequests[0].json.stream);

  const beforeDenied = state.messageRequests.length;
  const denied = reserveAnthropicRequest({
    body: requestBody,
    estimatedInputTokens: 1000000,
    remainingMicroUsd: usdToMicroUsd('0.01'),
  });
  t('unaffordable count is denied before Messages', false, denied.allowed);
  t('denied admission has explicit budget reason', 'ANTHROPIC_JOB_BUDGET_EXHAUSTED', denied.reason);
  t('denied admission emits no additional Messages request', beforeDenied, state.messageRequests.length);

  // First version never credits unused reservation back. A second admission
  // starts from the monotonically lower remaining value.
  const second = reserveAnthropicRequest({
    body: requestBody,
    estimatedInputTokens: countResult.input_tokens,
    remainingMicroUsd: remaining,
  });
  if (second.allowed) {
    t('second reservation is based only on lower remaining balance', true, second.reservedMicroUsd <= remaining);
    t('second reservation cannot increase budget', true, second.remainingAfterReservationMicroUsd < remaining);
  } else {
    t('second request may conservatively stop when allowance is exhausted', 'ANTHROPIC_JOB_BUDGET_EXHAUSTED', second.reason);
    t('denied request leaves no negative budget', true, remaining >= 0);
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exitCode = failed ? 1 : 0;
} finally {
  await new Promise((resolve) => server.close(resolve));
}
