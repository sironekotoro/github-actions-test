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
CAT_AGENT_CREDENTIAL_LEAK_BLOCKED="AGENT_CREDENTIAL_LEAK_BLOCKED"
CAT_MODEL_API="MODEL_API_FAILED"
CAT_AGENT_TIMEOUT="AGENT_TIMEOUT"
CAT_TEST="TEST_FAILED"
CAT_PUSH="PUSH_FAILED"
CAT_PR="PR_CREATE_FAILED"
CAT_WORKFLOW_PUSH_AUTH_NOT_CONFIGURED="WORKFLOW_PUSH_AUTH_NOT_CONFIGURED"
CAT_CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED="CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED"
CAT_AGENT_EXECUTOR_UNAVAILABLE="AGENT_EXECUTOR_UNAVAILABLE"
CAT_PROVIDER_BUDGET_LOW="PROVIDER_BUDGET_LOW"
CAT_PROVIDER_BUDGET_UNKNOWN="PROVIDER_BUDGET_UNKNOWN"
CAT_BILLING_ALERT_FAILED="BILLING_ALERT_FAILED"
CAT_RUNNER_UNAVAILABLE="RUNNER_UNAVAILABLE"
CAT_RUNNER_STATUS_UNKNOWN="RUNNER_STATUS_UNKNOWN"

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

# Broker / provisioning categories.
CAT_BROKER_AUTH_FAILED="BROKER_AUTH_FAILED"
CAT_BROKER_PROVISION_FAILED="BROKER_PROVISION_FAILED"
CAT_BROKER_CLEANUP_FAILED="BROKER_CLEANUP_FAILED"
CAT_BROKER_UNAVAILABLE="BROKER_UNAVAILABLE"
CAT_BROKER_CAPABILITY_FAILED="BROKER_CAPABILITY_GENERATION_FAILED"

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
get_failure_reason() { cat "$FAILURE_REASON_FILE" 2>/dev/null || echo ""; }

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

# scan_final_workspace_for_credential <workspace-dir> <credential-value>
#
# Inspect the final isolated tree before any patch is constructed. Node handles
# path names and file contents as byte sequences; the credential is supplied
# only through the environment, never argv or a temporary file. lstat keeps
# symlinks opaque: their link text is scanned, but their targets are not read.
scan_final_workspace_for_credential() {
  local workspace_dir="$1" credential_value="$2" scan_status

  [ -z "$credential_value" ] && return 0
  command -v node >/dev/null 2>&1 \
    || fail_with "$CAT_AGENT_CREDENTIAL_LEAK_BLOCKED" "credential publication scan unavailable"

  if AGENT_PUBLICATION_SCAN_CREDENTIAL="$credential_value" node - "$workspace_dir" <<'NODE'
const fs = require('fs');

const root = process.argv[2];
const needle = Buffer.from(process.env.AGENT_PUBLICATION_SCAN_CREDENTIAL || '');
if (needle.length === 0) process.exit(0);

function containsNeedle(buffer) {
  return buffer.indexOf(needle) !== -1;
}

function scanFile(entry) {
  const noFollow = fs.constants.O_NOFOLLOW || 0;
  const descriptor = fs.openSync(entry, fs.constants.O_RDONLY | noFollow);
  try {
    if (!fs.fstatSync(descriptor).isFile()) throw new Error('entry changed during scan');
    const chunk = Buffer.allocUnsafe(64 * 1024);
    let overlap = Buffer.alloc(0);
    for (;;) {
      const count = fs.readSync(descriptor, chunk, 0, chunk.length, null);
      if (count === 0) return false;
      const candidate = Buffer.concat([overlap, chunk.subarray(0, count)]);
      if (containsNeedle(candidate)) return true;
      const keep = Math.min(needle.length - 1, candidate.length);
      overlap = candidate.subarray(candidate.length - keep);
    }
  } finally {
    fs.closeSync(descriptor);
  }
}

function scan(entry) {
  const stat = fs.lstatSync(entry);
  if (stat.isSymbolicLink()) {
    return containsNeedle(Buffer.from(fs.readlinkSync(entry, {encoding: 'buffer'})));
  }
  if (stat.isFile()) return scanFile(entry);
  if (!stat.isDirectory()) return false;
  for (const name of fs.readdirSync(entry, {encoding: 'buffer'})) {
    if (containsNeedle(name)) return true;
    if (scan(Buffer.concat([Buffer.from(entry), Buffer.from('/'), name]))) return true;
  }
  return false;
}

try {
  process.exit(scan(Buffer.from(root)) ? 42 : 0);
} catch (_) {
  process.exit(1);
}
NODE
  then
    return 0
  else
    scan_status=$?
  fi
  if [ "$scan_status" -eq 42 ]; then
    fail_with "$CAT_AGENT_CREDENTIAL_LEAK_BLOCKED" "selected credential found in isolated workspace"
  fi
  fail_with "$CAT_AGENT_CREDENTIAL_LEAK_BLOCKED" "credential publication scan failed"
}

