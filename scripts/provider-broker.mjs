#!/usr/bin/env node
import crypto from 'node:crypto';
import http from 'node:http';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const PORT = parseInt(process.env.BROKER_PORT || '3080', 10);
const MANAGEMENT_KEY = process.env.OPENROUTER_MANAGEMENT_KEY || '';
const MANAGEMENT_API_URL = process.env.OPENROUTER_MANAGEMENT_API_URL || 'https://openrouter.ai/api/v1/keys';
const PROVIDER_API_BASE_URL = process.env.OPENROUTER_PROVIDER_API_URL || 'https://openrouter.ai';
const CAPABILITY = process.env.BROKER_CAPABILITY || '';
const CAPABILITY_TASK_ID = process.env.BROKER_TASK_ID || '';
const CAPABILITY_MODEL = process.env.BROKER_ALLOWED_MODEL || '';
const CAPABILITY_EXPIRY_MS = parseInt(process.env.BROKER_CAPABILITY_EXPIRY_MS || '3600000', 10);
const CAPABILITY_MAX_REQUESTS = parseInt(process.env.BROKER_MAX_REQUESTS || '500', 10);
const CAPABILITY_JOB_MAX_USD = parseFloat(process.env.BROKER_JOB_MAX_USD || '0.25');
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

let provisionedKey = null;
let provisionedKeyHash = null;
let provisionedKeyExpiresAt = null;
let requestCount = 0;
let concurrentCount = 0;
const capabilityExpiresAt = Date.now() + CAPABILITY_EXPIRY_MS;
let cleanedUp = false;

function log(level, msg) {
  const ts = new Date().toISOString();
  process.stderr.write(`[${ts}] [${level}] [broker] ${msg}\n`);
}

