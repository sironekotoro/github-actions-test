#!/usr/bin/env node
import http from 'node:http';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const PROVIDER = String(process.env.BROKER_PROVIDER || 'openrouter').trim().toLowerCase();
const PORT = Number.parseInt(process.env.BROKER_PORT || '3080', 10);

const OPENROUTER_MANAGEMENT_KEY = process.env.OPENROUTER_MANAGEMENT_KEY || '';
const OPENROUTER_MANAGEMENT_API_URL = process.env.OPENROUTER_MANAGEMENT_API_URL || 'https://openrouter.ai/api/v1/keys';
const OPENROUTER_PROVIDER_API_URL = process.env.OPENROUTER_PROVIDER_API_URL || 'https://openrouter.ai';

const OPENAI_ADMIN_KEY = process.env.OPENAI_ADMIN_KEY || '';
const OPENAI_ADMIN_API_URL = process.env.OPENAI_ADMIN_API_URL || 'https://api.openai.com/v1';
const OPENAI_PROVIDER_API_URL = process.env.OPENAI_PROVIDER_API_URL || 'https://api.openai.com';

const CAPABILITY = process.env.BROKER_CAPABILITY || '';
const CAPABILITY_TASK_ID = process.env.BROKER_TASK_ID || '';
const CAPABILITY_MODEL = process.env.BROKER_ALLOWED_MODEL || '';
const CAPABILITY_EXPIRY_MS = Number.parseInt(process.env.BROKER_CAPABILITY_EXPIRY_MS || '', 10);
const CAPABILITY_MAX_REQUESTS = Number.parseInt(process.env.BROKER_MAX_REQUESTS || '500', 10);
const CAPABILITY_JOB_MAX_USD = Number.parseFloat(process.env.BROKER_JOB_MAX_USD || '0.25');
const BODY_LIMIT_RAW = String(process.env.BROKER_MAX_BODY_BYTES || '').trim();
const PROXY_URL = process.env.BROKER_PROXY_URL || '';

let ProxyAgent = null;
if (PROXY_URL) {
  try {
    ProxyAgent = require('undici').ProxyAgent;
  } catch {
    log('error', 'undici not available for proxy support');
    process.exit(1);
  }
}

let provisionedKeyHash = null;
let upstreamCredential = null;
let openAiProjectId = null;
let openAiServiceAccountId = null;
let openAiApiKeyId = null;
let requestCount = 0;
let concurrentCount = 0;
let capabilityExpiresAt = 0;
let cleanedUp = false;
let maxBodyBytes = 0;
let openAiSpendLimitCents = 0;

function log(level, msg) {
  const ts = new Date().toISOString();
  process.stderr.write(`[${ts}] [${level}] [broker] ${msg}\n`);
}