# redacted_agent_log_tail <log-file> <credential-value> [prompt-file]
# Print the usual 40-line diagnostic tail after exact-literal replacement.
# The credential reaches trusted Node through the environment only.
redacted_agent_log_tail() {
  local logfile="$1" credential_value="$2" prompt_file="${3:-}"
  AGENT_LOG_REDACTION_CREDENTIAL="$credential_value" node - "$logfile" "$prompt_file" <<'NODE' >&2
const fs = require('fs');
const file = process.argv[2];
const marker = Buffer.from('[REDACTED_SELECTED_CREDENTIAL]');
const promptMarker = Buffer.from('[REDACTED_AGENT_PROMPT]');
const needle = Buffer.from(process.env.AGENT_LOG_REDACTION_CREDENTIAL || '');
let prompt = Buffer.alloc(0);
try {
  if (process.argv[3]) prompt = fs.readFileSync(process.argv[3]);
} catch (_) {
  prompt = Buffer.alloc(0);
}

function tailLines(data, count) {
  const newlines = [];
  for (let i = 0; i < data.length; i++) if (data[i] === 10) newlines.push(i);
  const completeLines = newlines.length;
  const hasPartialLine = data.length > 0 && data[data.length - 1] !== 10;
  const totalLines = completeLines + (hasPartialLine ? 1 : 0);
  if (totalLines <= count) return data;
  return data.subarray(newlines[totalLines - count - 1] + 1);
}

function replaceExact(data, search, replacement) {
  if (search.length === 0) return data;
  const parts = [];
  let offset = 0;
  for (;;) {
    const found = data.indexOf(search, offset);
    if (found === -1) break;
    parts.push(data.subarray(offset, found), replacement);
    offset = found + search.length;
  }
  parts.push(data.subarray(offset));
  return Buffer.concat(parts);
}

try {
  const data = tailLines(fs.readFileSync(file), 40);
  const credentialRedacted = replaceExact(data, needle, marker);
  process.stderr.write(replaceExact(credentialRedacted, prompt, promptMarker));
} catch (_) {
  process.stderr.write('[agent log unavailable]\n');
}
NODE
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
  [ -n "${OPENCODE_CONFIG_CONTENT+x}" ] && clean_env+=("OPENCODE_CONFIG_CONTENT=$OPENCODE_CONFIG_CONTENT")
  [ -n "${OPENCODE_BROKER_BASE_URL+x}" ] && clean_env+=("OPENCODE_BROKER_BASE_URL=$OPENCODE_BROKER_BASE_URL")
  [ -n "${OPENROUTER_MODEL+x}" ] && clean_env+=("OPENROUTER_MODEL=$OPENROUTER_MODEL")
  [ -n "${PROVIDER_BROKER_ENABLED+x}" ] && clean_env+=("PROVIDER_BROKER_ENABLED=$PROVIDER_BROKER_ENABLED")
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

# generate_broker_capability <var_name>
#
# Generate a cryptographically random opaque per-run broker capability token.
# The token is exported as the named variable and kept only in trusted memory/env.
# Fails closed if generation fails. Never reuses any existing credential value.
generate_broker_capability() {
  local var_name="$1" cap
  cap="$(node -e "
    const crypto = require('crypto');
    const buf = crypto.randomBytes(32);
    process.stdout.write('brk-' + buf.toString('base64url'));
  " 2>/dev/null)" || fail_with "$CAT_BROKER_CAPABILITY_FAILED" "capability generation failed"
  [ -n "$cap" ] || fail_with "$CAT_BROKER_CAPABILITY_FAILED" "capability generation produced empty token"
  printf -v "$var_name" '%s' "$cap"
  export "$var_name"="$cap"
}

# setup_broker_network_topology <private_network> <egress_network> <broker_egress_network> <proxy_name> <egress_image> <run_key>
#
# Create and connect three networks for broker mode:
#   (a) private_network (--internal): agent + broker only
#   (b) broker_egress_network (--internal): broker + Squid only
#   (c) egress_network (no --internal): Squid + external only
# Squid starts on (b) and is connected to (c). Broker is NOT on (a) yet
# (caller starts broker on (a) and connects to (b)).
# Sets PROXY_BROKER_IP to Squid's address on (b) for broker to use as HTTP_PROXY.
setup_broker_network_topology() {
  local private_network="$1" egress_network="$2" broker_egress_network="$3"
  local proxy_name="$4" egress_image="$5" run_key="$6"

  docker network create --internal "$private_network" >/dev/null \
    || fail_with "$CAT_BROKER_UNAVAILABLE" "could not create broker agent private network"
  docker network create "$egress_network" >/dev/null \
    || fail_with "$CAT_BROKER_UNAVAILABLE" "could not create broker egress network"
  docker network create --internal "$broker_egress_network" >/dev/null \
    || fail_with "$CAT_BROKER_UNAVAILABLE" "could not create broker internal egress network"

  # Start Squid on broker_egress_network only (NOT private_network)
  docker run --detach --name "$proxy_name" --network "$broker_egress_network" \
    --read-only --user 31:31 --cap-drop=ALL --security-opt=no-new-privileges \
    --tmpfs /run:rw,nosuid,nodev,noexec,mode=1777,size=16m \
    --tmpfs /var/cache/squid:rw,nosuid,nodev,noexec,mode=1777,size=64m \
    "$egress_image" >/dev/null \
    || fail_with "$CAT_BROKER_UNAVAILABLE" "could not start broker egress proxy"
  docker network connect "$egress_network" "$proxy_name" \
    || fail_with "$CAT_BROKER_UNAVAILABLE" "could not connect broker egress proxy to external network"

  # Get Squid address on the broker_egress_network (broker uses this as HTTP_PROXY)
  local broker_proxy_ip
  broker_proxy_ip="$(docker inspect "$proxy_name" 2>/dev/null \
    | jq -r --arg network "$broker_egress_network" '.[0].NetworkSettings.Networks[$network].IPAddress // empty')"
  [ -n "$broker_proxy_ip" ] || fail_with "$CAT_BROKER_UNAVAILABLE" "could not determine proxy address for broker"
  export PROXY_BROKER_IP="$broker_proxy_ip"
}

# setup_standard_proxy <private_network> <egress_network> <proxy_name> <egress_image>
#
# Create and connect the standard two-network topology for non-broker mode.
# Squid is on private_network (agent-facing) and egress_network (external).
# Sets PROXY_IP to Squid's address on private_network.
setup_standard_proxy() {
  local private_network="$1" egress_network="$2" proxy_name="$3" egress_image="$4"

  docker network create --internal "$private_network" >/dev/null \
    || fail_with "$CAT_AGENT_START" "could not create isolated agent network"
  docker network create "$egress_network" >/dev/null \
    || fail_with "$CAT_AGENT_START" "could not create isolated egress network"
  docker run --detach --name "$proxy_name" --network "$private_network" \
    --read-only --user 31:31 --cap-drop=ALL --security-opt=no-new-privileges \
    --tmpfs /run:rw,nosuid,nodev,noexec,mode=1777,size=16m \
    --tmpfs /var/cache/squid:rw,nosuid,nodev,noexec,mode=1777,size=64m \
    "$egress_image" >/dev/null \
    || fail_with "$CAT_AGENT_START" "could not start restricted egress proxy"
  docker network connect "$egress_network" "$proxy_name" \
    || fail_with "$CAT_AGENT_START" "could not connect restricted egress proxy"
}
#
# Shared trusted helper that validates and imports an untrusted agent patch.
# Called identically from ordinary dispatch and review-repair paths.
apply_agent_patch() {
  local target_dir="$1" patch_file="$2" diff_status="$3"
  local agent_log="${4:-}" credential_value="${5:-}" prompt_file="${6:-}"

  # diff_status outside {0,1} => infrastructure failure, not patch error
  [ "$diff_status" -eq 0 ] || [ "$diff_status" -eq 1 ] \
    || fail_with "$CAT_AGENT_START" "could not create patch from isolated workspace"

  # diff_status=0 => no changes from the agent
  if [ "$diff_status" -eq 0 ]; then
    set_failure_reason "NO_CHANGES"
    if [ -n "$agent_log" ]; then
      log_error "agent exited successfully but produced no filesystem changes; redacted log tail follows"
      redacted_agent_log_tail "$agent_log" "$credential_value" "$prompt_file"
    fi
    fail_with "$CAT_AGENT_PATCH_INVALID" "agent patch produced no changes"
  fi

  # diff_status=1 with missing or zero-byte patch
  if [ ! -f "$patch_file" ] || [ ! -s "$patch_file" ]; then
    set_failure_reason "EMPTY_PATCH"
    fail_with "$CAT_AGENT_PATCH_INVALID" "agent patch is missing or empty"
  fi

  # baseline git apply --check -p2 (no --whitespace=error)
  git -C "$target_dir" apply --check -p2 "$patch_file" 2>/dev/null \
    || { set_failure_reason "PATCH_PARSE_FAILED"; fail_with "$CAT_AGENT_PATCH_INVALID" "agent patch failed parse check"; }

  # strict git apply --check --whitespace=error -p2
  git -C "$target_dir" apply --check --whitespace=error -p2 "$patch_file" 2>/dev/null \
    || { set_failure_reason "PATCH_VALIDATION_FAILED"; fail_with "$CAT_AGENT_PATCH_INVALID" "agent patch failed validation"; }

  # final import (stderr suppressed)
  git -C "$target_dir" apply --whitespace=error -p2 "$patch_file" 2>/dev/null \
    || fail_with "$CAT_AGENT_PATCH_INVALID" "could not import agent patch"
}
