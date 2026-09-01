#!/usr/bin/env node
import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const brokerScript = path.join(ROOT, 'scripts', 'provider-broker.mjs');

const ADMIN_KEY = 'admin-local-secret-marker';
const CAPABILITY = 'b2b-capability-marker';
const MODEL = 'gpt-5.6-sol';
const PROJECT_KEY_PREFIX = 'sk-b2b-ephemeral-project-key-';

let passed = 0;
let failed = 0;
function t(desc, expected, actual) {
  const ok = String(expected) === String(actual);
  if (ok) {
    passed++;
    console.log(`PASS: ${desc}`);
  } else {
    failed++;
    console.log(`FAIL: ${desc} (expected [${expected}] got [${actual}])`);
  }
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

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks);
  let json = null;
  if (raw.length) {
    try { json = JSON.parse(raw.toString('utf8')); } catch {}
  }
  return { raw, json };
}

function sendJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) });
  res.end(text);
}

function startOpenAiMock(port, { failSpendLimit = false } = {}) {
  const state = {
    projectCounter: 0,
    projects: new Map(),
    adminRequests: [],
    providerRequests: [],
  };

  const server = http.createServer(async (req, res) => {
    const { raw, json } = await readBody(req);
    const url = new URL(req.url || '/', 'http://mock');
    const adminPath = url.pathname.startsWith('/v1/organization/');

    if (adminPath) {
      state.adminRequests.push({ method: req.method, path: url.pathname, headers: req.headers, json });
      if (req.headers.authorization !== `Bearer ${ADMIN_KEY}`) {
        sendJson(res, 401, { error: { message: 'bad admin auth' } });
        return;
      }

      if (req.method === 'POST' && url.pathname === '/v1/organization/projects') {
        state.projectCounter++;
        const id = `proj_b2b_${state.projectCounter}`;
        state.projects.set(id, {
          id,
          createdBody: json,
          spendLimit: null,
          modelPermissions: null,
          hostedToolPermissions: null,
          serviceAccountId: null,
          serviceAccountDeleted: false,
          archived: false,
        });
        sendJson(res, 200, { id, object: 'organization.project', name: json?.name || '', status: 'active' });
        return;
      }

      const projectMatch = url.pathname.match(/^\/v1\/organization\/projects\/(proj_b2b_\d+)(.*)$/);
      if (!projectMatch || !state.projects.has(projectMatch[1])) {
        sendJson(res, 404, { error: { message: 'project not found' } });
        return;
      }
      const projectId = projectMatch[1];
      const suffix = projectMatch[2];
      const project = state.projects.get(projectId);

      if (req.method === 'POST' && suffix === '/spend_limit') {
        project.spendLimit = json;
        if (failSpendLimit) {
          sendJson(res, 500, { error: { message: 'injected spend-limit failure' } });
          return;
        }
        sendJson(res, 200, {
          object: 'project.spend_limit',
          threshold_amount: json?.threshold_amount,
          currency: json?.currency,
          interval: json?.interval,
          enforcement: { status: 'enforcing' },
        });
        return;
      }

      if (req.method === 'POST' && suffix === '/model_permissions') {
        project.modelPermissions = json;
        sendJson(res, 200, {
          object: 'project.model_permissions',
          mode: json?.mode,
          model_ids: json?.model_ids,
        });
        return;
      }

      if (req.method === 'POST' && suffix === '/hosted_tool_permissions') {
        project.hostedToolPermissions = json;
        sendJson(res, 200, json || {});
        return;
      }

      if (req.method === 'POST' && suffix === '/service_accounts') {
        const serviceId = `svc_${projectId}`;
        project.serviceAccountId = serviceId;
        sendJson(res, 200, {
          object: 'organization.project.service_account',
          id: serviceId,
          name: json?.name || '',
          role: 'member',
          api_key: {
            object: 'organization.project.service_account.api_key',
            id: `key_${projectId}`,
            name: 'job key',
            value: `${PROJECT_KEY_PREFIX}${projectId}`,
          },
        });
        return;
      }

      if (
        req.method === 'DELETE' &&
        project.serviceAccountId &&
        suffix === `/service_accounts/${project.serviceAccountId}`
      ) {
        project.serviceAccountDeleted = true;
        sendJson(res, 200, { object: 'organization.project.service_account.deleted', id: project.serviceAccountId, deleted: true });
        return;
      }

      if (req.method === 'POST' && suffix === '/archive') {
        project.archived = true;
        sendJson(res, 200, { id: projectId, object: 'organization.project', status: 'archived' });
        return;
      }

      sendJson(res, 404, { error: { message: `unhandled admin route ${req.method} ${url.pathname}` } });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/v1/responses') {
      const request = { method: req.method, path: url.pathname, headers: req.headers, raw, json };
      state.providerRequests.push(request);
      const projectId = req.headers['openai-project'];
      const expectedKey = projectId ? `${PROJECT_KEY_PREFIX}${projectId}` : '';
      if (!projectId || !state.projects.has(projectId) || req.headers.authorization !== `Bearer ${expectedKey}`) {
        sendJson(res, 401, { error: { message: 'bad ephemeral project credential' } });
        return;
      }
      const created = { type: 'response.created', response: { id: 'resp_test' } };
      const completed = {
        type: 'response.completed',
        response: {
          id: 'resp_test',
          usage: { input_tokens: 0, input_tokens_details: null, output_tokens: 0, output_tokens_details: null, total_tokens: 0 },
        },
      };
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.end(
        `event: response.created\ndata: ${JSON.stringify(created)}\n\n` +
        `event: response.completed\ndata: ${JSON.stringify(completed)}\n\n`
      );
      return;
    }

    sendJson(res, 404, { error: { message: `unhandled provider route ${req.method} ${url.pathname}` } });
  });

  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, state })));
}