function failJson(res, status, code, detail, extraHeaders = {}) {
  const body = JSON.stringify({ error: { code, message: detail } });
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function validPositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function isSuccessStatus(status) {
  return status >= 200 && status < 300;
}

function validateConfiguration() {
  if (PROVIDER !== 'openrouter' && PROVIDER !== 'openai') {
    throw new Error('BROKER_PROVIDER must be openrouter or openai');
  }
  if (PROVIDER === 'openrouter' && !OPENROUTER_MANAGEMENT_KEY) {
    throw new Error('OPENROUTER_MANAGEMENT_KEY required');
  }
  if (PROVIDER === 'openai' && !OPENAI_ADMIN_KEY) {
    throw new Error('OPENAI_ADMIN_KEY required');
  }
  if (!CAPABILITY) throw new Error('BROKER_CAPABILITY required');
  if (!CAPABILITY_TASK_ID) throw new Error('BROKER_TASK_ID required');
  if (!CAPABILITY_MODEL) throw new Error('BROKER_ALLOWED_MODEL required');
  if (!validPositiveInteger(PORT) || PORT > 65535) throw new Error('BROKER_PORT invalid');
  if (!validPositiveInteger(CAPABILITY_EXPIRY_MS)) throw new Error('BROKER_CAPABILITY_EXPIRY_MS invalid');
  if (!validPositiveInteger(CAPABILITY_MAX_REQUESTS)) throw new Error('BROKER_MAX_REQUESTS invalid');
  if (!Number.isFinite(CAPABILITY_JOB_MAX_USD) || CAPABILITY_JOB_MAX_USD <= 0) {
    throw new Error('BROKER_JOB_MAX_USD invalid');
  }

  if (PROVIDER === 'openai') {
    // OpenAI project hard spend limits are configured in whole cents. Round
    // down so provider-side enforcement can never exceed the trusted job cap.
    openAiSpendLimitCents = Math.floor((CAPABILITY_JOB_MAX_USD * 100) + 1e-9);
    if (!validPositiveInteger(openAiSpendLimitCents)) {
      throw new Error('BROKER_JOB_MAX_USD is below OpenAI hard-limit granularity');
    }
  }

  if (BODY_LIMIT_RAW) {
    const configured = Number.parseInt(BODY_LIMIT_RAW, 10);
    if (!validPositiveInteger(configured) || String(configured) !== BODY_LIMIT_RAW || configured > 8 * 1024 * 1024) {
      throw new Error('BROKER_MAX_BODY_BYTES invalid');
    }
    maxBodyBytes = configured;
  } else {
    maxBodyBytes = PROVIDER === 'openai' ? 2 * 1024 * 1024 : 256 * 1024;
  }
}

async function jsonFetch(url, method, authorization, body) {
  const headers = { Authorization: `Bearer ${authorization}`, 'Content-Type': 'application/json' };
  const opts = { method, headers };
  if (body !== undefined && body !== null) opts.body = JSON.stringify(body);
  if (ProxyAgent) opts.dispatcher = new ProxyAgent(PROXY_URL);
  const response = await fetch(url, opts);
  const text = await response.text();
  let parsed = null;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
  }
  return { status: response.status, body: parsed };
}

async function managementFetch(method, path, body) {
  return jsonFetch(`${OPENROUTER_MANAGEMENT_API_URL}${path}`, method, OPENROUTER_MANAGEMENT_KEY, body);
}

async function openAiAdminFetch(method, path, body) {
  return jsonFetch(`${OPENAI_ADMIN_API_URL}${path}`, method, OPENAI_ADMIN_KEY, body);
}

function safeTaskName(prefix) {
  const task = CAPABILITY_TASK_ID.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 32) || 'task';
  return `${prefix}-${task}-${Date.now()}`.slice(0, 64);
}

async function provisionOpenRouterCredential() {
  const now = new Date();
  const expiresAt = new Date(now.getTime() + CAPABILITY_EXPIRY_MS + 300000);
  const payload = {
    name: safeTaskName('broker'),
    limit: CAPABILITY_JOB_MAX_USD,
    limit_reset: null,
    expires_at: expiresAt.toISOString(),
  };
  const { status, body } = await managementFetch('POST', '', payload);
  if (status !== 201 || !body?.key || !body?.data?.hash) {
    throw new Error(`provisioning failed: HTTP ${status}`);
  }
  upstreamCredential = body.key;
  provisionedKeyHash = body.data.hash;
  log('info', 'temporary key provisioned');
}

