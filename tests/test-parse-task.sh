#!/usr/bin/env bash
# Test 9: task payload parsing (malformed, fenced JSON, dispatch inputs)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

PARSE="$ROOT/scripts/parse-task.mjs"

# build an event.json with the given issue body
write_event() { # <tmp> <body>
  node -e '
    const fs = require("fs");
    const body = process.argv[1];
    const file = process.argv[2];
    fs.writeFileSync(file, JSON.stringify({ issue: { number: 7, title: "t", body } }));
  ' "$2" "$1/event.json"
}

run_parse_issue() { # <tmp> <body>
  write_event "$1" "$2"
  ( RUNNER_TEMP="$1" GITHUB_OUTPUT="$1/out.txt" EVENT_PATH="$1/event.json" \
      node "$PARSE" >"$1/stdout.log" 2>"$1/stderr.log" )
  local code=$?
  local err=""; [ -f "$1/stderr.log" ] && err="$(cat "$1/stderr.log")"
  echo "$code|$err"
}

valid='{"task_id":"t1","target_repository":"sironekotoro/github-actions-test","title":"hi","prompt":"do the thing"}'

tmp="$(make_temp)"
res="$(run_parse_issue "$tmp" "$valid")"
t "T9a whole-body JSON accepted" "0" "$(echo "$res" | cut -d'|' -f1)"

tmp="$(make_temp)"
body="intro
\`\`\`json
$valid
\`\`\`
outro"
res="$(run_parse_issue "$tmp" "$body")"
t "T9b fenced json block accepted" "0" "$(echo "$res" | cut -d'|' -f1)"

tmp="$(make_temp)"
res="$(run_parse_issue "$tmp" "this is not json at all")"
t "T9c malformed body rejected" "1|INVALID_PAYLOAD: could not parse a JSON task payload from the body: tried top-level JSON parse, fenced code block, and first JSON line — none succeeded" "$(echo "$res" | cut -d'|' -f1-2 | tr '\n' ' ' | sed 's/ *$//')"

tmp="$(make_temp)"
res="$(run_parse_issue "$tmp" '{"task_id":"t1"}')"
t "T9d missing required field rejected" "1|INVALID_PAYLOAD: missing required field: target_repository" "$(echo "$res" | cut -d'|' -f1-2)"

# Fenced JSON with invalid content reports which stage failed
tmp="$(make_temp)"
body="intro
\`\`\`json
{invalid json content}
\`\`\`
outro"
res="$(run_parse_issue "$tmp" "$body")"
t "T9f fenced invalid JSON reports fenced parse error" "1|INVALID_PAYLOAD: fenced JSON block found but its content is not valid JSON" "$(echo "$res" | cut -d'|' -f1-2 | sed 's/\.$//' | sed 's/: Expected property.*//')"

# dispatch inputs
tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
    DISPATCH_INPUTS='{"task_id":"d1","target_repository":"sironekotoro/github-actions-test","title":"d","prompt":"x"}' \
    node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
t "T9g dispatch inputs accepted" "0" "$code"

tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
    DISPATCH_INPUTS='{"task_id":"d-runner","target_repository":"sironekotoro/github-actions-test","title":"d","prompt":"x","runner_mode":"self-hosted"}' \
    node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
t "T9g1 explicit self-hosted runner mode accepted" "0|self-hosted" "$code|$(jq -r '.runner_mode' "$tmp/task.json")"

tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
    DISPATCH_INPUTS='{"task_id":"d-default","target_repository":"sironekotoro/github-actions-test","title":"d","prompt":"x"}' \
    node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
t "T9g2 omitted runner mode defaults to github" "0|github" "$code|$(jq -r '.runner_mode' "$tmp/task.json")"

tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
    DISPATCH_INPUTS='{"task_id":"d-override","target_repository":"sironekotoro/github-actions-test","title":"d","prompt":"x","requested_model":"openrouter/example/model","max_runtime":"17"}' \
    node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
t "T9g2a task model and runtime are preserved" "0|openrouter/example/model|17|17" "$code|$(jq -r '.requested_model' "$tmp/task.json")|$(jq -r '.max_runtime' "$tmp/task.json")|$(awk -F= '$1 == "max_runtime" {print $2}' "$tmp/out.txt")"

tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
    DISPATCH_INPUTS='{"task_id":"d-invalid-runner","target_repository":"sironekotoro/github-actions-test","title":"d","prompt":"x","runner_mode":"unknown"}' \
    node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
err=""; [ -f "$tmp/stderr.log" ] && err="$(cut -d: -f1 < "$tmp/stderr.log")"
t "T9g3 unknown runner mode fails closed" "1|INVALID_PAYLOAD" "$code|$err"

# malformed dispatch inputs
tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" DISPATCH_INPUTS='{not json' \
    node "$PARSE" >/dev/null 2>"$tmp/stderr.log" )
code=$?
err=""; [ -f "$tmp/stderr.log" ] && err="$(cat "$tmp/stderr.log" | cut -d: -f1)"
t "T9h malformed dispatch inputs rejected" "1|INVALID_PAYLOAD" "$code|$err"

finish
