#!/usr/bin/env node
import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BROKER = path.join(ROOT, 'scripts', 'provider-broker-anthropic.mjs');
const CAPABILITY = 'b3b-local-capability';
const PROVIDER_KEY = 'sk-ant-b3b-provider-secret';
const MODEL = 'claude-sonnet-5';
let passed = 0;
let failed = 0;
function t(desc, expected, actual) {
  if (String(expected) === String(actual)) { passed++; console.log(`PASS: ${desc}`); }
  else { failed++; console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`); }
}

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks);
  let json = null;
  try { json = JSON.parse(raw.toString('utf8')); } catch {}
  return { raw, json };
}

function startMock(port, delayMs = 0) {
  const state = { requests: [] };
  const server = http.createServer(async (req, res) => {
    const { raw, json } = await readBody(req);
    const url = new URL(req.url || '/', 'http://mock');
    state.requests.push({ method: req.method, path: url.pathname, search: url.search, headers: req.headers, raw, json });
    if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
    if (req.method === 'POST' && url.pathname === '/v1/messages' && url.search === '?beta=true') {
      if (req.headers['x-api-key'] !== PROVIDER_KEY) return sendJson(res, 401, { error: { message: 'bad upstream key' } });
      const event = { type: 'message_stop' };
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.end(`event: message_stop\ndata: ${JSON.stringify(event)}\n\n`);
      return;
    }
    sendJson(res, 404, { error: { message: 'unhandled mock route' } });
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, state })));
}

function waitForHealth(port, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const probe = () => {
      const req = http.get(`http://127.0.0.1:${port}/health`, (res) => { res.resume(); resolve(); });
      req.on('error', () => Date.now() - started > timeoutMs ? reject(new Error('timeout')) : setTimeout(probe, 30));
      req.setTimeout(300, () => req.destroy());
    };
    probe();
  });
}