async function provisionOpenAiCredential() {
  // A fresh project is the per-job provider-side security boundary. Because it
  // begins with zero spend, a monthly hard limit on this disposable project is
  // equivalent to a lifetime limit for the job. The project also carries an
  // exact model allowlist and disables every OpenAI-hosted tool before any
  // inference-capable credential is created.
  let result = await openAiAdminFetch('POST', '/organization/projects', {
    name: safeTaskName('agent-broker'),
  });
  if (!isSuccessStatus(result.status) || !result.body?.id) {
    throw new Error(`OpenAI project creation failed: HTTP ${result.status}`);
  }
  openAiProjectId = result.body.id;

  result = await openAiAdminFetch('POST', `/organization/projects/${openAiProjectId}/spend_limit`, {
    currency: 'USD',
    interval: 'month',
    threshold_amount: openAiSpendLimitCents,
  });
  if (
    !isSuccessStatus(result.status) ||
    result.body?.currency !== 'USD' ||
    result.body?.interval !== 'month' ||
    Number(result.body?.threshold_amount) !== openAiSpendLimitCents ||
    result.body?.enforcement?.status !== 'enforcing'
  ) {
    throw new Error(`OpenAI hard spend limit was not confirmed: HTTP ${result.status}`);
  }
  log('info', `OpenAI hard spend limit confirmed at ${openAiSpendLimitCents} cents`);

  result = await openAiAdminFetch('POST', `/organization/projects/${openAiProjectId}/model_permissions`, {
    mode: 'allow_list',
    model_ids: [CAPABILITY_MODEL],
  });
  if (
    !isSuccessStatus(result.status) ||
    result.body?.mode !== 'allow_list' ||
    !Array.isArray(result.body?.model_ids) ||
    result.body.model_ids.length !== 1 ||
    result.body.model_ids[0] !== CAPABILITY_MODEL
  ) {
    throw new Error(`OpenAI exact model allowlist was not confirmed: HTTP ${result.status}`);
  }
  log('info', 'OpenAI exact model allowlist confirmed');

  const disabledHostedTools = {
    file_search: { enabled: false },
    web_search: { enabled: false },
    image_generation: { enabled: false },
    mcp: { enabled: false },
    code_interpreter: { enabled: false },
  };
  result = await openAiAdminFetch('POST', `/organization/projects/${openAiProjectId}/hosted_tool_permissions`, disabledHostedTools);
  const hostedToolsDisabled = Object.keys(disabledHostedTools).every(
    (name) => result.body?.[name]?.enabled === false,
  );
  if (!isSuccessStatus(result.status) || !hostedToolsDisabled) {
    throw new Error(`OpenAI hosted-tool deny policy was not confirmed: HTTP ${result.status}`);
  }
  log('info', 'OpenAI hosted tools disabled');

  result = await openAiAdminFetch('POST', `/organization/projects/${openAiProjectId}/service_accounts`, {
    name: safeTaskName('agent-job'),
  });
  if (
    !isSuccessStatus(result.status) ||
    !result.body?.id ||
    result.body?.role !== 'member' ||
    !result.body?.api_key?.id ||
    !result.body?.api_key?.value
  ) {
    throw new Error(`OpenAI service-account credential creation failed: HTTP ${result.status}`);
  }
  openAiServiceAccountId = result.body.id;
  openAiApiKeyId = result.body.api_key.id;
  upstreamCredential = result.body.api_key.value;
  log('info', 'ephemeral OpenAI project credential provisioned');
}

async function provisionProviderCredential() {
  if (PROVIDER === 'openai') {
    await provisionOpenAiCredential();
    return;
  }
  await provisionOpenRouterCredential();
}

async function cleanupOpenRouterCredential() {
  if (!provisionedKeyHash) return;
  try {
    const { status } = await managementFetch('DELETE', `/${provisionedKeyHash}`);
    if (status === 200 || status === 204) {
      log('info', 'temporary key deleted');
      return;
    }
    log('warn', 'delete failed; expiry fallback');
  } catch {
    log('warn', 'delete failed; expiry fallback');
  }
}

async function cleanupOpenAiCredential() {
  // Remove the inference-capable service account first. Even if cleanup is
  // interrupted, the disposable project retains its hard spend limit, exact
  // model allowlist, and hosted-tool deny policy as provider-side fallbacks.
  upstreamCredential = null;

  if (openAiProjectId && openAiServiceAccountId) {
    try {
      const result = await openAiAdminFetch(
        'DELETE',
        `/organization/projects/${openAiProjectId}/service_accounts/${openAiServiceAccountId}`,
      );
      if (isSuccessStatus(result.status)) log('info', 'ephemeral OpenAI service account deleted');
      else log('warn', 'OpenAI service-account delete failed; project hard limit remains');
    } catch {
      log('warn', 'OpenAI service-account delete failed; project hard limit remains');
    }
  }

  if (openAiProjectId) {
    try {
      const result = await openAiAdminFetch('POST', `/organization/projects/${openAiProjectId}/archive`, null);
      if (isSuccessStatus(result.status) && result.body?.status === 'archived') {
        log('info', 'ephemeral OpenAI project archived');
      } else {
        log('warn', 'OpenAI project archive failed; hard limit remains');
      }
    } catch {
      log('warn', 'OpenAI project archive failed; hard limit remains');
    }
  }
}

async function cleanupProviderCredential() {
  if (cleanedUp) return;
  cleanedUp = true;
  if (PROVIDER === 'openai') await cleanupOpenAiCredential();
  else await cleanupOpenRouterCredential();
  upstreamCredential = null;
}

