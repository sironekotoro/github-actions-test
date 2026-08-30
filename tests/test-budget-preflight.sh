#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
TMP="$(make_temp)"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

start_server() {
  local mode="$1" credits="${2:-10}" usage="${3:-9}" key_remaining="${4:-null}" openai_cost="${5:-0.75}"
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  : > "$TMP/port"
  MOCK_MODE="$mode" MOCK_TOTAL_CREDITS="$credits" MOCK_TOTAL_USAGE="$usage" \
  MOCK_KEY_REMAINING="$key_remaining" MOCK_OPENAI_COST="$openai_cost" \
    python3 "$ROOT/tests/fixtures/phase_a_mock_server.py" > "$TMP/port" 2>/dev/null &
  SERVER_PID=$!
  i=0
  while [ ! -s "$TMP/port" ] && [ "$i" -lt 50 ]; do sleep 0.05; i=$((i+1)); done
  [ -s "$TMP/port" ] || return 1
  PORT="$(cat "$TMP/port")"
}

run_gate() {
  local agent="$1" enabled="$2"
  : > "$TMP/out"
  AGENT="$agent" PROVIDER_BUDGET_GATE_ENABLED="$enabled" \
  PROVIDER_BALANCE_WARN_USD=0.50 PROVIDER_BALANCE_HARD_FLOOR_USD=0.25 PROVIDER_JOB_MAX_USD=0.25 \
  OPENROUTER_MANAGEMENT_KEY='fixture-management-secret' OPENROUTER_API_KEY='fixture-inference-secret' \
  OPENROUTER_CREDITS_URL="http://127.0.0.1:$PORT/credits" OPENROUTER_KEY_URL="http://127.0.0.1:$PORT/key" \
  OPENAI_ADMIN_KEY='fixture-openai-admin-secret' OPENAI_MONTHLY_BUDGET_USD="${OPENAI_MONTHLY_BUDGET_USD:-2.00}" \
  OPENAI_COSTS_URL="http://127.0.0.1:$PORT/openai-costs" GITHUB_OUTPUT="$TMP/out" \
    node "$ROOT/scripts/provider-budget-preflight.mjs" > "$TMP/stdout" 2> "$TMP/stderr"
}

value() { grep -E "^$1=" "$TMP/out" | tail -1 | cut -d= -f2-; }

start_server ok
run_gate opencode false
t "disabled gate passes" "pass" "$(value decision)"
t "disabled gate state" "disabled" "$(value state)"
t "disabled gate still reports required reserve" "0.25" "$(value required_job_reserve_usd)"

start_server ok 10 9 0.80
run_gate opencode true
t "OpenRouter uses conservative account/key remaining" "0.8" "$(value available_usd)"
t "OpenRouter funded state passes" "pass" "$(value decision)"
t "OpenRouter funded state is ok" "ok" "$(value state)"
t "OpenRouter job cap is bounded by configured max" "0.25" "$(value job_cap_usd)"
t "OpenRouter requires full job reserve above floor" "0.25" "$(value required_job_reserve_usd)"

start_server ok 10 9.5 null
run_gate opencode true
t "OpenRouter exact warning threshold permits reserved run" "pass" "$(value decision)"
t "OpenRouter warning state" "warning" "$(value state)"
t "OpenRouter warning spendable preserves floor and reserve" "0.25" "$(value job_spendable_usd)"

start_server ok 10 9.7 null
run_gate opencode true
t "OpenRouter just above hard floor without full reserve waits" "wait" "$(value decision)"
t "OpenRouter insufficient reserve category" "PROVIDER_BUDGET_LOW" "$(value reason)"
t "OpenRouter insufficient reserve state" "blocked" "$(value state)"
t "OpenRouter reports only spendable amount above floor" "0.05" "$(value job_spendable_usd)"

start_server ok 10 9.75 null
run_gate opencode true
t "OpenRouter at hard floor waits" "wait" "$(value decision)"
t "OpenRouter hard floor category" "PROVIDER_BUDGET_LOW" "$(value reason)"
t "OpenRouter hard floor state" "blocked" "$(value state)"

start_server http500
run_gate opencode true
t "OpenRouter API uncertainty fails closed" "wait" "$(value decision)"
t "OpenRouter API uncertainty category" "PROVIDER_BUDGET_UNKNOWN" "$(value reason)"

start_server ok 10 9 null 0.75
OPENAI_MONTHLY_BUDGET_USD=2.00 run_gate codex true
t "OpenAI budget-derived remaining" "1.25" "$(value available_usd)"
t "OpenAI funded state passes" "pass" "$(value decision)"
t "OpenAI source is explicit budget envelope" "configured-monthly-budget-minus-official-costs" "$(value source)"

start_server ok 10 9 null 0.70
OPENAI_MONTHLY_BUDGET_USD=1.00 run_gate codex true
t "OpenAI above floor but below required reserve waits" "wait" "$(value decision)"
t "OpenAI insufficient reserve blocked" "blocked" "$(value state)"

start_server ok
run_gate claude-code true
t "Anthropic unsupported balance state fails closed" "wait" "$(value decision)"
t "Anthropic state is unknown" "unknown" "$(value state)"

combined="$(cat "$TMP/stdout" "$TMP/stderr" "$TMP/out")"
t "management secret never appears in output" "absent" "$(printf '%s' "$combined" | grep -q 'fixture-management-secret' && echo present || echo absent)"
t "inference secret never appears in output" "absent" "$(printf '%s' "$combined" | grep -q 'fixture-inference-secret' && echo present || echo absent)"
t "OpenAI admin secret never appears in output" "absent" "$(printf '%s' "$combined" | grep -q 'fixture-openai-admin-secret' && echo present || echo absent)"

finish
