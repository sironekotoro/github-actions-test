// Conservative broker-side Anthropic list-price reservation math.
//
// This module performs no network access. B3c deliberately proves the
// accounting invariant with local tests before it is wired into the live
// broker. Prices are represented in integer micro-USD to avoid floating-point
// under-reservation.

export const PRICING_VERSION = '2026-09-02';
export const SUPPORTED_MODEL = 'claude-sonnet-5';

// Claude Sonnet 5 standard pricing on 2026-09-02:
// base input $2/MTok; 5m cache write $2.50/MTok; 1h cache write $4/MTok;
// cache hit $0.20/MTok; output $10/MTok.
// Reserve every estimated input token at the highest input/cache-write rate
// ($4/MTok) so cache placement cannot make an admitted request more expensive
// than the broker reservation solely because of the input token class.
export const INPUT_MICRO_USD_PER_TOKEN = 4;
export const OUTPUT_MICRO_USD_PER_TOKEN = 10;

// Token Counting is documented as an estimate. This margin is intentionally
// conservative, but it is not represented as a provider-enforced monetary
// guarantee. It exists to make the software admission policy monotonic toward
// over-reservation.
export const INPUT_SAFETY_BPS = 11000; // 110%
export const INPUT_FIXED_MARGIN_TOKENS = 1024;
export const DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST = 4096;

export function usdToMicroUsd(value) {
  const raw = String(value ?? '').trim();
  if (!/^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,6})?$/.test(raw)) {
    throw new Error('USD amount must be a non-negative decimal with at most 6 places');
  }
  const [whole, fraction = ''] = raw.split('.');
  const micros = (BigInt(whole) * 1000000n) + BigInt((fraction + '000000').slice(0, 6));
  if (micros > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('USD amount too large');
  return Number(micros);
}

export function assertSupportedAnthropicShape(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('request body must be an object');
  if (body.model !== SUPPORTED_MODEL) throw new Error('unsupported Anthropic pricing model');
  if (body.stream !== true) throw new Error('stream=true required');
  if (!Number.isSafeInteger(body.max_tokens) || body.max_tokens <= 0 || body.max_tokens > 32000) {
    throw new Error('invalid max_tokens');
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) throw new Error('messages required');

  // Fast mode and server-side tools have pricing surfaces beyond the simple
  // token table used by this first guard. Fail closed instead of guessing.
  if (body.speed !== undefined && body.speed !== null && body.speed !== 'standard') throw new Error('non-standard speed is not priced');
  if (Array.isArray(body.mcp_servers) && body.mcp_servers.length > 0) throw new Error('MCP servers are not priced');
  if (body.tool_configuration !== undefined && body.tool_configuration !== null) throw new Error('MCP tool configuration is not priced');

  if (Array.isArray(body.tools)) {
    for (const tool of body.tools) {
      if (!tool || typeof tool !== 'object' || Array.isArray(tool)) throw new Error('invalid tool definition');
      // B3a's Claude Code tools are ordinary client tools with a name and
      // input_schema. Anthropic server tools/toolsets carry a provider-defined
      // `type`; reject those until their separate prices are modeled.
      if (typeof tool.type === 'string' && tool.type.length > 0) throw new Error('server/toolset pricing is not modeled');
      if (typeof tool.name !== 'string' || !tool.name) throw new Error('unnamed tool is not an allowed client tool');
    }
  }
  return true;
}

export function buildCountTokensBody(body) {
  assertSupportedAnthropicShape(body);
  const result = {};
  for (const key of [
    'model',
    'messages',
    'system',
    'tools',
    'thinking',
    'output_config',
    'context_management',
    'cache_control',
    'tool_choice',
  ]) {
    if (body[key] !== undefined) result[key] = body[key];
  }
  return result;
}

export function conservativeInputTokens(estimatedInputTokens) {
  if (!Number.isSafeInteger(estimatedInputTokens) || estimatedInputTokens < 0) {
    throw new Error('invalid token-count estimate');
  }
  const scaled = Math.ceil((estimatedInputTokens * INPUT_SAFETY_BPS) / 10000);
  const total = scaled + INPUT_FIXED_MARGIN_TOKENS;
  if (!Number.isSafeInteger(total)) throw new Error('input reservation overflow');
  return total;
}

export function reserveAnthropicRequest({
  body,
  estimatedInputTokens,
  remainingMicroUsd,
  maxOutputTokensPerRequest = DEFAULT_MAX_OUTPUT_TOKENS_PER_REQUEST,
}) {
  assertSupportedAnthropicShape(body);
  if (!Number.isSafeInteger(remainingMicroUsd) || remainingMicroUsd < 0) throw new Error('invalid remaining budget');
  if (!Number.isSafeInteger(maxOutputTokensPerRequest) || maxOutputTokensPerRequest <= 0 || maxOutputTokensPerRequest > 32000) {
    throw new Error('invalid per-request output ceiling');
  }

  const reservedInputTokens = conservativeInputTokens(estimatedInputTokens);
  const inputMicroUsd = reservedInputTokens * INPUT_MICRO_USD_PER_TOKEN;
  if (!Number.isSafeInteger(inputMicroUsd)) throw new Error('input cost overflow');
  if (inputMicroUsd >= remainingMicroUsd) {
    return { allowed: false, reason: 'ANTHROPIC_JOB_BUDGET_EXHAUSTED', inputMicroUsd, remainingMicroUsd };
  }

  const outputAffordable = Math.floor((remainingMicroUsd - inputMicroUsd) / OUTPUT_MICRO_USD_PER_TOKEN);
  const outputTokens = Math.min(body.max_tokens, maxOutputTokensPerRequest, outputAffordable);
  if (!Number.isSafeInteger(outputTokens) || outputTokens <= 0) {
    return { allowed: false, reason: 'ANTHROPIC_JOB_BUDGET_EXHAUSTED', inputMicroUsd, remainingMicroUsd };
  }

  const outputMicroUsd = outputTokens * OUTPUT_MICRO_USD_PER_TOKEN;
  const reservedMicroUsd = inputMicroUsd + outputMicroUsd;
  if (!Number.isSafeInteger(reservedMicroUsd) || reservedMicroUsd > remainingMicroUsd) {
    throw new Error('reservation invariant violated');
  }

  return {
    allowed: true,
    reason: '',
    reservedInputTokens,
    inputMicroUsd,
    outputTokens,
    outputMicroUsd,
    reservedMicroUsd,
    remainingAfterReservationMicroUsd: remainingMicroUsd - reservedMicroUsd,
    rewrittenBody: { ...body, max_tokens: outputTokens },
  };
}
