#!/usr/bin/env node
import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BROKER = path.join(ROOT, 'scripts', 'provider-broker-anthropic.mjs');
const CAPABILITY = 'guard-capability-marker';
const PROVIDER_KEY = 'sk-ant-guard-provider-marker';
const MODEL = 'claude-sonnet-5';
let passed = 0;
let failed = 0;
function t(desc, expected, actual) {
  if (String(expected) === String(actual)) { passed++; console.log(`PASS: ${desc}`); }
  else { failed++; console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`); }
}

function sendJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function startMock(port, { inputTokens = 12000, countStatus = 200, countDelayMs = 0, abortMessages = false } = {}) {
  const state = { events: [], counts: [], messages: [] };
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', 'http://mock');
    let json = null;
    try { json = await readJson(req); } catch {}
    const entry = { method: req.method, path: url.pathname, search: url.search, headers: req.headers, json };
    state.events.push(entry);

    if (req.method === 'POST' && url.pathname === '/v1/messages/count_tokens' && url.search === '?beta=true') {
      state.counts.push(entry);
      if (req.headers['x-api-key'] !== PROVIDER_KEY) return sendJson(res, 401, { error: { message: 'bad provider key' } });
      if (countStatus !== 200) return sendJson(res, countStatus, { error: { message: 'count failure' } });
      if (countDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, countDelayMs));
      return sendJson(res, 200, { input_tokens: inputTokens });
    }

    if (req.method === 'POST' && url.pathname === '/v1/messages' && url.search === '?beta=true') {
      state.messages.push(entry);
      if (req.headers['x-api-key'] !== PROVIDER_KEY) return sendJson(res, 401, { error: { message: 'bad provider key' } });
      if (abortMessages) {
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        res.write('event: message_start\ndata: {}\n\n');
        res.destroy();
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
      return;
    }

    sendJson(res, 404, { error: { message: 'unhandled route' } });
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, state })));
}

function waitForHealth(port, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const poll = () => {
      const req = http.get(`http://127.0.0.1:${port}/health`, (res) => { res.resume(); resolve(); });
      req.on('error', () => Date.now() - started > timeoutMs ? reject(new Error('timeout')) : setTimeout(poll, 30));
      req.setTimeout(300, () => req.destroy());
    };
    poll();
  });
}