function parseBearer(auth) {
  if (!auth) return null;
  const m = auth.match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : null;
}

function requestUrl(req) {
  try {
    return new URL(req.url || '/', 'http://broker.local');
  } catch {
    return null;
  }
}

function isAllowedPathAndMethod(method, pathname) {
  if (PROVIDER === 'openrouter') {
    return method === 'POST' && pathname === '/api/v1/chat/completions';
  }
  return pathname === '/v1/responses' && (method === 'GET' || method === 'POST');
}

function normalizeModel(model) {
  if (!model) return '';
  if (PROVIDER === 'openrouter') return model.replace(/^openrouter\//, '');
  return String(model);
}

function buildUpstreamHeaders(reqHeaders) {
  const allowlist = new Set([
    'content-type',
    'accept',
    'accept-encoding',
    'user-agent',
    'originator',
    'version',
  ]);
  const blocked = new Set([
    'authorization', 'proxy-authorization', 'proxy-authenticate',
    'www-authenticate', 'x-forwarded-for', 'x-forwarded-proto',
    'x-forwarded-host', 'forwarded', 'via', 'x-real-ip',
    'cookie', 'set-cookie', 'x-api-key', 'api-key',
    'openai-organization', 'openai-project',
  ]);
  const result = {};
  for (const [k, v] of Object.entries(reqHeaders)) {
    const lk = k.toLowerCase();
    if (blocked.has(lk)) continue;
    if (allowlist.has(lk)) result[k] = v;
  }
  return result;
}

function providerBaseUrl() {
  return PROVIDER === 'openai' ? OPENAI_PROVIDER_API_URL : OPENROUTER_PROVIDER_API_URL;
}

function validateOpenAiRequestShape(parsedBody, res) {
  if (parsedBody?.stream !== true) {
    failJson(res, 400, 'BROKER_STREAM_REQUIRED', 'Codex OpenAI broker requires stream=true');
    return false;
  }
  if (parsedBody?.store !== false) {
    failJson(res, 400, 'BROKER_STORE_FORBIDDEN', 'Codex OpenAI broker requires store=false');
    return false;
  }
  if (parsedBody?.background === true) {
    failJson(res, 400, 'BROKER_BACKGROUND_FORBIDDEN', 'background responses are not allowed');
    return false;
  }
  return true;
}

async function readRequestBody(req, res) {
  const chunks = [];
  let bodyBytes = 0;
  for await (const chunk of req) {
    bodyBytes += chunk.length;
    if (bodyBytes > maxBodyBytes) {
      failJson(res, 413, 'BROKER_PAYLOAD_TOO_LARGE', `payload exceeds ${maxBodyBytes} bytes`);
      return null;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function handleProxy(req, res) {
  if (cleanedUp) {
    failJson(res, 503, 'BROKER_CLOSED', 'broker has shut down');
    return;
  }
  const bearer = parseBearer(req.headers.authorization);
  if (!bearer || bearer !== CAPABILITY) {
    failJson(res, 401, 'BROKER_AUTH_INVALID', 'invalid or missing capability');
    return;
  }
  if (Date.now() > capabilityExpiresAt) {
    failJson(res, 401, 'BROKER_CAPABILITY_EXPIRED', 'capability expired');
    return;
  }
  if (requestCount >= CAPABILITY_MAX_REQUESTS) {
    failJson(res, 429, 'BROKER_REQUEST_LIMIT', 'request count exhaustion');
    return;
  }
  if (concurrentCount > 0) {
    failJson(res, 429, 'BROKER_CONCURRENCY_VIOLATION', 'max concurrency 1');
    return;
  }
  if (!upstreamCredential) {
    failJson(res, 503, 'BROKER_NOT_PROVISIONED', 'no upstream credential');
    return;
  }

  const url = requestUrl(req);
  if (!url || url.search) {
    failJson(res, 403, 'BROKER_PATH_DENIED', 'query parameters and malformed paths are not allowed');
    return;
  }
  if (!isAllowedPathAndMethod(req.method, url.pathname)) {
    failJson(res, 403, 'BROKER_PATH_DENIED', `unsupported ${req.method} ${url.pathname}`);
    return;
  }

  // Codex 0.147.0 first attempts Responses-over-WebSocket with an authenticated
  // GET /v1/responses. B2a proved that HTTP 426 makes Codex immediately and
  // stickily fall back to the observed HTTP/SSE POST contract. Do not proxy the
  // WebSocket handshake or expose the upstream credential on this request.
  if (PROVIDER === 'openai' && req.method === 'GET' && url.pathname === '/v1/responses') {
    requestCount++;
    failJson(res, 426, 'BROKER_WEBSOCKET_UNSUPPORTED', 'use HTTP Responses streaming', { Connection: 'close' });
    return;
  }

  const body = await readRequestBody(req, res);
  if (body === null) return;

  let parsedBody = null;
  if (body && req.method === 'POST') {
    try {
      parsedBody = JSON.parse(body);
    } catch {
      failJson(res, 400, 'BROKER_MALFORMED_PAYLOAD', 'invalid JSON');
      return;
    }
    if (!parsedBody?.model) {
      failJson(res, 400, 'BROKER_MODEL_REQUIRED', 'model field is required in request body');
      return;
    }
    const normalized = normalizeModel(parsedBody.model);
    const allowed = normalizeModel(CAPABILITY_MODEL);
    if (normalized !== allowed) {
      failJson(res, 403, 'BROKER_MODEL_MISMATCH', `model ${parsedBody.model} not allowed`);
      return;
    }
    if (PROVIDER === 'openai' && !validateOpenAiRequestShape(parsedBody, res)) return;
  }

  requestCount++;
  concurrentCount++;

  const upstreamHeaders = buildUpstreamHeaders(req.headers);
  upstreamHeaders.Authorization = `Bearer ${upstreamCredential}`;
  if (!upstreamHeaders['Content-Type'] && !upstreamHeaders['content-type']) {
    upstreamHeaders['Content-Type'] = 'application/json';
  }
  if (PROVIDER === 'openai' && openAiProjectId) {
    upstreamHeaders['OpenAI-Project'] = openAiProjectId;
  }

  const upstreamUrl = `${providerBaseUrl()}${url.pathname}`;
  const isStreaming = parsedBody?.stream === true;

  try {
    const fetchOpts = { method: req.method, headers: upstreamHeaders };
    if (body) fetchOpts.body = body;
    if (ProxyAgent) fetchOpts.dispatcher = new ProxyAgent(PROXY_URL);

    const upstreamRes = await fetch(upstreamUrl, fetchOpts);

    if (isStreaming) {
      const headers = { 'Content-Type': upstreamRes.headers.get('content-type') || 'application/json' };
      res.writeHead(upstreamRes.status, headers);
      if (upstreamRes.body) {
        for await (const chunk of upstreamRes.body) res.write(chunk);
      }
      res.end();
    } else {
      const text = await upstreamRes.text();
      res.writeHead(upstreamRes.status, {
        'Content-Type': upstreamRes.headers.get('content-type') || 'application/json',
        'Content-Length': Buffer.byteLength(text),
      });
      res.end(text);
    }
  } catch (err) {
    failJson(res, 502, 'BROKER_UPSTREAM_FAILED', `upstream error: ${err.message}`);
  } finally {
    concurrentCount--;
  }
}

function handleHealth(_req, res) {
  const info = JSON.stringify({ status: 'ok' });
  res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(info) });
  res.end(info);
}

const server = http.createServer((req, res) => {
  const url = requestUrl(req);
  if (url?.pathname === '/health' && !url.search && req.method === 'GET') {
    handleHealth(req, res);
    return;
  }
  handleProxy(req, res);
});

async function start() {
  validateConfiguration();
  capabilityExpiresAt = Date.now() + CAPABILITY_EXPIRY_MS;
  await provisionProviderCredential();

  server.listen(PORT, '0.0.0.0', () => {
    log('info', `provider=${PROVIDER} listening on ${PORT}`);
  });

  const cleanupTimer = setInterval(() => {
    if (Date.now() > capabilityExpiresAt && !cleanedUp) cleanupProviderCredential().catch(() => {});
  }, 60000);

  const shutdown = async () => {
    clearInterval(cleanupTimer);
    await cleanupProviderCredential();
    server.close(() => process.exit(0));
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

start().catch(async (err) => {
  try {
    await cleanupProviderCredential();
  } catch {
    // Best effort only; provider-side hard limit remains on any created project.
  }
  log('error', `fatal: ${err.message}`);
  process.exit(1);
});
