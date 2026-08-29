#!/usr/bin/env bash
# Functional and structural tests for the final credential publication guard.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

tmp="$(make_temp)"
secret='exact-provider-byte-string-987654321'
mkdir -p "$tmp/tree/sub" "$tmp/outside"
printf 'ordinary text\n' > "$tmp/tree/text.txt"
printf '\000\001clean\377binary\n' > "$tmp/tree/sub/data.bin"

run_scan() {
  RUNNER_TEMP="$tmp/runtime" GITHUB_STEP_SUMMARY="$tmp/summary" \
    bash -c 'source "$1/scripts/lib/common.sh"; scan_final_workspace_for_credential "$2" "$3"' \
    scan "$ROOT" "$tmp/tree" "$secret" >"$tmp/stdout" 2>"$tmp/stderr"
}

run_scan
t "clean text and binary tree passes" "0" "$?"

RUNNER_TEMP="$tmp/empty-runtime" bash -c \
  'source "$1/scripts/lib/common.sh"; scan_final_workspace_for_credential "$2" ""' \
  empty "$ROOT" "$tmp/tree"
t "empty credential is a no-op" "0" "$?"

printf 'prefix %s suffix\n' "$secret" > "$tmp/tree/text.txt"
run_scan
t "text credential is blocked" "1" "$?"
t "text detection category" "AGENT_CREDENTIAL_LEAK_BLOCKED" "$(cat "$tmp/runtime/failure_category")"
printf 'ordinary text\n' > "$tmp/tree/text.txt"

printf '\000prefix%s\377suffix' "$secret" > "$tmp/tree/sub/data.bin"
run_scan
t "binary credential is blocked" "1" "$?"
printf '\000\001clean\377binary\n' > "$tmp/tree/sub/data.bin"

printf '%s' "$secret" > "$tmp/outside/secret-file"
ln -s "$tmp/outside/secret-file" "$tmp/tree/follow-me"
run_scan
t "symlink is not followed" "0" "$?"
rm "$tmp/tree/follow-me"
ln -s "target-$secret" "$tmp/tree/leaking-link"
run_scan
t "symlink target text is blocked" "1" "$?"
rm "$tmp/tree/leaking-link"

touch "$tmp/tree/name-$secret"
run_scan
t "credential in filename is blocked" "1" "$?"
rm "$tmp/tree/name-$secret"

RUNNER_TEMP="$tmp/error-runtime" GITHUB_STEP_SUMMARY="$tmp/error-summary" \
  bash -c 'source "$1/scripts/lib/common.sh"; scan_final_workspace_for_credential "$2" "$3"' \
  error "$ROOT" "$tmp/missing-tree" "$secret" >"$tmp/error-stdout" 2>"$tmp/error-stderr"
t "scanner errors fail closed" "1" "$?"
t "scanner error category" "AGENT_CREDENTIAL_LEAK_BLOCKED" "$(cat "$tmp/error-runtime/failure_category")"

for output in "$tmp/stdout" "$tmp/stderr" "$tmp/summary" "$tmp/error-stdout" "$tmp/error-stderr" "$tmp/error-summary"; do
  leaked=no
  [ -f "$output" ] && grep -Fq "$secret" "$output" && leaked=yes
  t "$(basename "$output") does not leak credential" "no" "$leaked"
done

printf 'before\ncredential=%s\nafter\n' "$secret" > "$tmp/agent.log"
RUNNER_TEMP="$tmp/redact-runtime" bash -c \
  'source "$1/scripts/lib/common.sh"; redacted_agent_log_tail "$2" "$3"' \
  redact "$ROOT" "$tmp/agent.log" "$secret" >"$tmp/redact-out" 2>"$tmp/redact-err"
t "redacted log tail hides exact credential" "absent" "$(grep -Fq "$secret" "$tmp/redact-err" && echo present || echo absent)"
t "redacted log tail emits fixed marker" "present" "$(grep -Fq '[REDACTED_SELECTED_CREDENTIAL]' "$tmp/redact-err" && echo present || echo absent)"

ordinary="$ROOT/scripts/run-agent-dispatch-container.sh"
repair="$ROOT/scripts/run-review-repair-agent-container.sh"
line_of() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }
ordinary_container_done="$(line_of "$ordinary" '[ "$container_status" -eq 0 ] || exit "$container_status"')"
ordinary_git_cleanup="$(line_of "$ordinary" 'if [ -e "$workspace_dir/.git" ]; then')"
ordinary_scan="$(line_of "$ordinary" 'scan_final_workspace_for_credential "$workspace_dir" "$agent_credential"')"
ordinary_patch="$(line_of "$ordinary" 'patch_file="$agent_root/agent.patch"')"
repair_container_done="$(line_of "$repair" '[ "$container_status" -eq 0 ] || exit "$container_status"')"
repair_git_guard="$(line_of "$repair" '[ ! -e "$workspace_dir/.git" ]')"
repair_scan="$(line_of "$repair" 'scan_final_workspace_for_credential "$workspace_dir" "${OPENROUTER_API_KEY:-}"')"
repair_patch="$(line_of "$repair" 'patch_file="$agent_root/repair.patch"')"
t "ordinary tests/container finish before credential scan" "yes" "$([ "$ordinary_container_done" -lt "$ordinary_scan" ] && echo yes || echo no)"
t "ordinary .git cleanup precedes credential scan" "yes" "$([ "$ordinary_git_cleanup" -lt "$ordinary_scan" ] && echo yes || echo no)"
t "ordinary scan precedes patch construction" "yes" "$([ "$ordinary_scan" -lt "$ordinary_patch" ] && echo yes || echo no)"
t "repair tests/container finish before credential scan" "yes" "$([ "$repair_container_done" -lt "$repair_scan" ] && echo yes || echo no)"
t "repair .git guard precedes credential scan" "yes" "$([ "$repair_git_guard" -lt "$repair_scan" ] && echo yes || echo no)"
t "repair scan precedes patch construction" "yes" "$([ "$repair_scan" -lt "$repair_patch" ] && echo yes || echo no)"
t "run-agent has no direct log tail" "absent" "$(grep -Eq '^[[:space:]]*tail .*AGENT_LOG' "$ROOT/scripts/run-agent.sh" && echo present || echo absent)"
t "all failure tails use redaction helper" "3" "$(grep -c 'redacted_agent_log_tail' "$ROOT/scripts/run-agent.sh")"

finish