async function startBroker(mockPort, brokerPort, extraEnv = {}) {
  const env = {
    ...process.env,
    BROKER_PORT: String(brokerPort),
    ANTHROPIC_API_KEY: PROVIDER_KEY,
    ANTHROPIC_PROVIDER_API_URL: `http://127.0.0.1:${mockPort}`,
    BROKER_ANTHROPIC_SPEND_GUARD_ENABLED: 'true',
    BROKER_JOB_MAX_USD: '0.25',
    BROKER_CAPABILITY: CAPABILITY,
    BROKER_TASK_ID: 'spend-guard-test',
    BROKER_ALLOWED_MODEL: MODEL,
    BROKER_CAPABILITY_EXPIRY_MS: '600000',
    BROKER_MAX_REQUESTS: '20',
    ...extraEnv,
  };
  const stderr = [];
  const child = spawn('node', [BROKER], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderr.on('data', (chunk) => stderr.push(chunk));
  child.stderrText = () => Buffer.concat(stderr).toString('utf8');
  await waitForHealth(brokerPort);
  return child;
}

function request(port, body, headerOverrides = {}) {
  return new Promise((resolve, reject) => {
    const raw = Buffer.from(JSON.stringify(body));
    const req = http.request({
      hostname: '127.0.0.1', port, path: '/v1/messages?beta=true', method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': String(raw.length),
        'x-api-key': CAPABILITY,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'claude-code-20250219,context-management-2025-06-27,effort-2025-11-24',
        ...headerOverrides,
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

function slowRequest(port, body, pauseMs = 150) {
  return new Promise((resolve, reject) => {
    const raw = Buffer.from(JSON.stringify(body));
    const req = http.request({
      hostname: '127.0.0.1', port, path: '/v1/messages?beta=true', method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': String(raw.length),
        'x-api-key': CAPABILITY,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'claude-code-20250219,context-management-2025-06-27,effort-2025-11-24',
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    const split = Math.max(1, Math.floor(raw.length / 2));
    req.write(raw.subarray(0, split));
    setTimeout(() => req.end(raw.subarray(split)), pauseMs);
  });
}

function validBody(overrides = {}) {
  return {
    model: MODEL,
    max_tokens: 32000,
    stream: true,
    messages: [{ role: 'user', content: [{ type: 'text', text: 'local guard test' }] }],
    system: [{ type: 'text', text: 'system', cache_control: { type: 'ephemeral', ttl: '1h' } }],
    thinking: { type: 'adaptive' },
    output_config: { effort: 'high' },
    context_management: { edits: [] },
    tools: [{ name: 'Read', description: 'client tool', input_schema: { type: 'object', properties: {} } }],
    ...overrides,
  };
}

async function stop(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 2500);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}
async function close(server) { if (server) await new Promise((resolve) => server.close(resolve)); }

const BASE = 27600;
let mock;
let broker;
try {
  mock = await startMock(BASE);
  broker = await startBroker(BASE, BASE + 1);

  let response = await request(BASE + 1, validBody(), {
    'anthropic-beta': 'future-priced-feature,effort-2025-11-24,claude-code-20250219,context-management-2025-06-27',
  });
  t('guarded Messages request succeeds through local mock', 200, response.status);
  t('Count Tokens occurs before first Messages request', '/v1/messages/count_tokens', mock.state.events[0]?.path);
  t('first cost-bearing request follows Count Tokens', '/v1/messages', mock.state.events[1]?.path);
  t('Count Tokens uses trusted provider key', PROVIDER_KEY, mock.state.counts[0]?.headers['x-api-key']);
  t('opaque capability is not sent to Count Tokens', false, mock.state.counts[0]?.headers['x-api-key'] === CAPABILITY);
  t('Count Tokens body omits max_tokens', false, Object.hasOwn(mock.state.counts[0]?.json || {}, 'max_tokens'));
  t('Count Tokens preserves tool definitions', 1, mock.state.counts[0]?.json?.tools?.length);
  t('Messages max_tokens is rewritten to guarded ceiling', 4096, mock.state.messages[0]?.json?.max_tokens);
  t('Messages keeps exact supported model', MODEL, mock.state.messages[0]?.json?.model);
  t('Messages uses pinned Anthropic version', '2023-06-01', mock.state.messages[0]?.headers['anthropic-version']);
  t('Messages strips unknown beta and uses pinned Anthropic beta contract', 'claude-code-20250219,context-management-2025-06-27,effort-2025-11-24', mock.state.messages[0]?.headers['anthropic-beta']);

  response = await request(BASE + 1, validBody());
  t('second guarded request remains within cumulative allowance', 200, response.status);
  t('two Messages requests have been admitted', 2, mock.state.messages.length);

  response = await request(BASE + 1, validBody());
  t('third request exhausts conservative $0.25 reservation', 402, response.status);
  t('exhausted request still performs free Count Tokens first', 3, mock.state.counts.length);
  t('exhausted request emits no third Messages call', 2, mock.state.messages.length);
  t('budget error is explicit', true, response.body.includes('ANTHROPIC_JOB_BUDGET_EXHAUSTED'));

  response = await request(BASE + 1, validBody({ tools: [{ type: 'web_search_20250305', name: 'web_search' }] }));
  t('unpriced server tool fails closed before Count Tokens', 400, response.status);
  t('unpriced shape does not call Count Tokens', 3, mock.state.counts.length);
  t('unpriced shape does not call Messages', 2, mock.state.messages.length);

  response = await request(BASE + 1, validBody(), { 'anthropic-version': '2099-01-01' });
  t('unknown Anthropic version fails closed', 400, response.status);
  t('unknown Anthropic version is denied before Count Tokens', 3, mock.state.counts.length);

  response = await request(BASE + 1, validBody(), { 'anthropic-beta': 'claude-code-20250219,new-priced-feature' });
  t('missing required Anthropic beta fails closed', 400, response.status);
  t('missing required Anthropic beta is denied before Count Tokens', 3, mock.state.counts.length);

  await stop(broker);
  const logs = broker.stderrText();
  t('broker logs contain only safe reservation metadata', true, logs.includes('reserved_micro_usd='));
  t('provider key never appears in broker logs', false, logs.includes(PROVIDER_KEY));
  t('capability never appears in broker logs', false, logs.includes(CAPABILITY));
  await close(mock.server);

  mock = await startMock(BASE + 10, { countStatus: 500 });
  broker = await startBroker(BASE + 10, BASE + 11);
  response = await request(BASE + 11, validBody());
  t('Count Tokens failure fails closed', 502, response.status);
  t('Count Tokens failure emits no Messages call', 0, mock.state.messages.length);
  await stop(broker);
  await close(mock.server);

  mock = await startMock(BASE + 30);
  broker = await startBroker(BASE + 30, BASE + 31);
  const firstSlow = slowRequest(BASE + 31, validBody());
  await new Promise((resolve) => setTimeout(resolve, 40));
  response = await request(BASE + 31, validBody());
  t('second request is denied while first request body is incomplete', 429, response.status);
  t('slow-body concurrency denial emits no competing Count Tokens call', 0, mock.state.counts.length);
  response = await firstSlow;
  t('first slow-body request completes normally', 200, response.status);
  t('only the admitted slow-body request reaches Messages', 1, mock.state.messages.length);
  await stop(broker);
  await close(mock.server);

  mock = await startMock(BASE + 40, { countDelayMs: 100 });
  broker = await startBroker(BASE + 40, BASE + 41, { BROKER_CAPABILITY_EXPIRY_MS: '50' });
  response = await request(BASE + 41, validBody());
  t('capability expiry after Count Tokens denies Messages', 401, response.status);
  t('expired-after-count request emits no Messages call', 0, mock.state.messages.length);
  await stop(broker);
  await close(mock.server);

  mock = await startMock(BASE + 50, { abortMessages: true });
  broker = await startBroker(BASE + 50, BASE + 51);
  try { await request(BASE + 51, validBody()); } catch {}
  await waitForHealth(BASE + 51);
  t('partial upstream stream failure leaves broker alive', true, broker.exitCode === null);
  t('partial upstream stream made exactly one reserved Messages call', 1, mock.state.messages.length);
  await stop(broker);
  await close(mock.server);

  const liveEnv = {
    ...process.env,
    BROKER_PORT: String(BASE + 20),
    ANTHROPIC_API_KEY: PROVIDER_KEY,
    BROKER_ANTHROPIC_LIVE_ALLOWED: 'true',
    BROKER_CAPABILITY: CAPABILITY,
    BROKER_TASK_ID: 'live-without-guard',
    BROKER_ALLOWED_MODEL: MODEL,
    BROKER_CAPABILITY_EXPIRY_MS: '600000',
    BROKER_MAX_REQUESTS: '10',
    BROKER_JOB_MAX_USD: '0.25',
  };
  const blocked = spawn('node', [BROKER], { env: liveEnv, stdio: ['ignore', 'ignore', 'pipe'] });
  const blockedErr = [];
  blocked.stderr.on('data', (chunk) => blockedErr.push(chunk));
  const blockedStatus = await new Promise((resolve) => blocked.once('exit', resolve));
  const blockedLogs = Buffer.concat(blockedErr).toString('utf8');
  t('live Anthropic forwarding cannot start without spend guard', 1, blockedStatus);
  t('live startup block names required spend guard', true, blockedLogs.includes('requires spend guard enforcement'));
  t('live startup block leaks no provider key', false, blockedLogs.includes(PROVIDER_KEY));

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
} finally {
  await stop(broker).catch(() => {});
  await close(mock?.server).catch(() => {});
}