async function startBroker(mockPort, brokerPort, extraEnv = {}) {
  const env = {
    ...process.env,
    BROKER_PORT: String(brokerPort),
    ANTHROPIC_API_KEY: PROVIDER_KEY,
    ANTHROPIC_PROVIDER_API_URL: `http://127.0.0.1:${mockPort}`,
    BROKER_CAPABILITY: CAPABILITY,
    BROKER_TASK_ID: 'b3b-test',
    BROKER_ALLOWED_MODEL: MODEL,
    BROKER_CAPABILITY_EXPIRY_MS: '600000',
    BROKER_MAX_REQUESTS: '20',
    ...extraEnv,
  };
  const stderr = [];
  const child = spawn('node', [BROKER], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderr.on('data', (c) => stderr.push(c));
  child.stderrText = () => Buffer.concat(stderr).toString('utf8');
  await waitForHealth(brokerPort);
  return child;
}

function request(port, { method = 'POST', path = '/v1/messages?beta=true', capability = CAPABILITY, body, rawBody, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const h = { ...headers };
    if (capability !== null) h['x-api-key'] = capability;
    let payload = null;
    if (rawBody !== undefined) payload = Buffer.from(rawBody);
    else if (body !== undefined) payload = Buffer.from(JSON.stringify(body));
    if (payload) { h['Content-Type'] ??= 'application/json'; h['Content-Length'] = String(payload.length); }
    const req = http.request({ hostname: '127.0.0.1', port, method, path, headers: h }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (payload) req.end(payload); else req.end();
  });
}

function validBody(overrides = {}) {
  return {
    model: MODEL,
    max_tokens: 32000,
    stream: true,
    messages: [{ role: 'user', content: 'local test' }],
    system: [],
    tools: [],
    thinking: { type: 'adaptive' },
    output_config: { effort: 'high' },
    ...overrides,
  };
}

async function stop(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await new Promise((resolve) => child.once('exit', resolve));
}
async function close(server) { if (server) await new Promise((resolve) => server.close(resolve)); }

const BASE = 26300;
let mock;
let broker;
try {
  mock = await startMock(BASE);
  broker = await startBroker(BASE, BASE + 1);

  let r = await request(BASE + 1, { method: 'HEAD', path: '/', capability: null });
  t('Claude preflight HEAD root is answered locally', 200, r.status);
  t('HEAD root is never forwarded upstream', 0, mock.state.requests.length);

  r = await request(BASE + 1, { body: validBody(), headers: {
    'anthropic-version': '2023-06-01',
    'anthropic-beta': 'claude-code-20250219,effort-2025-11-24',
    Authorization: 'Bearer caller-secret',
  }});
  t('valid observed Messages request succeeds', 200, r.status);
  t('exactly one upstream request is made', 1, mock.state.requests.length);
  const forwarded = mock.state.requests[0];
  t('upstream path remains /v1/messages', '/v1/messages', forwarded.path);
  t('observed beta query is preserved exactly', '?beta=true', forwarded.search);
  t('broker injects real provider key as x-api-key', PROVIDER_KEY, forwarded.headers['x-api-key']);
  t('opaque capability is not forwarded upstream', false, forwarded.headers['x-api-key'] === CAPABILITY);
  t('caller Authorization is stripped', undefined, forwarded.headers.authorization);
  t('Anthropic version is preserved', '2023-06-01', forwarded.headers['anthropic-version']);
  t('Anthropic beta header is preserved', 'claude-code-20250219,effort-2025-11-24', forwarded.headers['anthropic-beta']);
  t('exact model is forwarded unchanged', MODEL, forwarded.json.model);
  t('streaming SSE returns to caller', true, r.body.includes('message_stop'));

  r = await request(BASE + 1, { capability: 'wrong', body: validBody() });
  t('wrong capability fails closed', 401, r.status);
  r = await request(BASE + 1, { body: validBody({ model: 'claude-other' }) });
  t('wrong model fails closed', 403, r.status);
  r = await request(BASE + 1, { body: validBody({ stream: false }) });
  t('non-streaming request fails closed', 400, r.status);
  r = await request(BASE + 1, { body: validBody({ max_tokens: 32001 }) });
  t('max_tokens above observed bound fails closed', 400, r.status);
  r = await request(BASE + 1, { path: '/v1/messages', body: validBody() });
  t('missing beta query fails closed', 403, r.status);
  r = await request(BASE + 1, { path: '/v1/messages?beta=true&extra=1', body: validBody() });
  t('extra query parameter fails closed', 403, r.status);
  r = await request(BASE + 1, { path: '/v1/complete?beta=true', body: validBody() });
  t('unobserved endpoint fails closed', 403, r.status);
  r = await request(BASE + 1, { rawBody: '{bad-json' });
  t('malformed JSON fails closed', 400, r.status);

  await stop(broker);
  const logs = broker.stderrText();
  t('provider key is absent from broker logs', false, logs.includes(PROVIDER_KEY));
  t('capability is absent from broker logs', false, logs.includes(CAPABILITY));

  broker = await startBroker(BASE, BASE + 2, { BROKER_MAX_BODY_BYTES: '90000' });
  r = await request(BASE + 2, { rawBody: JSON.stringify(validBody({ messages: [{ role: 'user', content: 'x'.repeat(100000) }] })) });
  t('configured Claude body ceiling fails closed', 413, r.status);
  await stop(broker);

  const liveEnv = {
    ...process.env,
    BROKER_PORT: String(BASE + 3),
    ANTHROPIC_API_KEY: PROVIDER_KEY,
    BROKER_CAPABILITY: CAPABILITY,
    BROKER_TASK_ID: 'b3b-live-block-test',
    BROKER_ALLOWED_MODEL: MODEL,
    BROKER_CAPABILITY_EXPIRY_MS: '600000',
  };
  const blocked = spawn('node', [BROKER], { env: liveEnv, stdio: ['ignore', 'ignore', 'pipe'] });
  const blockedErr = [];
  blocked.stderr.on('data', (c) => blockedErr.push(c));
  const blockedStatus = await new Promise((resolve) => blocked.once('exit', resolve));
  t('real Anthropic endpoint is disabled by default in B3b', 1, blockedStatus);
  t('live block explains missing spend enforcement', true, Buffer.concat(blockedErr).toString('utf8').includes('spend enforcement'));

  mock = await startMock(BASE + 10, 250);
  broker = await startBroker(BASE + 10, BASE + 11);
  const first = request(BASE + 11, { body: validBody() });
  await new Promise((r0) => setTimeout(r0, 40));
  const second = await request(BASE + 11, { body: validBody() });
  t('concurrent second request fails closed', 429, second.status);
  await first;
  await stop(broker);

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
} finally {
  await stop(broker).catch(() => {});
  await close(mock?.server).catch(() => {});
}
