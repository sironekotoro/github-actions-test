#!/usr/bin/env node
import http from 'node:http';
import { createRequire } from 'node:module';
import {
  DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST,
  PRICING_VERSION,
  SUPPORTED_MODEL,
  assertSupportedAnthropicShape,
  buildCountTokensBody,
  reserveAnthropicRequest,
  usdToMicroUsd,
} from './lib/anthropic-spend-guard.mjs';

const require = createRequire(import.meta.url);
const PORT = Number.parseInt(process.env.BROKER_PORT || '3080', 10);
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';
const ANTHROPIC_PROVIDER_API_URL = process.env.ANTHROPIC_PROVIDER_API_URL || 'https://api.anthropic.com';
const ANTHROPIC_LIVE_ALLOWED = process.env.BROKER_ANTHROPIC_LIVE_ALLOWED === 'true';
const SPEND_GUARD_ENABLED = process.env.BROKER_ANTHROPIC_SPEND_GUARD_ENABLED === 'true';
const CAPABILITY = process.env.BROKER_CAPABILITY || '';
const CAPABILITY_TASK_ID = process.env.BROKER_TASK_ID || '';
const CAPABILITY_MODEL = process.env.BROKER_ALLOWED_MODEL || '';
const CAPABILITY_EXPIRY_MS = Number.parseInt(process.env.BROKER_CAPABILITY_EXPIRY_MS || '', 10);
const CAPABILITY_MAX_REQUESTS = Number.parseInt(process.env.BROKER_MAX_REQUESTS || '500', 10);
const JOB_MAX_USD_RAW = String(process.env.BROKER_JOB_MAX_USD || '0.25').trim();
const MAX_OUTPUT_RAW = String(process.env.BROKER_ANTHROPIC_MAX_OUTPUT_TOKENS_PER_REQUEST || '').trim();
const BODY_LIMIT_RAW = String(process.env.BROKER_MAX_BODY_BYTES || '').trim();
const PROXY_URL = process.env.BROKER_PROXY_URL || '';
const ANTHROPIC_VERSION = '2023-06-01';
const ANTHROPIC_BETA_FEATURES = Object.freeze([
  'claude-code-20250219',
  'context-management-2025-06-27',
  'effort-2025-11-24',
]);
const REQUIRED_ANTHROPIC_BETA_FEATURES = Object.freeze([
  'claude-code-20250219',
  'effort-2025-11-24',
]);

let ProxyAgent = null;
if (PROXY_URL) {
  try { ProxyAgent = require('undici').ProxyAgent; }
  catch { process.stderr.write('[broker] undici not available for proxy support\n'); process.exit(1); }
}

let requestCount = 0;
let concurrentCount = 0;
let capabilityExpiresAt = 0;
let maxBodyBytes = 0;
let maxOutputTokensPerRequest = DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST;
let remainingMicroUsd = 0;
let closed = false;

function log(level, message) {
  process.stderr.write(`[${new Date().toISOString()}] [${level}] [anthropic-broker] ${message}\n`);
}

function failJson(res, status, code, message) {
  const body = JSON.stringify({ error: { code, message } });
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function validPositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function isLoopbackProviderUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'http:' && ['127.0.0.1', 'localhost', '::1'].includes(url.hostname);
  } catch { return false; }
}

