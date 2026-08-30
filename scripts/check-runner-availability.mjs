#!/usr/bin/env node
import fs from 'node:fs';

const outputFile = process.env.GITHUB_OUTPUT || '';
const outputs = new Map();

function emit(key, value) {
  outputs.set(key, String(value ?? '').replace(/[\r\n\0]/g, ' '));
}
function flush() {
  if (!outputFile) return;
  fs.appendFileSync(outputFile, [...outputs.entries()].map(([k, v]) => `${k}=${v}`).join('\n') + '\n');
}
function bool(name, fallback = false) {
  const value = String(process.env[name] ?? '').trim().toLowerCase();
  if (!value) return fallback;
  return value === 'true' || value === '1' || value === 'yes';
}
function labelsFromEnv() {
  const raw = process.env.RUNNER_REQUIRED_LABELS || '';
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.some(v => typeof v !== 'string' || !v.trim())) {
    throw new Error('runner labels must be a non-empty JSON string array');
  }
  return parsed.map(v => v.trim());
}
function wait(state, reason, labels = []) {
  emit('decision', 'wait');
  emit('state', state);
  emit('reason', reason);
  emit('runner_labels', JSON.stringify(labels));
  emit('runner_name', '');
}
function run(state, labels, name = '') {
  emit('decision', 'run');
  emit('state', state);
  emit('reason', '');
  emit('runner_labels', JSON.stringify(labels));
  emit('runner_name', name);
}

async function main() {
  let labels;
  try {
    labels = labelsFromEnv();
  } catch {
    wait('unknown', 'RUNNER_STATUS_UNKNOWN');
    flush();
    return;
  }

  if (!bool('RUNNER_ROUTER_ENABLED', false)) {
    run('disabled', labels);
    flush();
    return;
  }

  const token = process.env.RUNNER_STATUS_TOKEN || '';
  const repository = process.env.GITHUB_REPOSITORY || '';
  if (!token || !/^[^/]+\/[^/]+$/.test(repository)) {
    wait('unknown', 'RUNNER_STATUS_UNKNOWN', labels);
    flush();
    return;
  }

  const [owner, repo] = repository.split('/');
  const base = (process.env.RUNNER_STATUS_API_BASE || 'https://api.github.com').replace(/\/$/, '');
  const url = `${base}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/runners?per_page=100`;
  try {
    const response = await fetch(url, {
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
      },
      signal: AbortSignal.timeout(Number(process.env.RUNNER_STATUS_TIMEOUT_MS || 10000)),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = await response.json();
    if (!Array.isArray(body?.runners)) throw new Error('invalid runner response');

    const required = new Set(labels.map(v => v.toLowerCase()));
    const compatible = body.runners.filter(runner => {
      const runnerLabels = new Set((runner?.labels || []).map(label => String(label?.name || '').toLowerCase()));
      return [...required].every(label => runnerLabels.has(label));
    });
    const online = compatible.filter(runner => runner?.status === 'online');
    const idle = online.find(runner => runner?.busy === false);
    if (idle) run('online-idle', labels, idle.name || '');
    else if (online.length > 0) run('online-busy', labels, online[0]?.name || '');
    else wait('offline', 'RUNNER_UNAVAILABLE', labels);
  } catch {
    wait('unknown', 'RUNNER_STATUS_UNKNOWN', labels);
  }
  flush();
}

await main();
