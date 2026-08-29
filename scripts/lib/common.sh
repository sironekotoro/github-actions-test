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
FAILURE_REASON_FILE="${RUNNER_TEMP:-/tmp}/failure_reason"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/tmp/agent_step_summary.md}"

mkdir -p "$(dirname "$FAILURE_FILE")"
[ -f "$FAILURE_FILE" ] || : > "$FAILURE_FILE"
mkdir -p "$(dirname "$FAILURE_REASON_FILE")"
[ -f "$FAILURE_REASON_FILE" ] || : > "$FAILURE_REASON_FILE"
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

# Agent type / credential profile categories.
CAT_AGENT_UNKNOWN="AGENT_UNKNOWN"
CAT_AGENT_AUTH="AGENT_AUTH_FAILED"
CAT_AGENT_UNAVAILABLE="AGENT_UNAVAILABLE"

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
set_failure_reason() { printf '%s\n' "$1" > "$FAILURE_REASON_FILE"; }
clear_failure_reason() { : > "$FAILURE_REASON_FILE"; }
get_failure_reason() { cat "$FAILURE_REASON_FILE" 2>/dev/null || echo UNKNOWN; }

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

# agent_exec_clean <credential-var> <credential-value> -- <command...>
#
# Execute one command from a deliberately minimal environment. The workflow
# shell may contain several secrets and GitHub credentials; neither those
# names nor arbitrary inherited variables are allowed to reach the CLI.
agent_exec_clean() {
  local credential_var="$1" credential_value="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift

  local -a clean_env=()
  [ -n "${PATH+x}" ] && clean_env+=("PATH=$PATH")
  [ -n "${HOME+x}" ] && clean_env+=("HOME=$HOME")
  [ -n "${TMPDIR+x}" ] && clean_env+=("TMPDIR=$TMPDIR")
  [ -n "${TMP+x}" ] && clean_env+=("TMP=$TMP")
  [ -n "${TEMP+x}" ] && clean_env+=("TEMP=$TEMP")
  [ -n "${LANG+x}" ] && clean_env+=("LANG=$LANG")
  [ -n "${LC_ALL+x}" ] && clean_env+=("LC_ALL=$LC_ALL")
  [ -n "${LANGUAGE+x}" ] && clean_env+=("LANGUAGE=$LANGUAGE")
  [ -n "${TERM+x}" ] && clean_env+=("TERM=$TERM")
  [ -n "${HTTPS_PROXY+x}" ] && clean_env+=("HTTPS_PROXY=$HTTPS_PROXY")
  [ -n "${HTTP_PROXY+x}" ] && clean_env+=("HTTP_PROXY=$HTTP_PROXY")
  [ -n "${ALL_PROXY+x}" ] && clean_env+=("ALL_PROXY=$ALL_PROXY")
  [ -n "${NO_PROXY+x}" ] && clean_env+=("NO_PROXY=$NO_PROXY")
  [ -n "${SSL_CERT_FILE+x}" ] && clean_env+=("SSL_CERT_FILE=$SSL_CERT_FILE")
  [ -n "${NODE_EXTRA_CA_CERTS+x}" ] && clean_env+=("NODE_EXTRA_CA_CERTS=$NODE_EXTRA_CA_CERTS")
  [ -n "$credential_var" ] && clean_env+=("$credential_var=$credential_value")

  env -i "${clean_env[@]}" "$@"
}

# agent_run_clean <credential-var> <credential-value> <minutes> <logfile> -- <command...>
agent_run_clean() {
  local credential_var="$1" credential_value="$2" max_runtime="$3" logfile="$4"
  shift 4
  [ "${1:-}" = "--" ] && shift

  if command -v timeout >/dev/null 2>&1; then
    agent_exec_clean "$credential_var" "$credential_value" -- timeout "${max_runtime}m" "$@" >"$logfile" 2>&1
  else
    agent_exec_clean "$credential_var" "$credential_value" -- "$@" >"$logfile" 2>&1
  fi
}

# apply_agent_patch <target-dir> <patch-file> <diff-status>
#
# Process the result of a git diff --no-index between base and workspace.
# All post-agent patch classification is owned by this single shared helper
# so ordinary dispatch and review-repair behave identically.
#
# diff_status outside {0,1} => FAILURE_CATEGORY=AGENT_START_FAILED, no FAILURE_REASON.
# diff_status=0             => FAILURE_REASON=NO_CHANGES, FAILURE_CATEGORY=AGENT_PATCH_INVALID.
# empty patch file          => FAILURE_REASON=EMPTY_PATCH, FAILURE_CATEGORY=AGENT_PATCH_INVALID.
# git apply --check -p2    => FAILURE_REASON=PATCH_PARSE_FAILED, FAILURE_CATEGORY=AGENT_PATCH_INVALID.
# strict whitespace check   => FAILURE_REASON=PATCH_VALIDATION_FAILED, FAILURE_CATEGORY=AGENT_PATCH_INVALID.
# final git apply fail      => FAILURE_CATEGORY=AGENT_PATCH_INVALID, no FAILURE_REASON.
# success                   => returns 0.
apply_agent_patch() {
  local target_dir="$1" patch_file="$2" diff_status="$3"

  if [ "$diff_status" -ne 0 ] && [ "$diff_status" -ne 1 ]; then
    clear_failure_reason
    fail_with "$CAT_AGENT_START" "could not create agent patch from isolated workspace"
  fi

  if [ "$diff_status" -eq 0 ]; then
    set_failure_reason NO_CHANGES
    fail_with "$CAT_AGENT_PATCH_INVALID" "agent produced no changes"
  fi

  if [ ! -s "$patch_file" ]; then
    set_failure_reason EMPTY_PATCH
    fail_with "$CAT_AGENT_PATCH_INVALID" "agent patch is empty"
  fi

  if ! git -C "$target_dir" apply --check -p2 "$patch_file" 2>/dev/null; then
    set_failure_reason PATCH_PARSE_FAILED
    fail_with "$CAT_AGENT_PATCH_INVALID" "isolated agent patch failed parse validation"
  fi

  if ! git -C "$target_dir" apply --check --whitespace=error -p2 "$patch_file" 2>/dev/null; then
    set_failure_reason PATCH_VALIDATION_FAILED
    fail_with "$CAT_AGENT_PATCH_INVALID" "isolated agent patch failed whitespace validation"
  fi

  if ! git -C "$target_dir" apply --whitespace=error -p2 "$patch_file"; then
    clear_failure_reason
    fail_with "$CAT_AGENT_PATCH_INVALID" "could not import agent patch"
  fi
}
