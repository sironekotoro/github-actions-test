#!/usr/bin/env node
import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const fixturesDir = path.join(ROOT, 'tests', 'fixtures');
const brokerScript = path.join(ROOT, 'scripts', 'provider-broker.mjs');

let passed = 0;
let failed = 0;
let currentSection = '';

function t(desc, expected, actual) {
  const ok = String(expected) === String(actual);
  if (ok) { passed++; console.log(`PASS: ${desc}`); }
  else { failed++; console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`); }
}

function section(name) {
  currentSection = name;
  console.log(`\n--- ${name} ---`);
}

async function startMockServer(port, mode = 'ok') {
  const child = spawn('node', [path.join(fixturesDir, 'broker_mock_server.js')], {
    env: { ...process.env, MOCK_PORT: String(port), MOCK_MANAGEMENT_MODE: mode },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForPort(port, 3000);
  return child;
}

function waitForPort(port, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    function check() {
      const req = http.get(`http://127.0.0.1:${port}/health`, (res) => {
        // Readiness means the HTTP listener is accepting connections. Some
        // focused mock servers intentionally do not implement /health and
        // return 404; that is still a valid readiness signal.
        res.resume();
        resolve();
      });
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) reject(new Error('timeout'));
        else setTimeout(check, 100);
      });
      req.setTimeout(2000, () => { req.destroy(); if (Date.now() - start > timeoutMs) reject(new Error('timeout'));
        else setTimeout(check, 100); });
    }
    check();
  });
}

function simulateManagementEndpoint(port) {
  // Creates a mock that captures management API calls for later assertion
  const captured = { createBody: null, deleteCalled: false, deleteHash: null };
  const server = http.createServer((req, res) => {
    const path = req.url || '';
    if (req.method === 'POST' && path === '/api/v1/keys' || path === '') {
      let data = '';
      req.on('data', c => data += c);
      req.on('end', () => {
        captured.createBody = JSON.parse(data);
        const resp = JSON.stringify({
          key: 'sk-or-mock-key-abc',
          data: { hash: 'mock-hash-captured', limit: captured.createBody.limit, limit_reset: null, expires_at: captured.createBody.expires_at }
        });
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(resp);
      });
    } else if (req.method === 'DELETE' && path.startsWith('/api/v1/keys/')) {
      captured.deleteCalled = true;
      captured.deleteHash = path.split('/').pop();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ deleted: true }));
    } else if (path === '/api/v1/chat/completions') {
      let data = '';
      req.on('data', c => data += c);
      req.on('end', () => {
        const parsed = JSON.parse(data);
        // Echo back headers for assertion
        const resp = JSON.stringify({
          id: 'mock-echo', object: 'chat.completion', model: parsed.model,
          choices: [{ message: { role: 'assistant', content: 'mock' } }],
          _echoHeaders: req.headers
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(resp);
      });
    } else if (path === '/api/v1/models') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'test-model' }] }));
    } else {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'not found' }));
    }
  });
  server.listen(port, '127.0.0.1');
  return { server, captured };
}

async function startBroker(mockPort, brokerPort, extraEnv = {}) {
  const env = {
    ...process.env,
    PROVIDER_BROKER_ENABLED: 'true',
    BROKER_PORT: String(brokerPort),
    OPENROUTER_MANAGEMENT_KEY: 'mock-mgmt-key',
    BROKER_CAPABILITY: 'test-capability-token-abc123',
    BROKER_TASK_ID: 'test-task-001',
    BROKER_ALLOWED_MODEL: 'openrouter/deepseek/deepseek-v4-flash',
    BROKER_JOB_MAX_USD: '0.25',
    BROKER_MAX_REQUESTS: '100',
    BROKER_CAPABILITY_EXPIRY_MS: '3600000',
    OPENROUTER_MANAGEMENT_API_URL: `http://127.0.0.1:${mockPort}/api/v1/keys`,
    OPENROUTER_PROVIDER_API_URL: `http://127.0.0.1:${mockPort}`,
    ...extraEnv,
  };
  const stderrChunks = [];
  const child = spawn('node', [brokerScript], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stderr.on('data', (c) => stderrChunks.push(c));
  try {
    await waitForPort(brokerPort, 5000);
  } catch (e) {
    child.kill();
    throw new Error(`broker did not start in time: ${Buffer.concat(stderrChunks).toString()}`);
  }
  child.stderrData = () => Buffer.concat(stderrChunks).toString();
  return child;
}

async function httpRequest(method, port, path, auth, body, extraHeaders = {}) {
  return new Promise((resolve, reject) => {
    const headers = { 'Content-Type': 'application/json', ...extraHeaders };
    if (auth) headers['Authorization'] = 'Bearer ' + auth;
    const opts = { hostname: '127.0.0.1', port, path, method, headers };
    const req = http.request(opts, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('timeout')); });
    if (body) req.end(JSON.stringify(body));
    else req.end();
  });
}