function validateConfiguration() {
  if (!validPositiveInteger(PORT) || PORT > 65535) throw new Error('BROKER_PORT invalid');
  if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY required');
  if (!CAPABILITY) throw new Error('BROKER_CAPABILITY required');
  if (!CAPABILITY_TASK_ID) throw new Error('BROKER_TASK_ID required');
  if (!CAPABILITY_MODEL) throw new Error('BROKER_ALLOWED_MODEL required');
  if (!validPositiveInteger(CAPABILITY_EXPIRY_MS)) throw new Error('BROKER_CAPABILITY_EXPIRY_MS invalid');
  if (!validPositiveInteger(CAPABILITY_MAX_REQUESTS)) throw new Error('BROKER_MAX_REQUESTS invalid');

  if (SPEND_GUARD_ENABLED) {
    if (CAPABILITY_MODEL !== SUPPORTED_MODEL) throw new Error(`Anthropic spend guard supports only ${SUPPORTED_MODEL}`);
    remainingMicroUsd = usdToMicroUsd(JOB_MAX_USD_RAW);
    if (!validPositiveInteger(remainingMicroUsd)) throw new Error('BROKER_JOB_MAX_USD invalid');
    if (MAX_OUTPUT_RAW) {
      const configured = Number.parseInt(MAX_OUTPUT_RAW, 10);
      if (!validPositiveInteger(configured) || String(configured) !== MAX_OUTPUT_RAW || configured > 32000) {
        throw new Error('BROKER_ANTHROPIC_MAX_OUTPUT_TOKENS_PER_REQUEST invalid');
      }
      maxOutputTokensPerRequest = configured;
    }
  }

  if (!isLoopbackProviderUrl(ANTHROPIC_PROVIDER_API_URL)) {
    if (!ANTHROPIC_LIVE_ALLOWED) throw new Error('Anthropic live forwarding disabled until trusted per-job spend enforcement is wired');
    if (!SPEND_GUARD_ENABLED) throw new Error('Anthropic live forwarding requires spend guard enforcement');
  }

  if (BODY_LIMIT_RAW) {
    const configured = Number.parseInt(BODY_LIMIT_RAW, 10);
    if (!validPositiveInteger(configured) || String(configured) !== BODY_LIMIT_RAW || configured > 8 * 1024 * 1024) {
      throw new Error('BROKER_MAX_BODY_BYTES invalid');
    }
    maxBodyBytes = configured;
  } else {
    maxBodyBytes = 4 * 1024 * 1024;
  }
}

function requestUrl(req) {
  try { return new URL(req.url || '/', 'http://broker.local'); }
  catch { return null; }
}

function buildUpstreamHeaders(reqHeaders) {
  const allowed = new Set(['accept', 'accept-encoding', 'user-agent']);
  const blocked = new Set([
    'authorization', 'x-api-key', 'api-key', 'proxy-authorization', 'proxy-authenticate',
    'www-authenticate', 'x-forwarded-for', 'x-forwarded-proto', 'x-forwarded-host',
    'forwarded', 'via', 'x-real-ip', 'cookie', 'set-cookie',
  ]);
  const result = {};
  for (const [key, value] of Object.entries(reqHeaders)) {
    const lower = key.toLowerCase();
    if (blocked.has(lower)) continue;
    if (allowed.has(lower)) result[key] = value;
  }
  return result;
}

function trustedAnthropicHeaders(reqHeaders) {
  const headers = buildUpstreamHeaders(reqHeaders);
  headers['x-api-key'] = ANTHROPIC_API_KEY;
  headers['anthropic-version'] = ANTHROPIC_VERSION;
  headers['anthropic-beta'] = normalizedAnthropicBeta(reqHeaders['anthropic-beta']);
  headers['content-type'] = 'application/json';
  return headers;
}

function normalizedAnthropicBeta(value) {
  if (typeof value !== 'string') return '';
  const requested = new Set(value.split(',').map((part) => part.trim()));
  return ANTHROPIC_BETA_FEATURES.filter((feature) => requested.has(feature)).join(',');
}

function hasSupportedBetaContract(value) {
  if (typeof value !== 'string') return false;
  const features = value.split(',').map((part) => part.trim());
  const unique = new Set(features);
  return features.length === unique.size
    && features.every((feature) => ANTHROPIC_BETA_FEATURES.includes(feature))
    && REQUIRED_ANTHROPIC_BETA_FEATURES.every((feature) => unique.has(feature));
}