function failJson(res, status, code, detail) {
  const body = JSON.stringify({ error: { code, message: detail } });
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

async function managementFetch(method, path, body) {
  const url = `${MANAGEMENT_API_URL}${path}`;
  const headers = { Authorization: `Bearer ${MANAGEMENT_KEY}`, 'Content-Type': 'application/json' };
  const opts = { method, headers };
  if (body) opts.body = JSON.stringify(body);
  if (ProxyAgent) opts.dispatcher = new ProxyAgent(PROXY_URL);
  const response = await fetch(url, opts);
  if (response.status === 204) {
    return { status: response.status, body: null };
  }
  const resBody = await response.json();
  return { status: response.status, body: resBody };
}

async function provisionTemporaryKey() {
  const now = new Date();
  const expiresAt = new Date(now.getTime() + CAPABILITY_EXPIRY_MS + 300000);
  const safeName = `broker-${(CAPABILITY_TASK_ID || 'unknown').replace(/[^a-zA-Z0-9_-]/g, '')}-${now.getTime()}`.substring(0, 64);
  const payload = {
    name: safeName,
    limit: CAPABILITY_JOB_MAX_USD,
    limit_reset: null,
    expires_at: expiresAt.toISOString(),
  };
  const { status, body } = await managementFetch('POST', '', payload);
  if (status !== 201 || !body?.key) {
    throw new Error(`provisioning failed: HTTP ${status}`);
  }
  provisionedKey = body.key;
  provisionedKeyHash = body?.data?.hash || null;
  provisionedKeyExpiresAt = expiresAt;
  log('info', 'temporary key provisioned');
}

async function deleteTemporaryKey() {
  if (!provisionedKeyHash || cleanedUp) return;
  cleanedUp = true;
  try {
    const { status } = await managementFetch('DELETE', `/${provisionedKeyHash}`);
    if (status === 200 || status === 204) {
      log('info', 'temporary key deleted');
      return;
    }
    log('warn', 'delete failed; expiry fallback');
  } catch (err) {
    log('warn', 'delete failed; expiry fallback');
  }
}

function parseBearer(auth) {
  if (!auth) return null;
  const m = auth.match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : null;
}

function isAllowedPathAndMethod(method, path) {
  if (!path) return false;
  if (method === 'POST' && path === '/api/v1/chat/completions') return true;
  if (method === 'GET' && (path === '/api/v1/models' || path.match(/^\/api\/v1\/models\/(.+)$/))) return true;
  return false;
}

function normalizeModel(model) {
  if (!model) return '';
  return model.replace(/^openrouter\//, '');
}

function buildUpstreamHeaders(reqHeaders) {
  const allowlist = new Set([
    'content-type',
    'accept',
    'accept-encoding',
    'user-agent',
  ]);
  const blocked = new Set([
    'authorization', 'proxy-authorization', 'proxy-authenticate',
    'www-authenticate', 'x-forwarded-for', 'x-forwarded-proto',
    'x-forwarded-host', 'forwarded', 'via', 'x-real-ip',
    'cookie', 'set-cookie', 'x-api-key', 'api-key',
  ]);
  const result = {};
  for (const [k, v] of Object.entries(reqHeaders)) {
    const lk = k.toLowerCase();
    if (blocked.has(lk)) continue;
    if (allowlist.has(lk)) {
      result[k] = v;
    }
  }
  return result;
}

async function handleProxy(req, res) {
  if (cleanedUp) {
    failJson(res, 503, 'BROKER_CLOSED', 'broker has shut down');
    return;
  }
  const bearer = parseBearer(req.headers['authorization']);
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
  if (!provisionedKey) {
    failJson(res, 503, 'BROKER_NOT_PROVISIONED', 'no temporary key');
    return;
  }

  const urlPath = req.url || '/';
  if (!isAllowedPathAndMethod(req.method, urlPath)) {
    failJson(res, 403, 'BROKER_PATH_DENIED', `unsupported ${req.method} ${urlPath}`);
    return;
  }

  let body = '';
  const maxBodyBytes = 256 * 1024;
  let bodyBytes = 0;
  for await (const chunk of req) {
    bodyBytes += chunk.length;
    if (bodyBytes > maxBodyBytes) {
      failJson(res, 413, 'BROKER_PAYLOAD_TOO_LARGE', 'payload exceeds 256KB');
      return;
    }
    body += chunk.toString();
  }

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
  }

  requestCount++;
  concurrentCount++;

  const upstreamHeaders = buildUpstreamHeaders(req.headers);
  upstreamHeaders['Authorization'] = `Bearer ${provisionedKey}`;
  if (!upstreamHeaders['Content-Type']) {
    upstreamHeaders['Content-Type'] = 'application/json';
  }

  const upstreamUrl = `${PROVIDER_API_BASE_URL}${urlPath}`;
  const isStreaming = parsedBody?.stream === true;

  try {
    const fetchOpts = { method: req.method, headers: upstreamHeaders };
    if (body) fetchOpts.body = body;
    if (ProxyAgent) {
      fetchOpts.dispatcher = new ProxyAgent(PROXY_URL);
    }

    const upstreamRes = await fetch(upstreamUrl, fetchOpts);

    if (isStreaming) {
      const headers = { 'Content-Type': upstreamRes.headers.get('content-type') || 'application/json' };
      if (upstreamRes.headers.get('transfer-encoding')) headers['Transfer-Encoding'] = 'chunked';
      res.writeHead(upstreamRes.status, headers);
      for await (const chunk of upstreamRes.body) {
        res.write(chunk);
      }
      res.end();
    } else {
      const data = await upstreamRes.json();
      const resp = JSON.stringify(data);
      res.writeHead(upstreamRes.status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(resp) });
      res.end(resp);
    }
  } catch (err) {
    failJson(res, 502, 'BROKER_UPSTREAM_FAILED', `upstream error: ${err.message}`);
  } finally {
    concurrentCount--;
  }
}

function handleHealth(req, res) {
  const info = JSON.stringify({
    status: 'ok',
    provisioned: !!provisionedKey,
    requestCount,
    concurrentCount,
  });
  res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(info) });
  res.end(info);
}

const server = http.createServer((req, res) => {
  const urlPath = req.url || '/';
  if (urlPath === '/health' && req.method === 'GET') {
    handleHealth(req, res);
    return;
  }
  handleProxy(req, res);
});

async function start() {
  if (!MANAGEMENT_KEY) { log('error', 'OPENROUTER_MANAGEMENT_KEY required'); process.exit(1); }
  if (!CAPABILITY) { log('error', 'BROKER_CAPABILITY required'); process.exit(1); }
  if (!CAPABILITY_MODEL) { log('error', 'BROKER_ALLOWED_MODEL required'); process.exit(1); }

  await provisionTemporaryKey();

  server.listen(PORT, '0.0.0.0', () => {
    log('info', `listening on ${PORT}`);
  });

  const cleanupTimer = setInterval(() => {
    if (Date.now() > capabilityExpiresAt && !cleanedUp) {
      deleteTemporaryKey().catch(() => {});
    }
  }, 60000);

  const shutdown = async () => {
    clearInterval(cleanupTimer);
    await deleteTemporaryKey();
    server.close(() => process.exit(0));
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

start().catch(err => {
  log('error', `fatal: ${err.message}`);
  process.exit(1);
});