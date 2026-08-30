#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
PARSER="$ROOT/scripts/parse-review-repair.mjs"

make_context() { # <tmp> <comments-json>
  local tmp="$1" comments="$2" metadata b64 writer='agent-dispatch-app[bot]'
  metadata="$(jq -cnS --arg writer "$writer" '{
    schema:"agent-dispatch-task/v1",task_id:"app-principal",target_repository:"sironekotoro/github-actions-test",
    source:"issue#124",title:"repair",prompt:"Implement safely.",created_at:"2026-08-30T00:00:00Z",
    requested_model:"",max_runtime:"",dry_run:false,dispatcher_repository:"sironekotoro/github-actions-test",
    writer_login:$writer}')"
  b64="$(printf '%s' "$metadata" | base64 | tr -d '\n')"
  jq -cn --arg writer "$writer" --arg body "<!-- agent-dispatch-task:v1:$b64 -->" '{
    number:125,state:"open",merged_at:null,draft:false,body:$body,user:{login:$writer,type:"Bot"},
    base:{ref:"master",repo:{full_name:"sironekotoro/github-actions-test"}},
    head:{ref:"agent/app-principal",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{full_name:"sironekotoro/github-actions-test"}}}' > "$tmp/pr.json"
  jq -cn '{id:900,state:"CHANGES_REQUESTED",body:"Fix it.",submitted_at:"2026-08-30T01:00:00Z",
    commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",user:{login:"sironekotoro"}}' > "$tmp/review.json"
  printf '%s\n' "$comments" > "$tmp/comments.json"
}

run_parser() { # <tmp> [executor]
  local tmp="$1" executor="${2:-false}"
  local -a extra=()
  if [ "$executor" = true ]; then
    extra=(EXECUTOR_RESUME=true EXPECTED_PR_NUMBER=125 EXPECTED_REVIEW_ID=900 \
      EXPECTED_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa EXPECTED_ATTEMPT=1)
  fi
  env RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" TASK_FILE="$tmp/task.json" \
    PR_FILE="$tmp/pr.json" REVIEW_FILE="$tmp/review.json" COMMENTS_FILE="$tmp/comments.json" \
    REVIEW_REPAIR_ENABLED=true REVIEW_REPAIR_MAX=3 STRICT_REVIEWER=true ACTOR_ALLOWLIST=sironekotoro \
    TARGET_REPOSITORY=sironekotoro/github-actions-test DISPATCHER_REPOSITORY=sironekotoro/github-actions-test \
    REVIEW_DECISION=CHANGES_REQUESTED "${extra[@]}" \
    node "$PARSER" > "$tmp/stdout" 2> "$tmp/stderr"
}

decision_of() { sed -n 's/^decision=//p' "$1/out" 2>/dev/null | tail -n 1; }

# A legacy workflow-token marker has a different principal and must not be
# accepted as authoritative state for an App-authored agent PR.
tmp="$(make_temp)"
foreign='[{"user":{"login":"github-actions[bot]"},"body":"<!-- agent-review-repair:v1 status=started review_id=900 attempt=1 -->"}]'
make_context "$tmp" "$foreign"
run_parser "$tmp"
t 'foreign GITHUB_TOKEN marker is ignored for App-authored PR' 'run|1' \
  "$(decision_of "$tmp")|$(jq -r .review.attempt "$tmp/task.json")"

# The App principal recorded in immutable PR metadata is authoritative.
tmp="$(make_temp)"
trusted='[{"user":{"login":"agent-dispatch-app[bot]"},"body":"<!-- agent-review-repair:v1 status=started review_id=900 attempt=1 -->"}]'
make_context "$tmp" "$trusted"
run_parser "$tmp"
t 'App-authored reservation marker is trusted' duplicate-review "$(decision_of "$tmp")"

# Executor resume accepts the exact reservation when the App principal wrote it.
tmp="$(make_temp)"
make_context "$tmp" "$trusted"
run_parser "$tmp" true
t 'App-authored reservation satisfies executor provenance' '0|run|1' \
  "$?|$(decision_of "$tmp")|$(jq -r .review.attempt "$tmp/task.json")"

# Once the App principal claims the executor, duplicate execution is blocked.
tmp="$(make_temp)"
claimed='[
 {"user":{"login":"agent-dispatch-app[bot]"},"body":"<!-- agent-review-repair:v1 status=started review_id=900 attempt=1 -->"},
 {"user":{"login":"agent-dispatch-app[bot]"},"body":"<!-- agent-review-repair:v1 status=executor-started review_id=900 attempt=1 -->"}
]'
make_context "$tmp" "$claimed"
run_parser "$tmp" true
t 'App-authored executor marker prevents duplicate executor' '0|duplicate-review' \
  "$?|$(decision_of "$tmp")"

finish