function validateAnthropicHeaders(req, res) {
  if (req.headers['anthropic-version'] !== ANTHROPIC_VERSION || !hasSupportedBetaContract(req.headers['anthropic-beta'])) {
    failJson(res, 400, 'BROKER_ANTHROPIC_HEADERS_DENIED', 'request headers are outside the pinned Anthropic contract');
    return false;
  }
  return true;
}

async function providerFetch(path, headers, body) {
  const opts = { method: 'POST', headers, body: JSON.stringify(body) };
  if (ProxyAgent) opts.dispatcher = new ProxyAgent(PROXY_URL);
  return fetch(`${ANTHROPIC_PROVIDER_API_URL}${path}`, opts);
}

async function countInputTokens(parsed, reqHeaders) {
  const countBody = buildCountTokensBody(parsed);
  const upstream = await providerFetch('/v1/messages/count_tokens?beta=true', trustedAnthropicHeaders(reqHeaders), countBody);
  const text = await upstream.text();
  let result = null;
  try { result = text ? JSON.parse(text) : null; } catch {}
  if (upstream.status < 200 || upstream.status >= 300 || !Number.isSafeInteger(result?.input_tokens) || result.input_tokens < 0) {
    throw new Error(`token count unavailable: HTTP ${upstream.status}`);
  }
  return result.input_tokens;
}

async function readBody(req, res) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > maxBodyBytes) {
      failJson(res, 413, 'BROKER_PAYLOAD_TOO_LARGE', `payload exceeds ${maxBodyBytes} bytes`);
      return null;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

function validateRequestShape(parsed, res) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    failJson(res, 400, 'BROKER_MALFORMED_PAYLOAD', 'JSON object required');
    return false;
  }
  if (!parsed.model) {
    failJson(res, 400, 'BROKER_MODEL_REQUIRED', 'model field is required');
    return false;
  }
  if (String(parsed.model) !== CAPABILITY_MODEL) {
    failJson(res, 403, 'BROKER_MODEL_MISMATCH', `model ${parsed.model} not allowed`);
    return false;
  }
  if (parsed.stream !== true) {
    failJson(res, 400, 'BROKER_STREAM_REQUIRED', 'Claude broker requires stream=true');
    return false;
  }
  if (!validPositiveInteger(parsed.max_tokens) || parsed.max_tokens > 32000) {
    failJson(res, 400, 'BROKER_MAX_TOKENS_INVALID', 'max_tokens must be an integer from 1 to 32000');
    return false;
  }
  return true;
}

