#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
TMP="$(make_temp)"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

start_server() {
  local mode="$1"
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  : > "$TMP/port"
  MOCK_MODE="$mode" python3 "$ROOT/tests/fixtures/phase_a_mock_server.py" > "$TMP/port" 2>/dev/null &
  SERVER_PID=$!
  i=0
  while [ ! -s "$TMP/port" ] && [ "$i" -lt 50 ]; do sleep 0.05; i=$((i+1)); done
  [ -s "$TMP/port" ] || return 1
  PORT="$(cat "$TMP/port")"
}

run_router() {
  local enabled="$1" token="${2-fixture-runner-token}"
  : > "$TMP/out"
  RUNNER_ROUTER_ENABLED="$enabled" RUNNER_STATUS_TOKEN="$token" \
  RUNNER_REQUIRED_LABELS='["self-hosted","review-repair","macOS","ARM64"]' \
  GITHUB_REPOSITORY='sironekotoro/github-actions-test' \
  RUNNER_STATUS_API_BASE="http://127.0.0.1:$PORT" GITHUB_OUTPUT="$TMP/out" \
    node "$ROOT/scripts/check-runner-availability.mjs" > "$TMP/stdout" 2> "$TMP/stderr"
}
value() { grep -E "^$1=" "$TMP/out" | tail -1 | cut -d= -f2-; }

start_server runner-idle
run_router false ''
t "disabled router preserves self-hosted route" "run" "$(value decision)"
t "disabled router state" "disabled" "$(value state)"

start_server runner-idle
run_router true
t "idle compatible runner runs" "run" "$(value decision)"
t "idle compatible runner state" "online-idle" "$(value state)"
t "idle runner name is surfaced" "mock-idle" "$(value runner_name)"

start_server runner-busy
run_router true
t "busy compatible runner queues on self-hosted" "run" "$(value decision)"
t "busy compatible runner state" "online-busy" "$(value state)"

start_server runner-offline
run_router true
t "offline compatible runner defers" "wait" "$(value decision)"
t "offline category" "RUNNER_UNAVAILABLE" "$(value reason)"

start_server runner-wrong-labels
run_router true
t "online incompatible runner does not qualify" "wait" "$(value decision)"

start_server http500
run_router true
t "runner API error fails closed" "wait" "$(value decision)"
t "runner API error category" "RUNNER_STATUS_UNKNOWN" "$(value reason)"

start_server runner-idle
run_router true ''
t "missing runner status credential fails closed" "wait" "$(value decision)"
t "missing runner status credential category" "RUNNER_STATUS_UNKNOWN" "$(value reason)"

combined="$(cat "$TMP/stdout" "$TMP/stderr" "$TMP/out")"
t "runner status token never appears in output" "absent" "$(printf '%s' "$combined" | grep -q 'fixture-runner-token' && echo present || echo absent)"
t "runner labels remain stable JSON" '["self-hosted","review-repair","macOS","ARM64"]' "$(value runner_labels)"

finish
