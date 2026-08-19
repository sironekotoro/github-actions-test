#!/usr/bin/env bash
# Shared helpers for the agent dispatch pipeline.
#
# Convention:
#   - failure category is written to $FAILURE_FILE so the workflow can report
#     a precise, machine-readable cause instead of a bare `exit 1`.
#   - a short summary table is appended to $GITHUB_STEP_SUMMARY when present.
#   - prompt / task bodies are NEVER echoed by these helpers.
set -uo pipefail

FAILURE_FILE="${RUNNER_TEMP:-/tmp}/failure_category"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/tmp/agent_step_summary.md}"

mkdir -p "$(dirname "$FAILURE_FILE")"
: > "$FAILURE_FILE"
: > "$SUMMARY_FILE"

# --- failure categories (machine readable) ---
CAT_INVALID_PAYLOAD="INVALID_PAYLOAD"
CAT_REPO_MISMATCH="REPOSITORY_IDENTITY_MISMATCH"
CAT_UNAUTHORIZED="UNAUTHORIZED_ACTOR"
CAT_ALREADY_RUNNING="TASK_ALREADY_RUNNING"
CAT_DIRTY_TREE="DIRTY_WORKING_TREE"
CAT_CHECKOUT="CHECKOUT_FAILED"
CAT_AGENT_START="AGENT_START_FAILED"
CAT_MODEL_API="MODEL_API_FAILED"
CAT_AGENT_TIMEOUT="AGENT_TIMEOUT"
CAT_TEST="TEST_FAILED"
CAT_PUSH="PUSH_FAILED"
CAT_PR="PR_CREATE_FAILED"

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

set_failure() { printf '%s\n' "$1" > "$FAILURE_FILE"; }

get_failure() { cat "$FAILURE_FILE" 2>/dev/null || echo UNKNOWN; }

fail_with() {
  local category="$1"; shift
  set_failure "$category"
  log_error "FAILURE_CATEGORY=$category $*"
  exit 1
}

summary() { printf '%s\n' "$*" >> "$SUMMARY_FILE"; }

sha256_of() { # <file> -> sha256 (never prints contents)
  command -v shasum >/dev/null 2>&1 \
    && shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 \
    || openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
}