async function handleMessages(req, res, url) {
  if (closed) return failJson(res, 503, 'BROKER_CLOSED', 'broker has shut down');
  if (req.headers['x-api-key'] !== CAPABILITY) return failJson(res, 401, 'BROKER_AUTH_INVALID', 'invalid or missing capability');
  if (Date.now() > capabilityExpiresAt) return failJson(res, 401, 'BROKER_CAPABILITY_EXPIRED', 'capability expired');
  if (requestCount >= CAPABILITY_MAX_REQUESTS) return failJson(res, 429, 'BROKER_REQUEST_LIMIT', 'request count exhaustion');
  if (concurrentCount > 0) return failJson(res, 429, 'BROKER_CONCURRENCY_VIOLATION', 'max concurrency 1');
  if (req.method !== 'POST' || url.pathname !== '/v1/messages' || url.search !== '?beta=true') {
    return failJson(res, 403, 'BROKER_PATH_DENIED', `unsupported ${req.method} ${url.pathname}${url.search}`);
  }
  // Acquire the single request slot before the first await. Otherwise two
  // slow request bodies can both pass the concurrency check and race the
  // in-memory spend reservation.
  concurrentCount++;
  try {
    const body = await readBody(req, res);
    if (body === null) return;
    let parsed;
    try { parsed = JSON.parse(body); }
    catch { return failJson(res, 400, 'BROKER_MALFORMED_PAYLOAD', 'invalid JSON'); }
    if (!validateRequestShape(parsed, res)) return;
    if (SPEND_GUARD_ENABLED) {
      try { assertSupportedAnthropicShape(parsed); }
      catch { return failJson(res, 400, 'BROKER_SPEND_SHAPE_DENIED', 'request shape is not covered by Anthropic spend policy'); }
    }
    if (!validateAnthropicHeaders(req, res)) return;

    requestCount++;
    let forwardedBody = parsed;
    if (SPEND_GUARD_ENABLED) {
      let estimatedInputTokens;
      try {
        estimatedInputTokens = await countInputTokens(parsed, req.headers);
      } catch {
        return failJson(res, 502, 'BROKER_TOKEN_COUNT_FAILED', 'Anthropic token count failed closed');
      }
      if (Date.now() > capabilityExpiresAt) {
        return failJson(res, 401, 'BROKER_CAPABILITY_EXPIRED', 'capability expired before cost-bearing request');
      }

      const reservation = reserveAnthropicRequest({
        body: parsed,
        estimatedInputTokens,
        remainingMicroUsd,
        maxOutputTokensPerRequest,
      });
      if (!reservation.allowed) {
        return failJson(res, 402, reservation.reason, 'Anthropic job allowance exhausted');
      }

      // Reserve before the cost-bearing Messages call and deliberately never
      // release unused reservation. This keeps accounting monotonic and makes
      // every broker-authorized request fit inside the configured job allowance.
      remainingMicroUsd = reservation.remainingAfterReservationMicroUsd;
      forwardedBody = reservation.rewrittenBody;
      log('info', `spend reservation pricing=${PRICING_VERSION} reserved_micro_usd=${reservation.reservedMicroUsd} remaining_micro_usd=${remainingMicroUsd} max_tokens=${reservation.outputTokens}`);
    }

    const upstream = await providerFetch('/v1/messages?beta=true', trustedAnthropicHeaders(req.headers), forwardedBody);
    res.writeHead(upstream.status, { 'Content-Type': upstream.headers.get('content-type') || 'application/json' });
    if (upstream.body) for await (const chunk of upstream.body) res.write(chunk);
    res.end();
  } catch {
    // A streaming failure can happen after response headers were sent. Retain
    // the full reservation and terminate that response without attempting a
    // second writeHead; the broker stays alive for controlled cleanup.
    if (res.headersSent) res.destroy();
    else failJson(res, 502, 'BROKER_UPSTREAM_FAILED', 'Anthropic upstream request failed');
  } finally {
    concurrentCount--;
  }
}

function handleHeadRoot(req, res, url) {
  if (req.method === 'HEAD' && url.pathname === '/' && !url.search) {
    res.writeHead(200, { Connection: 'close' });
    res.end();
    return true;
  }
  return false;
}

function handleHealth(req, res, url) {
  if (req.method === 'GET' && url.pathname === '/health' && !url.search) {
    const body = JSON.stringify({ status: 'ok' });
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
    return true;
  }
  return false;
}

const server = http.createServer((req, res) => {
  const url = requestUrl(req);
  if (!url) return failJson(res, 403, 'BROKER_PATH_DENIED', 'malformed path');
  if (handleHealth(req, res, url) || handleHeadRoot(req, res, url)) return;
  handleMessages(req, res, url);
});

async function shutdown(signal) {
  if (closed) return;
  closed = true;
  log('info', `shutdown requested: ${signal}`);
  await new Promise((resolve) => server.close(resolve));
  process.exit(0);
}

try {
  validateConfiguration();
  capabilityExpiresAt = Date.now() + CAPABILITY_EXPIRY_MS;
  server.listen(PORT, '0.0.0.0', () => log('info', `listening on ${PORT}; live=${ANTHROPIC_LIVE_ALLOWED}; spend_guard=${SPEND_GUARD_ENABLED}`));
} catch (error) {
  log('error', `startup failed: ${error.message}`);
  process.exit(1);
}

process.on('SIGTERM', () => { shutdown('SIGTERM'); });
process.on('SIGINT', () => { shutdown('SIGINT'); });
