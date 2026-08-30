#!/usr/bin/env node
import fs from 'node:fs';

const outputFile = process.env.GITHUB_OUTPUT || '';
const outputs = new Map();

function clean(value) {
  return String(value ?? '').replace(/[\r\n\0]/g, ' ');
}

function emit(key, value) {
  outputs.set(key, clean(value));
}

function flush() {
  if (!outputFile) return;
  const body = [...outputs.entries()].map(([k, v]) => `${k}=${v}`).join('\n') + '\n';
  fs.appendFileSync(outputFile, body);
}

function enabled(name, fallback = false) {
  const value = String(process.env[name] ?? '').trim().toLowerCase();
  if (!value) return fallback;
  return value === 'true' || value === '1' || value === 'yes';
}

function money(name, fallback = null) {
  const raw = String(process.env[name] ?? '').trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative USD amount`);
  return value;
}

function usd(value) {
  if (!Number.isFinite(value)) return '';
  return Math.max(0, value).toFixed(6).replace(/0+$/, '').replace(/\.$/, '');
}

async function getJson(url, headers) {
  const response = await fetch(url, {
    headers,
    signal: AbortSignal.timeout(Number(process.env.BUDGET_PREFLIGHT_TIMEOUT_MS || 10000)),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

function decide(provider, available, source, hardFloor, warning, maxJob) {
  const safeAvailable = Math.max(0, available);
  const spendable = Math.max(0, safeAvailable - hardFloor);
  const jobCap = Math.min(maxJob, spendable);
  // Phase A cannot yet enforce a per-request spend cap inside the provider path.
  // Therefore do not start a paid job unless the full configured job allowance
  // is available *above* the protected floor. Phase B's broker will enforce the
  // cap authoritatively during inference.
  const reserveSatisfied = spendable >= maxJob;
  const blocked = safeAvailable <= hardFloor || !reserveSatisfied;
  const state = blocked ? 'blocked' : safeAvailable <= warning ? 'warning' : 'ok';
  emit('provider', provider);
  emit('state', state);
  emit('decision', blocked ? 'wait' : 'pass');
  emit('reason', blocked ? 'PROVIDER_BUDGET_LOW' : '');
  emit('source', source);
  emit('available_usd', usd(safeAvailable));
  emit('hard_floor_usd', usd(hardFloor));
  emit('warning_usd', usd(warning));
  emit('job_spendable_usd', usd(spendable));
  emit('job_cap_usd', usd(jobCap));
  emit('required_job_reserve_usd', usd(maxJob));
}

function unknown(provider, reason, hardFloor, warning, maxJob = 0) {
  emit('provider', provider);
  emit('state', 'unknown');
  emit('decision', 'wait');
  emit('reason', reason || 'PROVIDER_BUDGET_UNKNOWN');
  emit('source', 'unknown');
  emit('available_usd', '');
  emit('hard_floor_usd', usd(hardFloor));
  emit('warning_usd', usd(warning));
  emit('job_spendable_usd', '0');
  emit('job_cap_usd', '0');
  emit('required_job_reserve_usd', usd(maxJob));
}

async function openRouter(hardFloor, warning, maxJob) {
  const managementKey = process.env.OPENROUTER_MANAGEMENT_KEY || '';
  const inferenceKey = process.env.OPENROUTER_API_KEY || '';
  if (!managementKey || !inferenceKey) {
    unknown('openrouter', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
    return;
  }

  const creditsUrl = process.env.OPENROUTER_CREDITS_URL || 'https://openrouter.ai/api/v1/credits';
  const keyUrl = process.env.OPENROUTER_KEY_URL || 'https://openrouter.ai/api/v1/key';
  try {
    const [credits, key] = await Promise.all([
      getJson(creditsUrl, {Authorization: `Bearer ${managementKey}`}),
      getJson(keyUrl, {Authorization: `Bearer ${inferenceKey}`}),
    ]);
    const totalCredits = Number(credits?.data?.total_credits);
    const totalUsage = Number(credits?.data?.total_usage);
    if (!Number.isFinite(totalCredits) || !Number.isFinite(totalUsage)) throw new Error('invalid credits response');
    const accountRemaining = Math.max(0, totalCredits - totalUsage);

    const rawKeyRemaining = key?.data?.limit_remaining;
    const keyRemaining = rawKeyRemaining === null || rawKeyRemaining === undefined
      ? Number.POSITIVE_INFINITY
      : Number(rawKeyRemaining);
    if (!Number.isFinite(keyRemaining) && keyRemaining !== Number.POSITIVE_INFINITY) throw new Error('invalid key response');
    const available = Math.min(accountRemaining, Math.max(0, keyRemaining));
    decide('openrouter', available, Number.isFinite(keyRemaining) ? 'account-credits+key-limit' : 'account-credits', hardFloor, warning, maxJob);
  } catch {
    unknown('openrouter', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
  }
}

async function openAI(hardFloor, warning, maxJob) {
  const adminKey = process.env.OPENAI_ADMIN_KEY || '';
  let monthlyBudget;
  try {
    monthlyBudget = money('OPENAI_MONTHLY_BUDGET_USD');
  } catch {
    unknown('openai', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
    return;
  }
  if (!adminKey || monthlyBudget === null) {
    unknown('openai', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
    return;
  }

  const now = new Date();
  const start = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1) / 1000;
  const end = Math.floor(now.getTime() / 1000) + 1;
  const base = process.env.OPENAI_COSTS_URL || 'https://api.openai.com/v1/organization/costs';
  const url = new URL(base);
  url.searchParams.set('start_time', String(start));
  url.searchParams.set('end_time', String(end));
  url.searchParams.set('bucket_width', '1d');
  url.searchParams.set('limit', '31');

  try {
    const body = await getJson(url, {Authorization: `Bearer ${adminKey}`, 'Content-Type': 'application/json'});
    if (body?.has_more) throw new Error('unexpected pagination');
    let spent = 0;
    for (const bucket of body?.data || []) {
      for (const result of bucket?.results || []) {
        const currency = String(result?.amount?.currency || '').toLowerCase();
        const value = Number(result?.amount?.value);
        if (currency !== 'usd' || !Number.isFinite(value) || value < 0) throw new Error('invalid costs response');
        spent += value;
      }
    }
    decide('openai', Math.max(0, monthlyBudget - spent), 'configured-monthly-budget-minus-official-costs', hardFloor, warning, maxJob);
  } catch {
    unknown('openai', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
  }
}

async function main() {
  let hardFloor;
  let warning;
  let maxJob;
  try {
    hardFloor = money('PROVIDER_BALANCE_HARD_FLOOR_USD', 0.25);
    warning = money('PROVIDER_BALANCE_WARN_USD', 0.50);
    maxJob = money('PROVIDER_JOB_MAX_USD', 0.25);
    if (warning < hardFloor) throw new Error('warning threshold below hard floor');
  } catch {
    unknown('unknown', 'PROVIDER_BUDGET_UNKNOWN', 0.25, 0.50, 0.25);
    flush();
    return;
  }

  const agent = String(process.env.AGENT || '').trim();
  const provider = agent === 'opencode' ? 'openrouter' : agent === 'codex' ? 'openai' : agent === 'claude-code' ? 'anthropic' : 'unknown';

  if (!enabled('PROVIDER_BUDGET_GATE_ENABLED', false)) {
    emit('provider', provider);
    emit('state', 'disabled');
    emit('decision', 'pass');
    emit('reason', '');
    emit('source', 'disabled');
    emit('available_usd', '');
    emit('hard_floor_usd', usd(hardFloor));
    emit('warning_usd', usd(warning));
    emit('job_spendable_usd', '');
    emit('job_cap_usd', '');
    emit('required_job_reserve_usd', usd(maxJob));
    flush();
    return;
  }

  if (agent === 'opencode') await openRouter(hardFloor, warning, maxJob);
  else if (agent === 'codex') await openAI(hardFloor, warning, maxJob);
  else if (agent === 'claude-code') unknown('anthropic', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
  else unknown('unknown', 'PROVIDER_BUDGET_UNKNOWN', hardFloor, warning, maxJob);
  flush();
}

await main();
