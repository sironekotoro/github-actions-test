#!/usr/bin/env node
import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const brokerScript = path.join(ROOT, 'scripts', 'provider-broker.mjs');

let passed = 0;
let failed = 0;
function t(desc, expected, actual) {
  const ok = String(expected) === String(actual);
  if (ok) { passed++; console.log(`PASS: ${desc}`); }
  else { failed++; console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`); }
}

function waitForPort(port, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const check = () => {
      const req = http.get(`http://127.0.0.1:${port}/health`, (res) => {
        res.resume();
        resolve();
      });
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) reject(new Error('timeout'));
        else setTimeout(check, 50);
      });
      req.setTimeout(500, () => req.destroy());
    };
    check();
  });
}

function startUpstream(port) {
  const captured = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks);
    captured.push({ method: req.method, url: req.url, headers: req.headers, raw });

    if (req.method === 'POST' && req.url === '/v1/responses') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.end(
        'event: response.created\ndata: {"type":"response.created","response":{"id":"resp_test"}}\n\n' +
        'event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_test","usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0}}}\n\n'
      );
      return;
    }
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end('{"error":"not found"}');
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, captured })));
}

async function startBroker(upstreamPort, brokerPort, extraEnv = {}) {
  const env = {
    ...process.env,
    BROKER_PROVIDER: 'openai',
    BROKER_PORT: String(brokerPort),
    OPENAI_API_KEY: 'sk-openai-upstream-secret-marker',
    OPENAI_PROVIDER_API_URL: `http://127.0.0.1:${upstreamPort}`,
    OPENAI_ORGANIZATION: 'org-trusted',
    OPENAI_PROJECT: 'proj-trusted',
    BROKER_CAPABILITY: 'b2b-capability-marker',
    BROKER_TASK_ID: 'b2b-test-task',
    BROKER_ALLOWED_MODEL: 'gpt-5.6-sol',
    BROKER_JOB_MAX_USD: '0.25',
    BROKER_MAX_REQUESTS: '100',
    BROKER_CAPABILITY_EXPIRY_MS: '600000',
    ...extraEnv,
  };
  const stderr = [];
  const child = spawn('node', [brokerScript], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stderr.on('data', (chunk) => stderr.push(chunk));
  child.stderrText = () => Buffer.concat(stderr).toString('utf8');
  await waitForPort(brokerPort);
  return child;
}

function request({ port, method = 'POST', path = '/v1/responses', capability = 'b2b-capability-marker', body, rawBody, headers = {} }) {
  return new Promise((resolve, reject) => {
    const requestHeaders = { ...headers };
    if (capability !== null) requestHeaders.Authorization = `Bearer ${capability}`;
    let payload = null;
    if (rawBody !== undefined) payload = Buffer.from(rawBody);
    else if (body !== undefined) payload = Buffer.from(JSON.stringify(body));
    if (payload && !requestHeaders['Content-Type']) requestHeaders['Content-Type'] = 'application/json';
    if (payload) requestHeaders['Content-Length'] = String(payload.length);

    const req = http.request({ hostname: '127.0.0.1', port, path, method, headers: requestHeaders }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('timeout')); });
    if (payload) req.end(payload); else req.end();
  });
}

function validBody(overrides = {}) {
  return {
    model: 'gpt-5.6-sol',
    input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'local test' }] }],
    stream: true,
    store: false,
    ...overrides,
  };
}

async function stop(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 1500);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}

const UPSTREAM = 25100;
let upstream;
let broker;

