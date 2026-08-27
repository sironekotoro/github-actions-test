#!/usr/bin/env bash
# Shared helpers for the agent dispatch pipeline.
#
# Convention:
#   - failure category is written to $FAILURE_FILE so the workflow can report
#     a precise, machine-readable cause instead of a bare `exit 1`.
#   - a short summary table is appended to $GITHUB_STEP_SUMMARY when present.
#   - prompt / task bodies and secret values are NEVER echoed by these helpers.
set -uo pipefail

FAILURE_FILE="${RUNNER_TEMP:-/tmp}/failure_category"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/tmp/agent_step_summary.md}"

mkdir -p "$(dirname "$FAILURE_FILE")"
[ -f "$FAILURE_FILE" ] || : > "$FAILURE_FILE"
mkdir -p "$(dirname "$SUMMARY_FILE")"
[ -f "$SUMMARY_FILE" ] || : > "$SUMMARY_FILE"

# --- failure categories (machine readable) ---
CAT_INVALID_PAYLOAD="INVALID_PAYLOAD"
CAT_REPO_MISMATCH="REPOSITORY_IDENTITY_MISMATCH"
CAT_UNAUTHORIZED="UNAUTHORIZED_ACTOR"
CAT_ALREADY_RUNNING="TASK_ALREADY_RUNNING"
CAT_DIRTY_TREE="DIRTY_WORKING_TREE"
CAT_CHECKOUT="CHECKOUT_FAILED"
CAT_AGENT_START="AGENT_START_FAILED"
CAT_AGENT_PATCH_INVALID="AGENT_PATCH_INVALID"
CAT_MODEL_API="MODEL_API_FAILED"
CAT_AGENT_TIMEOUT="AGENT_TIMEOUT"
CAT_TEST="TEST_FAILED"
CAT_PUSH="PUSH_FAILED"
CAT_PR="PR_CREATE_FAILED"
CAT_WORKFLOW_PUSH_AUTH_NOT_CONFIGURED="WORKFLOW_PUSH_AUTH_NOT_CONFIGURED"
CAT_CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED="CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED"
CAT_AGENT_EXECUTOR_UNAVAILABLE="AGENT_EXECUTOR_UNAVAILABLE"

# Cross-repository dispatch categories.
CAT_TARGET_NOT_ALLOWED="TARGET_REPOSITORY_NOT_ALLOWED"
CAT_CROSS_REPO_AUTH_UNAVAILABLE="CROSS_REPO_AUTH_UNAVAILABLE"
CAT_APP_INSTALLATION_NOT_FOUND="APP_INSTALLATION_NOT_FOUND"
CAT_APP_TOKEN_FAILED="APP_TOKEN_FAILED"
CAT_TARGET_CHECKOUT="TARGET_CHECKOUT_FAILED"
CAT_TARGET_PERMISSION="TARGET_PERMISSION_DENIED"
CAT_TARGET_DEFAULT_BRANCH="TARGET_DEFAULT_BRANCH_NOT_FOUND"
CAT_TARGET_PUSH="TARGET_PUSH_FAILED"
CAT_TARGET_PR="TARGET_PR_CREATE_FAILED"

# Review-repair categories. Ignored review states and duplicate events are
# reported as non-failing decisions; these categories are reserved for a
# fail-closed safety stop or an exhausted bound.
CAT_REPAIR_METADATA="REPAIR_METADATA_INVALID"
CAT_REPAIR_IDENTITY="REPAIR_PR_IDENTITY_MISMATCH"
CAT_REPAIR_BRANCH="REPAIR_BRANCH_MISMATCH"
CAT_REPAIR_LIMIT="REPAIR_LIMIT_REACHED"
CAT_REPAIR_STATE="REPAIR_STATE_WRITE_FAILED"
CAT_REPAIR_EXECUTOR_UNAVAILABLE="REPAIR_EXECUTOR_UNAVAILABLE"
CAT_REPAIR_DISPATCH="REPAIR_EXECUTOR_DISPATCH_FAILED"
CAT_REPAIR_REQUEST="REPAIR_EXECUTOR_REQUEST_INVALID"

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

sha256_of() {
  command -v shasum >/dev/null 2>&1 \
    && shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 \
    || openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
}
