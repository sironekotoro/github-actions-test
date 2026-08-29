#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
SCRIPT="$ROOT/scripts/build-review-matrix.sh"

run_matrix() { # <tmp>
  local tmp="$1"
  RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" \
    ALLOWLIST_FILE="$tmp/allowed.txt" REVIEW_TARGETS_FILE="$tmp/review.txt" \
    DISPATCHER_REPOSITORY="sironekotoro/github-actions-test" \
    bash "$SCRIPT" >"$tmp/stdout" 2>"$tmp/stderr"
}

# The review polling list is intentionally narrower than the ordinary dispatch allowlist.
tmp="$(make_temp)"
printf '%s\n' \
  'sironekotoro/github-actions-test' \
  'sironekotoro/zengin-pl' \
  'sironekotoro/sironekotoro-blog' > "$tmp/allowed.txt"
printf '%s\n' 'sironekotoro/zengin-pl' > "$tmp/review.txt"
run_matrix "$tmp"
status=$?
matrix="$(sed -n 's/^matrix=//p' "$tmp/out")"
t "narrow review target matrix succeeds" "0|1|sironekotoro/zengin-pl" \
  "$status|$(jq 'length' <<<"$matrix")|$(jq -r '.[0].repository' <<<"$matrix")"
t "ordinary allowlisted target is not polled unless explicitly enabled" "false" \
  "$(jq -e 'map(.repository) | index("sironekotoro/sironekotoro-blog") != null' <<<"$matrix" >/dev/null && echo true || echo false)"

# A polling target must remain authorized by the ordinary dispatch allowlist.
tmp="$(make_temp)"
printf '%s\n' 'sironekotoro/zengin-pl' > "$tmp/allowed.txt"
printf '%s\n' 'sironekotoro/sironekotoro-blog' > "$tmp/review.txt"
run_matrix "$tmp"
status=$?
t "review target outside dispatch allowlist fails closed" "1|TARGET_REPOSITORY_NOT_ALLOWED" \
  "$status|$(cat "$tmp/failure_category")"

# The dispatcher repository belongs to the same-repo event path, never the polling matrix.
tmp="$(make_temp)"
printf '%s\n' 'sironekotoro/github-actions-test' > "$tmp/allowed.txt"
printf '%s\n' 'sironekotoro/github-actions-test' > "$tmp/review.txt"
run_matrix "$tmp"
status=$?
t "dispatcher cannot enter cross-repo polling matrix" "1|TARGET_REPOSITORY_NOT_ALLOWED" \
  "$status|$(cat "$tmp/failure_category")"

# Duplicate entries are harmless and do not create duplicate matrix jobs.
tmp="$(make_temp)"
printf '%s\n' 'sironekotoro/zengin-pl' > "$tmp/allowed.txt"
printf '%s\n' 'sironekotoro/zengin-pl' 'SIRONEKOTORO/ZENGIN-PL' > "$tmp/review.txt"
run_matrix "$tmp"
status=$?
matrix="$(sed -n 's/^matrix=//p' "$tmp/out")"
t "duplicate review targets are deduplicated" "0|1" "$status|$(jq 'length' <<<"$matrix")"

finish
