#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

DISPATCH="$ROOT/scripts/run-agent-dispatch-container.sh"
REPAIR="$ROOT/scripts/run-review-repair-agent-container.sh"
BROKER="$ROOT/scripts/provider-broker.mjs"
PKG="$ROOT/docker/provider-broker-package.json"
OPENCODE="$ROOT/scripts/agents/opencode.sh"

for script in "$DISPATCH" "$REPAIR"; do
  name="$(basename "$script")"
  t "$name binds broker to validated task id" "yes" \
    "$(grep -q 'broker_task_id=.*task_id' "$script" && grep -q 'BROKER_TASK_ID="$broker_task_id"' "$script" && echo yes || echo no)"
  t "$name derives capability expiry from agent runtime" "yes" \
    "$(grep -q 'agent_runtime_minutes=' "$script" && grep -q 'broker_capability_expiry_ms=.*agent_runtime_minutes + 5' "$script" && echo yes || echo no)"
  t "$name has no fixed one-hour capability fallback" "yes" \
    "$(grep -q 'BROKER_CAPABILITY_EXPIRY_MS=.*3600000' "$script" && echo no || echo yes)"
  t "$name marks broker started before health checks" "yes" \
    "$(awk '/docker run --detach --name "\$broker_name"/{seen=1} seen && /broker_started=true/{started=NR} seen && /docker network connect "\$broker_egress_network"/{connected=NR; exit} END{if(started && connected && started<connected) print "yes"; else print "no"}' "$script")"
done

t "obsolete standalone broker launcher removed" "no" \
  "$([ -e "$ROOT/scripts/run-provider-broker.sh" ] && echo yes || echo no)"

t "broker dependency uses patched undici 7.29.0" "7.29.0" \
  "$(node -e 'console.log(require(process.argv[1]).dependencies.undici)' "$PKG")"

t "broker validates capability expiry configuration" "yes" \
  "$(grep -q 'BROKER_CAPABILITY_EXPIRY_MS invalid' "$BROKER" && echo yes || echo no)"
t "broker validates request-count configuration" "yes" \
  "$(grep -q 'BROKER_MAX_REQUESTS invalid' "$BROKER" && echo yes || echo no)"
t "broker validates per-job budget configuration" "yes" \
  "$(grep -q 'BROKER_JOB_MAX_USD invalid' "$BROKER" && echo yes || echo no)"
t "broker requires task binding" "yes" \
  "$(grep -q 'BROKER_TASK_ID required' "$BROKER" && echo yes || echo no)"

t "pinned OpenCode broker base uses /api/v1" "yes" \
  "$(grep -q "baseURL = brokerBase + '/api/v1'" "$OPENCODE" && echo yes || echo no)"
t "pinned OpenCode small model is bound to requested model" "yes" \
  "$(grep -q 'base.small_model = requestedModel' "$OPENCODE" && echo yes || echo no)"

health_block="$(awk '/function handleHealth/{capture=1} capture{print} /^}/{if(capture){exit}}' "$BROKER")"
t "health endpoint is minimal" "yes" \
  "$(printf '%s' "$health_block" | grep -q "JSON.stringify({ status: 'ok' })" && ! printf '%s' "$health_block" | grep -qE 'provisioned|requestCount|concurrentCount' && echo yes || echo no)"

# Malformed security bounds must fail before any provider call is attempted.
run_invalid_config() {
  local key="$1" value="$2" expected="$3" tmp status
  tmp="$(make_temp)"
  env \
    BROKER_PORT=3080 \
    OPENROUTER_MANAGEMENT_KEY=dummy-management \
    BROKER_CAPABILITY=dummy-capability \
    BROKER_TASK_ID=dummy-task \
    BROKER_ALLOWED_MODEL=openrouter/deepseek/deepseek-v4-flash \
    BROKER_CAPABILITY_EXPIRY_MS=600000 \
    BROKER_MAX_REQUESTS=10 \
    BROKER_JOB_MAX_USD=0.25 \
    "$key=$value" \
    node "$BROKER" >"$tmp/out" 2>"$tmp/err"
  status=$?
  t "$key malformed value fails closed" "yes" \
    "$([ "$status" -ne 0 ] && grep -q "$expected" "$tmp/err" && echo yes || echo no)"
}

run_invalid_config BROKER_CAPABILITY_EXPIRY_MS not-a-number 'BROKER_CAPABILITY_EXPIRY_MS invalid'
run_invalid_config BROKER_MAX_REQUESTS not-a-number 'BROKER_MAX_REQUESTS invalid'
run_invalid_config BROKER_JOB_MAX_USD not-a-number 'BROKER_JOB_MAX_USD invalid'

finish