try {
  upstream = await startUpstream(UPSTREAM);
  broker = await startBroker(UPSTREAM, UPSTREAM + 1);

  let resp = await request({ port: UPSTREAM + 1, method: 'GET', body: undefined });
  t('authenticated WebSocket GET receives immediate HTTP fallback', 426, resp.status);
  t('WebSocket GET is never forwarded upstream', 0, upstream.captured.length);

  resp = await request({
    port: UPSTREAM + 1,
    body: validBody(),
    headers: {
      Accept: 'text/event-stream',
      Originator: 'codex_exec',
      Version: '0.147.0',
      'OpenAI-Organization': 'org-untrusted',
      'OpenAI-Project': 'proj-untrusted',
    },
  });
  t('valid Responses POST succeeds through local upstream', 200, resp.status);
  t('exactly one provider POST forwarded', 1, upstream.captured.length);
  const forwarded = upstream.captured[0];
  t('upstream path is exact Responses path', '/v1/responses', forwarded.url);
  t('broker injects trusted OpenAI API credential', 'Bearer sk-openai-upstream-secret-marker', forwarded.headers.authorization);
  t('broker forwards Codex Originator metadata', 'codex_exec', forwarded.headers.originator);
  t('broker forwards pinned Codex version metadata', '0.147.0', forwarded.headers.version);
  t('broker replaces caller organization header with trusted value', 'org-trusted', forwarded.headers['openai-organization']);
  t('broker replaces caller project header with trusted value', 'proj-trusted', forwarded.headers['openai-project']);
  t('SSE response is streamed back', true, resp.body.includes('response.completed'));

  resp = await request({ port: UPSTREAM + 1, capability: 'wrong-capability', body: validBody() });
  t('wrong capability fails closed', 401, resp.status);

  resp = await request({ port: UPSTREAM + 1, body: validBody({ model: 'gpt-other' }) });
  t('wrong model fails closed', 403, resp.status);

  resp = await request({ port: UPSTREAM + 1, body: validBody({ stream: false }) });
  t('non-streaming Responses request fails closed', 400, resp.status);

  resp = await request({ port: UPSTREAM + 1, body: validBody({ store: true }) });
  t('stored Responses request fails closed', 400, resp.status);

  resp = await request({ port: UPSTREAM + 1, body: validBody({ background: true }) });
  t('background Responses request fails closed', 400, resp.status);

  resp = await request({ port: UPSTREAM + 1, path: '/v1/chat/completions', body: validBody() });
  t('unobserved Chat Completions path is denied', 403, resp.status);

  resp = await request({ port: UPSTREAM + 1, path: '/v1/responses?foo=bar', body: validBody() });
  t('query parameters are denied', 403, resp.status);

  resp = await request({ port: UPSTREAM + 1, rawBody: '{not-json' });
  t('malformed JSON fails closed', 400, resp.status);

  await stop(broker);
  broker = await startBroker(UPSTREAM, UPSTREAM + 2, { BROKER_MAX_BODY_BYTES: '32' });
  resp = await request({ port: UPSTREAM + 2, body: validBody() });
  t('configured body ceiling is enforced', 413, resp.status);
  await stop(broker);

  broker = await startBroker(UPSTREAM, UPSTREAM + 3, { BROKER_MAX_REQUESTS: '2' });
  resp = await request({ port: UPSTREAM + 3, method: 'GET' });
  t('fallback GET counts as bounded capability request', 426, resp.status);
  resp = await request({ port: UPSTREAM + 3, body: validBody() });
  t('second request remains within limit', 200, resp.status);
  resp = await request({ port: UPSTREAM + 3, method: 'GET' });
  t('third request exceeds capability request limit', 429, resp.status);
  await stop(broker);

  const missingKeyPort = UPSTREAM + 4;
  const missing = spawn('node', [brokerScript], {
    env: {
      ...process.env,
      BROKER_PROVIDER: 'openai',
      BROKER_PORT: String(missingKeyPort),
      OPENAI_API_KEY: '',
      BROKER_CAPABILITY: 'cap',
      BROKER_TASK_ID: 'task',
      BROKER_ALLOWED_MODEL: 'gpt-5.6-sol',
      BROKER_CAPABILITY_EXPIRY_MS: '60000',
      BROKER_MAX_REQUESTS: '10',
      BROKER_JOB_MAX_USD: '0.25',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const missingErr = [];
  missing.stderr.on('data', (chunk) => missingErr.push(chunk));
  const missingCode = await new Promise((resolve) => missing.once('exit', resolve));
  t('OpenAI broker fails startup without upstream key', 1, missingCode);
  t('missing-key diagnostic names required variable', true, Buffer.concat(missingErr).toString('utf8').includes('OPENAI_API_KEY required'));

  t('real OpenAI endpoint is not referenced by test harness', false, import.meta.url.includes('api.openai.com'));
} catch (err) {
  failed++;
  console.error(`FAIL: unexpected test error: ${err.stack || err}`);
} finally {
  await stop(broker);
  if (upstream?.server) await new Promise((resolve) => upstream.server.close(resolve));
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