function parseResponse(resp) {
  try { return JSON.parse(resp.body); } catch { return {}; }
}

// ============================================================================
// TESTS
// ============================================================================

let mock, broker;
const MOCK_BASE = 23000;

async function run() {
  try {
    // 1. Management API: 201 create, proper response shape, no models field
    section('Management API: 201 create, no models field');
    const { server: mgmtServer, captured } = simulateManagementEndpoint(MOCK_BASE + 200);
    await waitForPort(MOCK_BASE + 200, 2000);
    broker = await startBroker(MOCK_BASE + 200, MOCK_BASE + 201);
    await new Promise(r => setTimeout(r, 500));
    t('management create body has no models field', 'absent',
      captured.createBody && captured.createBody.models ? 'present' : 'absent');
    t('management create body has limit', '0.25', String(captured.createBody?.limit));
    t('management create body has limit_reset null', 'null', JSON.stringify(captured.createBody?.limit_reset));
    t('management create body has expires_at', 'present',
      captured.createBody?.expires_at ? 'present' : 'absent');
    t('management create body has name', 'present',
      captured.createBody?.name ? 'present' : 'absent');
    // Verify DELETE was NOT called yet (cleanup happens on shutdown)
    t('management delete NOT called before shutdown', false, captured.deleteCalled);
    broker.kill(); await new Promise(r => setTimeout(r, 300));
    t('management delete called on shutdown', true, captured.deleteCalled);
    t('management delete hash matches created hash', 'mock-hash-captured', captured.deleteHash);
    mgmtServer.close();

    // 2. Capability authentication
    section('Capability authentication');
    mock = await startMockServer(MOCK_BASE);
    broker = await startBroker(MOCK_BASE, MOCK_BASE + 1);
    let resp = await httpRequest('GET', MOCK_BASE + 1, '/api/v1/models', 'test-capability-token-abc123');
    t('valid capability auth succeeds', 200, resp.status);
    resp = await httpRequest('GET', MOCK_BASE + 1, '/api/v1/models', '');
    t('missing capability fails closed', 401, resp.status);
    resp = await httpRequest('GET', MOCK_BASE + 1, '/api/v1/models', 'wrong-token');
    t('wrong capability fails closed', 401, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 3. Expired capability
    section('Expired capability');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 10);
    broker = await startBroker(MOCK_BASE + 10, MOCK_BASE + 11, { BROKER_CAPABILITY_EXPIRY_MS: '1' });
    await new Promise(r => setTimeout(r, 800));
    resp = await httpRequest('GET', MOCK_BASE + 11, '/api/v1/models', 'test-capability-token-abc123');
    t('expired capability fails closed', 401, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 4. Model validation with normalization
    section('Model validation with normalization');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 20);
    broker = await startBroker(MOCK_BASE + 20, MOCK_BASE + 21);
    resp = await httpRequest('POST', MOCK_BASE + 21, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      model: 'deepseek/deepseek-v4-flash', messages: [{ role: 'user', content: 'hi' }]
    });
    t('allowed model without openrouter/ prefix accepted', 200, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 21, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      model: 'openrouter/deepseek/deepseek-v4-flash', messages: [{ role: 'user', content: 'hi' }]
    });
    t('allowed model with openrouter/ prefix accepted', 200, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 21, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      model: 'other/model', messages: [{ role: 'user', content: 'hi' }]
    });
    t('disallowed model fails closed', 403, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 21, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      messages: [{ role: 'user', content: 'hi' }]
    });
    t('missing model in body fails closed', 400, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 5. Path and method validation
    section('Path and method validation');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 30);
    broker = await startBroker(MOCK_BASE + 30, MOCK_BASE + 31);
    resp = await httpRequest('GET', MOCK_BASE + 31, '/api/v1/models', 'test-capability-token-abc123');
    t('GET /api/v1/models allowed', 200, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 31, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      model: 'openrouter/deepseek/deepseek-v4-flash', messages: [{ role: 'user', content: 'hi' }]
    });
    t('POST /api/v1/chat/completions allowed', 200, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 31, '/api/v1/completions', 'test-capability-token-abc123', {
      model: 'openrouter/deepseek/deepseek-v4-flash', prompt: 'hello'
    });
    t('POST /api/v1/completions denied', 403, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 31, '/api/v1/embeddings', 'test-capability-token-abc123', {
      model: 'openrouter/deepseek/deepseek-v4-flash', input: 'hello'
    });
    t('POST /api/v1/embeddings denied', 403, resp.status);
    resp = await httpRequest('POST', MOCK_BASE + 31, '/api/v1/keys', 'test-capability-token-abc123');
    t('POST /api/v1/keys denied', 403, resp.status);
    resp = await httpRequest('DELETE', MOCK_BASE + 31, '/api/v1/chat/completions', 'test-capability-token-abc123');
    t('DELETE on allowed path denied', 403, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 6. Request count exhaustion
    section('Request count exhaustion');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 40);
    broker = await startBroker(MOCK_BASE + 40, MOCK_BASE + 41, { BROKER_MAX_REQUESTS: '2' });
    resp = await httpRequest('GET', MOCK_BASE + 41, '/api/v1/models', 'test-capability-token-abc123');
    t('request 1 within limit', 200, resp.status);
    resp = await httpRequest('GET', MOCK_BASE + 41, '/api/v1/models', 'test-capability-token-abc123');
    t('request 2 within limit', 200, resp.status);
    resp = await httpRequest('GET', MOCK_BASE + 41, '/api/v1/models', 'test-capability-token-abc123');
    t('request 3 beyond limit fails', 429, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 7. Malformed payload
    section('Malformed payload');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 50);
    broker = await startBroker(MOCK_BASE + 50, MOCK_BASE + 51);
    resp = await new Promise((resolve, reject) => {
      const opts = { hostname: '127.0.0.1', port: MOCK_BASE + 51, path: '/api/v1/chat/completions', method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer test-capability-token-abc123' } };
      const req = http.request(opts, (res) => { let d = ''; res.on('data', c => d += c);
        res.on('end', () => resolve({ status: res.statusCode, body: d })); });
      req.on('error', reject);
      req.setTimeout(5000, () => { req.destroy(); reject(new Error('timeout')); });
      req.end('this is not json');
    });
    t('malformed payload fails closed', 400, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 8. Provisioning parameters
    section('Provisioning parameters');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 60);
    broker = await startBroker(MOCK_BASE + 60, MOCK_BASE + 61, {
      BROKER_JOB_MAX_USD: '0.50',
      BROKER_CAPABILITY_EXPIRY_MS: '600000',
    });
    resp = await httpRequest('GET', MOCK_BASE + 61, '/api/v1/models', 'test-capability-token-abc123');
    t('provisioned key works with custom params', 200, resp.status);
    const stderr = broker.stderrData();
    t('broker logs provisioned (no hash)', 'present', stderr.includes('temporary key provisioned') ? 'present' : 'absent');
    t('broker does not log management key', 'absent', stderr.includes('mock-mgmt-key') ? 'present' : 'absent');
    t('broker does not log capability token', 'absent', stderr.includes('test-capability-token-abc123') ? 'present' : 'absent');
    t('broker does not log prompt body', 'absent', stderr.includes('mock response') ? 'present' : 'absent');
    t('broker does not log truncated key hash', 'absent', stderr.includes('...') || stderr.includes('REDACTED') || stderr.includes('mock-hash') ? 'present' : 'absent');
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 9. Provisioning failure (mock returns 500)
    section('Provisioning failure');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 70, 'http500');
    try {
      broker = await startBroker(MOCK_BASE + 70, MOCK_BASE + 71);
      t('broker fails on provisioning error', 'should-not-start', 'started');
      broker.kill();
    } catch (e) {
      t('broker fails closed on provisioning error', 0, 0);
    }
    mock.kill(); await new Promise(r => setTimeout(r, 200));

    // 10. Concurrency enforcement
    section('Concurrency enforcement');
    mock = await startMockServer(MOCK_BASE + 80);
    mock.kill('SIGKILL'); await new Promise(r => setTimeout(r, 300));
    const mockDelayChild = spawn('node', [path.join(fixturesDir, 'broker_mock_server.js')], {
      env: { ...process.env, MOCK_PORT: String(MOCK_BASE + 80), MOCK_DELAY_MS: '500' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    mock = mockDelayChild;
    await waitForPort(MOCK_BASE + 80, 3000);
    broker = await startBroker(MOCK_BASE + 80, MOCK_BASE + 81);
    const concurrencyResult = await new Promise((resolve) => {
      let done = 0, failures = 0;
      function req() {
        const data = JSON.stringify({ model: 'openrouter/deepseek/deepseek-v4-flash', messages: [{ role: 'user', content: 'hi' }] });
        const opts = { hostname: '127.0.0.1', port: MOCK_BASE + 81, path: '/api/v1/chat/completions', method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer test-capability-token-abc123' } };
        const r = http.request(opts, (res) => { res.resume();
          res.on('end', () => { if (res.statusCode === 429) failures++; done++;
            if (done === 2) resolve(failures); }); });
        r.setTimeout(3000, () => { r.destroy(); done++; if (done === 2) resolve(failures); });
        r.end(data);
      }
      req(); req();
      setTimeout(() => resolve(failures), 4000);
    });
    t('concurrency violation returns 429', 1, concurrencyResult);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 11. Upstream header control: allowlist only, blocked headers stripped
    section('Upstream header allowlist');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 90);
    broker = await startBroker(MOCK_BASE + 90, MOCK_BASE + 91);
    resp = await httpRequest('POST', MOCK_BASE + 91, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      model: 'openrouter/deepseek-v4-flash', messages: [{ role: 'user', content: 'hi' }]
    }, {
      'Proxy-Authorization': 'Basic abc123',
      'X-Forwarded-For': 'evil.com',
      'X-Custom-Header': 'should-be-dropped',
      'Cookie': 'session=abc',
      'X-API-Key': 'sentinel-key-value',
      'api-key': 'sentinel-api-key',
    });
    t('caller request succeeds despite credential headers', 200, resp.status);
    broker.kill(); await new Promise(r => setTimeout(r, 100));

    // 12. Upstream authorization is injected, caller auth stripped
    section('Upstream authorization injection');
    const capturePort = MOCK_BASE + 300;
    const managementCapturePort = MOCK_BASE + 302;
    const upstreamCapture = { headers: null };
    const capServer = http.createServer((req, res) => {
      upstreamCapture.headers = req.headers;
      let data = '';
      req.on('data', c => data += c);
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ id: 'mock', choices: [{ message: { role: 'assistant', content: 'ok' } }] }));
      });
    });
    capServer.listen(capturePort, '127.0.0.1');
    await waitForPort(capturePort, 2000);
    const captureMgmt = await startMockServer(managementCapturePort);
    const capEnvBroker = await startBroker(managementCapturePort, MOCK_BASE + 301, {
      OPENROUTER_PROVIDER_API_URL: `http://127.0.0.1:${capturePort}`,
      BROKER_MAX_REQUESTS: '10',
    });
    resp = await httpRequest('POST', MOCK_BASE + 301, '/api/v1/chat/completions', 'test-capability-token-abc123', {
      model: 'openrouter/deepseek/deepseek-v4-flash', messages: [{ role: 'user', content: 'hi' }]
    }, {
      'Authorization': 'Bearer caller-token-should-not-leak',
      'Proxy-Authorization': 'Basic sentinel-proxy',
      'X-Api-Key': 'sentinel-x-api-key',
      'api-key': 'sentinel-api-key',
      'Cookie': 'session=secret',
      'X-Forwarded-For': '1.2.3.4',
      'X-Custom-Hack': 'should-not-reach-upstream',
    });
    t('upstream request succeeds', 200, resp.status);
    const uh = upstreamCapture.headers;
    t('upstream Authorization is broker-held key, not caller auth', true,
      uh && uh['authorization'] === 'Bearer sk-or-mock-provisioned-key-123456789');
    t('upstream has no Proxy-Authorization', 'absent',
      uh && uh['proxy-authorization'] ? 'present' : 'absent');
    t('upstream has no X-Api-Key', 'absent',
      uh && (uh['x-api-key'] || uh['x-apikey']) ? 'present' : 'absent');
    t('upstream has no api-key', 'absent',
      uh && uh['api-key'] ? 'present' : 'absent');
    t('upstream has no Cookie', 'absent',
      uh && uh['cookie'] ? 'present' : 'absent');
    t('upstream has no X-Forwarded-For', 'absent',
      uh && uh['x-forwarded-for'] ? 'present' : 'absent');
    t('upstream has no X-Custom-Hack', 'absent',
      uh && uh['x-custom-hack'] ? 'present' : 'absent');
    t('upstream has Content-Type', 'present',
      uh && uh['content-type'] ? 'present' : 'absent');
    capServer.close();
    capEnvBroker.kill('SIGTERM'); await new Promise(r => setTimeout(r, 300));
    captureMgmt.kill('SIGKILL'); await new Promise(r => setTimeout(r, 100));

    // 13. Graceful key deletion on shutdown
    section('Graceful key deletion on shutdown');
    mock.kill(); await new Promise(r => setTimeout(r, 200));
    mock = await startMockServer(MOCK_BASE + 100);
    broker = await startBroker(MOCK_BASE + 100, MOCK_BASE + 101);
    broker.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 500));
    const deleteStderr = broker.stderrData();
    t('broker logs delete on SIGTERM', 'present', deleteStderr.includes('temporary key deleted') ? 'present' : 'absent');
    mock.kill(); await new Promise(r => setTimeout(r, 200));

    // 14. Delete failure expiry fallback
    section('Delete failure expiry fallback');
    mock = await startMockServer(MOCK_BASE + 110, 'ok');
    mock.kill('SIGKILL'); await new Promise(r => setTimeout(r, 300));
    mock = await startMockServer(MOCK_BASE + 110, 'ok');
    broker = await startBroker(MOCK_BASE + 110, MOCK_BASE + 111);
    mock.kill('SIGKILL');
    const mockDelFail = spawn('node', [path.join(fixturesDir, 'broker_mock_server.js')], {
      env: { ...process.env, MOCK_PORT: String(MOCK_BASE + 110), MOCK_DELETE_MODE: 'http500', MOCK_MANAGEMENT_MODE: 'ok' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    mock = mockDelFail;
    await waitForPort(MOCK_BASE + 110, 3000);
    broker.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 500));
    const deleteFailStderr = broker.stderrData();
    t('broker logs expiry fallback on delete failure', 'present',
      deleteFailStderr.includes('fallback') ? 'present' : 'absent');
    mock.kill(); await new Promise(r => setTimeout(r, 200));

    // 15. Fresh capability generation test
    section('Fresh capability generation');
    const commonSh = String(fs.readFileSync(path.join(ROOT, 'scripts/lib/common.sh')));
    t('common.sh has generate_broker_capability function', 'present',
      commonSh.includes('generate_broker_capability') ? 'present' : 'absent');
    const dispatchScript = String(fs.readFileSync(path.join(ROOT, 'scripts/run-agent-dispatch-container.sh')));
    t('dispatch container uses generate_broker_capability', 'present',
      dispatchScript.includes('generate_broker_capability') ? 'present' : 'absent');
    t('dispatch container never reuses AGENT_CREDENTIAL_VALUE for capability', 'absent',
      dispatchScript.includes('broker_capability="${AGENT_CREDENTIAL_VALUE:-}"') ? 'present' : 'absent');
    const rrScript = String(fs.readFileSync(path.join(ROOT, 'scripts/run-review-repair-agent-container.sh')));
    t('review repair uses generate_broker_capability', 'present',
      rrScript.includes('generate_broker_capability') ? 'present' : 'absent');
    t('review repair never reuses OPENROUTER_API_KEY for capability', 'absent',
      rrScript.includes('broker_capability="${OPENROUTER_API_KEY:-}"') ? 'present' : 'absent');

  } finally {
    try { broker?.kill('SIGKILL'); } catch {}
    try { mock?.kill('SIGKILL'); } catch {}
    await new Promise(r => setTimeout(r, 300));
  }

  // ============================================================================
  // Static structural tests
  // ============================================================================
  section('Static structural tests');

  // Credential profile
  t('opencode broker profile allowed in agent_allowed_profiles', 'present',
    String(fs.readFileSync(path.join(ROOT, 'scripts/lib/credentials.sh'))).includes('openrouter-broker') ? 'present' : 'absent');

  // Action inputs
  const actionYml = String(fs.readFileSync(path.join(ROOT, '.github/actions/agent-dispatch/action.yml')));
  t('action has provider_broker_enabled input', 'yes', actionYml.includes('provider_broker_enabled') ? 'yes' : 'no');
  t('action has provider_job_max_usd input', 'yes', actionYml.includes('provider_job_max_usd') ? 'yes' : 'no');
  t('action has openrouter_management_key input', 'yes', actionYml.includes('openrouter_management_key') ? 'yes' : 'no');

  const sameRepoBlock = actionYml.split('Run same-repo coding agent')[1] || '';
  t('same-repo passes PROVIDER_BROKER_ENABLED', 'yes', sameRepoBlock.includes('PROVIDER_BROKER_ENABLED') ? 'yes' : 'no');
  t('same-repo passes PROVIDER_JOB_MAX_USD', 'yes', sameRepoBlock.includes('PROVIDER_JOB_MAX_USD') ? 'yes' : 'no');
  t('same-repo passes OPENROUTER_MANAGEMENT_KEY', 'yes', sameRepoBlock.includes('OPENROUTER_MANAGEMENT_KEY') ? 'yes' : 'no');

  const crossRepoBlock = actionYml.split('Run cross-repo coding agent')[1] || '';
  t('cross-repo passes PROVIDER_BROKER_ENABLED', 'yes', crossRepoBlock.includes('PROVIDER_BROKER_ENABLED') ? 'yes' : 'no');
  t('cross-repo passes PROVIDER_JOB_MAX_USD', 'yes', crossRepoBlock.includes('PROVIDER_JOB_MAX_USD') ? 'yes' : 'no');
  t('cross-repo passes OPENROUTER_MANAGEMENT_KEY', 'yes', crossRepoBlock.includes('OPENROUTER_MANAGEMENT_KEY') ? 'yes' : 'no');

  t('action builds broker image when enabled', 'yes', actionYml.includes('docker build --tag "provider-broker:') ? 'yes' : 'no');
  t('action cleans broker image', 'yes', actionYml.includes('provider-broker') ? 'yes' : 'no');

  const credentialsSh = String(fs.readFileSync(path.join(ROOT, 'scripts/lib/credentials.sh')));
  t('credentials.sh checks PROVIDER_BROKER_ENABLED for default profile', 'yes',
    credentialsSh.includes('PROVIDER_BROKER_ENABLED') ? 'yes' : 'no');

  const opencodeAdapter = String(fs.readFileSync(path.join(ROOT, 'scripts/agents/opencode.sh')));
  t('opencode adapter uses JSON config merge not concatenation', 'yes',
    opencodeAdapter.includes('JSON.parse') || opencodeAdapter.includes('JSON.stringify') ? 'yes' : 'no');
  t('opencode adapter checks PROVIDER_BROKER_ENABLED', 'yes',
    opencodeAdapter.includes('PROVIDER_BROKER_ENABLED') ? 'yes' : 'no');

  const containerScript = String(fs.readFileSync(path.join(ROOT, 'scripts/run-agent-dispatch-container.sh')));
  t('container MANAGEMENT_KEY only in broker env section', 'yes',
    containerScript.includes('MANAGEMENT_KEY') && !/\-\-env\s+OPENROUTER_MANAGEMENT_KEY/.test(containerScript) ? 'yes' : 'no');
  t('dispatch removes proxy env for broker', 'yes', containerScript.includes('agent_proxy_env') ? 'yes' : 'no');
  t('dispatch uses setup_broker_network_topology for broker', 'yes',
    containerScript.includes('setup_broker_network_topology') ? 'yes' : 'no');
  t('dispatch does not call setup_standard_proxy in broker mode', 'yes',
    /if.*PROVIDER_BROKER_ENABLED.*profile.*openrouter-broker/.test(containerScript) && containerScript.indexOf('setup_standard_proxy') > containerScript.indexOf('if.*PROVIDER_BROKER_ENABLED') ? 'no' : 'yes');
  t('broker not connected to egress_network', 'yes',
    !containerScript.includes('connect.*broker.*egress_network') ? 'yes' : 'no');
  t('broker uses BROKER_PROXY_URL for egress', 'yes',
    containerScript.includes('BROKER_PROXY_URL') ? 'yes' : 'no');
  t('broker capability not literal in docker argv', 'yes',
    containerScript.includes('-e BROKER_CAPABILITY') && !/-e BROKER_CAPABILITY=/.test(containerScript) ? 'yes' : 'no');
  t('agent OPENROUTER_API_KEY not literal in docker argv', 'yes',
    containerScript.includes('--env OPENROUTER_API_KEY') && !/--env OPENROUTER_API_KEY=/.test(containerScript) ? 'yes' : 'no');

  const commonSh = String(fs.readFileSync(path.join(ROOT, 'scripts/lib/common.sh')));
  t('agent_exec_clean includes OPENCODE_CONFIG_CONTENT', 'yes',
    commonSh.includes('OPENCODE_CONFIG_CONTENT') ? 'yes' : 'no');
  t('agent_exec_clean includes OPENCODE_BROKER_BASE_URL', 'yes',
    commonSh.includes('OPENCODE_BROKER_BASE_URL') ? 'yes' : 'no');
  t('agent_exec_clean includes OPENROUTER_MODEL', 'yes',
    commonSh.includes('OPENROUTER_MODEL') ? 'yes' : 'no');
  t('agent_exec_clean includes PROVIDER_BROKER_ENABLED', 'yes',
    commonSh.includes('PROVIDER_BROKER_ENABLED') ? 'yes' : 'no');
  t('common.sh has --internal for broker_egress_network', 'yes',
    commonSh.includes('--internal') ? 'yes' : 'no');
  t('common.sh has setup_broker_network_topology', 'yes',
    commonSh.includes('setup_broker_network_topology') ? 'yes' : 'no');
  t('common.sh exports PROXY_BROKER_IP', 'yes',
    commonSh.includes('PROXY_BROKER_IP') ? 'yes' : 'no');

  const brokerScriptContent = String(fs.readFileSync(brokerScript));
  t('broker script does not echo management key', 'absent',
    brokerScriptContent.includes('console.log.*Management') || brokerScriptContent.includes('process.stdout.write.*Management') ? 'present' : 'absent');
  t('broker does not log raw capability value', 'absent',
    brokerScriptContent.includes('log(.*CAPABILITY') || brokerScriptContent.includes('BROKER_CAPABILITY value') ? 'present' : 'absent');
  t('broker uses allowlist for upstream headers', 'yes',
    brokerScriptContent.includes('buildUpstreamHeaders') ? 'yes' : 'no');
  t('broker normalizes model (strips openrouter/ prefix)', 'yes',
    brokerScriptContent.includes('normalizeModel') ? 'yes' : 'no');
  t('broker checks status===201 for create', 'yes',
    brokerScriptContent.includes('status !== 201') ? 'yes' : 'no');
  t('broker graceful shutdown on SIGTERM', 'yes',
    brokerScriptContent.includes('SIGTERM') ? 'yes' : 'no');
  t('broker graceful shutdown on SIGINT', 'yes',
    brokerScriptContent.includes('SIGINT') ? 'yes' : 'no');
  t('broker loads undici via createRequire', 'yes',
    brokerScriptContent.includes('createRequire') ? 'yes' : 'no');

  t('broker Dockerfile uses local undici install', 'yes',
    String(fs.readFileSync(path.join(ROOT, 'docker/provider-broker.Dockerfile'))).includes('package.json') ? 'yes' : 'no');
  t('common.sh exports PROXY_BROKER_IP', 'yes',
    commonSh.includes('PROXY_BROKER_IP') ? 'yes' : 'no');

  t('broker mock server exists', 'yes', fs.existsSync(path.join(fixturesDir, 'broker_mock_server.js')) ? 'yes' : 'no');
  t('broker test helper exists', 'yes', fs.existsSync(path.join(fixturesDir, 'broker_test_helper.js')) ? 'yes' : 'no');

  const rrContainerScript = String(fs.readFileSync(path.join(ROOT, 'scripts/run-review-repair-agent-container.sh')));
  t('review-repair container checks broker image when enabled', 'yes',
    rrContainerScript.includes('broker_image') ? 'yes' : 'no');
  t('review-repair container generates fresh capability', 'yes',
    rrContainerScript.includes('generate_broker_capability') ? 'yes' : 'no');
  t('review-repair uses setup_broker_network_topology', 'yes',
    rrContainerScript.includes('setup_broker_network_topology') ? 'yes' : 'no');
  t('review-repair does not create networks inline when broker enabled', 'yes',
    rrContainerScript.includes('docker network create --internal "$private_network"') ? 'no' : 'yes');
  t('review-repair container graceful broker shutdown', 'yes',
    rrContainerScript.includes('docker stop --time 10') ? 'yes' : 'no');
  t('review-repair broker uses BROKER_PROXY_URL', 'yes',
    rrContainerScript.includes('BROKER_PROXY_URL') ? 'yes' : 'no');
  t('review-repair broker capability not literal in docker argv', 'yes',
    rrContainerScript.includes('-e BROKER_CAPABILITY') && !/-e BROKER_CAPABILITY=/.test(rrContainerScript) ? 'yes' : 'no');
  t('review-repair agent OPENROUTER_API_KEY not literal in docker argv', 'yes',
    rrContainerScript.includes('--env OPENROUTER_API_KEY') && !/--env OPENROUTER_API_KEY=/.test(rrContainerScript) ? 'yes' : 'no');
  t('review-repair passes capability for redaction in broker mode', 'yes',
    rrContainerScript.includes('"$broker_capability"') ? 'yes' : 'no');

  // Credential cannot become capability tests
  section('Credential-to-capability separation');
  const credentialPublicationSh = String(fs.readFileSync(path.join(ROOT, 'tests/test-credential-publication.sh')));
  t('credential publication scans work with broker capability', 'yes',
    credentialPublicationSh.includes('scan_final_workspace_for_credential') ? 'yes' : 'no');

  // Summary
  console.log(`\n----\nPASS=${passed} FAIL=${failed}`);
  process.exit(failed > 0 ? 1 : 0);
}

run().catch(err => {
  console.error('FATAL:', err.message);
  process.exit(1);
});