async function startBroker(mockPort, brokerPort, extraEnv = {}) {
  const env = {
    ...process.env,
    BROKER_PROVIDER: 'openai',
    BROKER_PORT: String(brokerPort),
    OPENAI_ADMIN_KEY: ADMIN_KEY,
    OPENAI_ADMIN_API_URL: `http://127.0.0.1:${mockPort}/v1`,
    OPENAI_PROVIDER_API_URL: `http://127.0.0.1:${mockPort}`,
    BROKER_CAPABILITY: CAPABILITY,
    BROKER_TASK_ID: 'b2b-test-task',
    BROKER_ALLOWED_MODEL: MODEL,
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

function request({ port, method = 'POST', path = '/v1/responses', capability = CAPABILITY, body, rawBody, headers = {} }) {
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
    model: MODEL,
    input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'local test' }] }],
    include: ['reasoning.encrypted_content'],
    stream: true,
    store: false,
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

function latestProject(mock) {
  return [...mock.state.projects.values()].at(-1);
}

async function closeServer(server) {
  if (!server) return;
  await new Promise((resolve) => server.close(resolve));
}

const BASE = 25100;
let mock;
let broker;

try {
  mock = await startOpenAiMock(BASE);
  broker = await startBroker(BASE, BASE + 1);

  const project = latestProject(mock);
  t('fresh disposable OpenAI project is created before broker serves traffic', true, Boolean(project));
  t('provider-side hard spend limit is exactly 25 cents', 25, project?.spendLimit?.threshold_amount);
  t('hard spend limit currency is USD', 'USD', project?.spendLimit?.currency);
  t('hard spend limit uses disposable-project monthly interval', 'month', project?.spendLimit?.interval);
  t('exact model allowlist mode is configured', 'allow_list', project?.modelPermissions?.mode);
  t('exactly one model is provider-allowlisted', MODEL, project?.modelPermissions?.model_ids?.length === 1 ? project.modelPermissions.model_ids[0] : '');
  for (const tool of ['file_search', 'web_search', 'image_generation', 'mcp', 'code_interpreter']) {
    t(`hosted tool ${tool} is disabled provider-side`, false, project?.hostedToolPermissions?.[tool]?.enabled);
  }
  t('ephemeral project service account is created', true, Boolean(project?.serviceAccountId));

  const setupPaths = mock.state.adminRequests.slice(0, 5).map((r) => `${r.method} ${r.path}`);
  t('project hard cap is configured before model permissions', true, setupPaths[1]?.endsWith('/spend_limit'));
  t('model allowlist is configured before hosted-tool policy', true, setupPaths[2]?.endsWith('/model_permissions'));
  t('hosted tools are disabled before service-account credential creation', true, setupPaths[3]?.endsWith('/hosted_tool_permissions') && setupPaths[4]?.endsWith('/service_accounts'));

  let resp = await request({ port: BASE + 1, method: 'GET', body: undefined });
  t('authenticated WebSocket GET receives immediate HTTP fallback', 426, resp.status);
  t('WebSocket GET is never forwarded to provider endpoint', 0, mock.state.providerRequests.length);

  resp = await request({
    port: BASE + 1,
    body: validBody(),
    headers: {
      Accept: 'text/event-stream',
      Originator: 'codex_exec',
      Version: '0.147.0',
      'OpenAI-Organization': 'org-untrusted',
      'OpenAI-Project': 'proj-untrusted',
    },
  });
  t('valid Responses POST succeeds through local provider mock', 200, resp.status);
  t('exactly one provider POST is forwarded', 1, mock.state.providerRequests.length);
  const forwarded = mock.state.providerRequests[0];
  t('upstream path is exact Responses path', '/v1/responses', forwarded?.path);
  t('broker injects ephemeral project service-account credential', `Bearer ${PROJECT_KEY_PREFIX}${project.id}`, forwarded?.headers.authorization);
  t('agent capability never becomes upstream Authorization', false, forwarded?.headers.authorization?.includes(CAPABILITY));
  t('admin credential never becomes provider Authorization', false, forwarded?.headers.authorization?.includes(ADMIN_KEY));
  t('broker forwards Codex Originator metadata', 'codex_exec', forwarded?.headers.originator);
  t('broker forwards pinned Codex version metadata', '0.147.0', forwarded?.headers.version);
  t('caller organization header is stripped', undefined, forwarded?.headers['openai-organization']);
  t('caller project header is replaced with disposable project id', project.id, forwarded?.headers['openai-project']);
  t('SSE response is streamed back', true, resp.body.includes('response.completed'));

  resp = await request({ port: BASE + 1, capability: 'wrong-capability', body: validBody() });
  t('wrong capability fails closed', 401, resp.status);

  resp = await request({ port: BASE + 1, body: validBody({ model: 'gpt-other' }) });
  t('wrong model fails closed', 403, resp.status);

  resp = await request({ port: BASE + 1, body: validBody({ stream: false }) });
  t('non-streaming Responses request fails closed', 400, resp.status);

  resp = await request({ port: BASE + 1, body: validBody({ store: true }) });
  t('stored Responses request fails closed', 400, resp.status);

  resp = await request({ port: BASE + 1, body: validBody({ background: true }) });
  t('background Responses request fails closed', 400, resp.status);

  resp = await request({ port: BASE + 1, path: '/v1/chat/completions', body: validBody() });
  t('unobserved Chat Completions path is denied', 403, resp.status);

  resp = await request({ port: BASE + 1, path: '/v1/responses?foo=bar', body: validBody() });
  t('query parameters are denied', 403, resp.status);

  resp = await request({ port: BASE + 1, rawBody: '{not-json' });
  t('malformed JSON fails closed', 400, resp.status);

  // B2a observed a ~57 KiB request even for a tiny prompt. Verify the OpenAI
  // default ceiling comfortably accepts that shape without reverting to the
  // much smaller OpenRouter default.
  const largeB2aLikeBody = validBody({ client_metadata: { marker: 'x'.repeat(60_000) } });
  resp = await request({ port: BASE + 1, body: largeB2aLikeBody });
  t('OpenAI default body ceiling accepts B2a-sized request', 200, resp.status);

  await stop(broker);
  t('graceful shutdown deletes ephemeral service account', true, project.serviceAccountDeleted);
  t('graceful shutdown archives disposable project', true, project.archived);
  const brokerLogs = broker.stderrText();
  for (const secret of [ADMIN_KEY, CAPABILITY, `${PROJECT_KEY_PREFIX}${project.id}`]) {
    t('broker lifecycle logs do not leak credential material', false, brokerLogs.includes(secret));
  }

  broker = await startBroker(BASE, BASE + 2, { BROKER_MAX_BODY_BYTES: '32' });
  resp = await request({ port: BASE + 2, body: validBody() });
  t('configured body ceiling is enforced', 413, resp.status);
  await stop(broker);

  broker = await startBroker(BASE, BASE + 3, { BROKER_MAX_REQUESTS: '2' });
  resp = await request({ port: BASE + 3, method: 'GET' });
  t('fallback GET counts as bounded capability request', 426, resp.status);
  resp = await request({ port: BASE + 3, body: validBody() });
  t('second request remains within limit', 200, resp.status);
  resp = await request({ port: BASE + 3, method: 'GET' });
  t('third request exceeds capability request limit', 429, resp.status);
  await stop(broker);

  // Provider hard-cap granularity is cents. Fractional cents are rounded down,
  // never up, so the provider-side ceiling cannot exceed the trusted job cap.
  broker = await startBroker(BASE, BASE + 4, { BROKER_JOB_MAX_USD: '0.259' });
  t('fractional-cent job cap rounds provider hard limit down', 25, latestProject(mock)?.spendLimit?.threshold_amount);
  await stop(broker);

  const missingKeyPort = BASE + 5;
  const missing = spawn('node', [brokerScript], {
    env: {
      ...process.env,
      BROKER_PROVIDER: 'openai',
      BROKER_PORT: String(missingKeyPort),
      OPENAI_ADMIN_KEY: '',
      BROKER_CAPABILITY: 'cap',
      BROKER_TASK_ID: 'task',
      BROKER_ALLOWED_MODEL: MODEL,
      BROKER_CAPABILITY_EXPIRY_MS: '60000',
      BROKER_MAX_REQUESTS: '10',
      BROKER_JOB_MAX_USD: '0.25',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const missingErr = [];
  missing.stderr.on('data', (chunk) => missingErr.push(chunk));
  const missingCode = await new Promise((resolve) => missing.once('exit', resolve));
  t('OpenAI broker fails startup without admin key', 1, missingCode);
  t('missing-key diagnostic names required admin variable', true, Buffer.concat(missingErr).toString('utf8').includes('OPENAI_ADMIN_KEY required'));

  await closeServer(mock.server);
  mock = await startOpenAiMock(BASE + 10, { failSpendLimit: true });
  const failing = spawn('node', [brokerScript], {
    env: {
      ...process.env,
      BROKER_PROVIDER: 'openai',
      BROKER_PORT: String(BASE + 11),
      OPENAI_ADMIN_KEY: ADMIN_KEY,
      OPENAI_ADMIN_API_URL: `http://127.0.0.1:${BASE + 10}/v1`,
      OPENAI_PROVIDER_API_URL: `http://127.0.0.1:${BASE + 10}`,
      BROKER_CAPABILITY: CAPABILITY,
      BROKER_TASK_ID: 'partial-provision-failure',
      BROKER_ALLOWED_MODEL: MODEL,
      BROKER_CAPABILITY_EXPIRY_MS: '60000',
      BROKER_MAX_REQUESTS: '10',
      BROKER_JOB_MAX_USD: '0.25',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const failingCode = await new Promise((resolve) => failing.once('exit', resolve));
  const failedProject = latestProject(mock);
  t('provisioning failure fails broker startup closed', 1, failingCode);
  t('partial project is archived during startup cleanup', true, failedProject?.archived);
  t('no service account exists after pre-credential provisioning failure', null, failedProject?.serviceAccountId);

  // Static/local-only guard: this test points both Admin and inference traffic
  // exclusively at loopback mocks and never embeds a real provider endpoint.
  const forbiddenProviderEndpoint = ['api', 'openai', 'com'].join('.');
  t('test harness contains no real OpenAI endpoint literal', false, fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').includes(forbiddenProviderEndpoint));
} catch (err) {
  failed++;
  console.error(`FAIL: unexpected test error: ${err.stack || err}`);
} finally {
  await stop(broker);
  if (mock?.server) await closeServer(mock.server);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
