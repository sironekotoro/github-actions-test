#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
PARSE="$ROOT/scripts/parse-task.mjs"

run_dispatch() { # <tmp> <json>
  local tmp="$1" payload="$2"
  ( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" DISPATCH_INPUTS="$payload" \
      node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
}

base='{"task_id":"safe-task_1.2","target_repository":"sironekotoro/github-actions-test","title":"Safe title","prompt":"Do the work."}'

tmp="$(make_temp)"; run_dispatch "$tmp" "$base"; code=$?
t "bounded safe payload remains accepted" "0|safe-task_1.2" "$code|$(jq -r .task_id "$tmp/task.json")"

# Values written to GITHUB_OUTPUT must never permit multiline command-file injection.
tmp="$(make_temp)"
payload="$(jq -cn --arg title $'bad\nrunner_mode=github' '{task_id:"t1",target_repository:"sironekotoro/github-actions-test",title:$title,prompt:"x"}')"
run_dispatch "$tmp" "$payload"; code=$?
t "multiline title is rejected before GITHUB_OUTPUT" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

tmp="$(make_temp)"; payload='{"task_id":"../escape","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"x"}'
run_dispatch "$tmp" "$payload"; code=$?
t "unsafe task branch id is rejected" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

tmp="$(make_temp)"; payload='{"task_id":"safe..bad","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"x"}'
run_dispatch "$tmp" "$payload"; code=$?
t "double-dot task id is rejected" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

tmp="$(make_temp)"; payload='{"task_id":"t1","target_repository":"https://github.com/sironekotoro/github-actions-test","title":"t","prompt":"x"}'
run_dispatch "$tmp" "$payload"; code=$?
t "target repository requires owner/name grammar" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

for runtime in 0 46 nope 1.5; do
  tmp="$(make_temp)"
  payload="$(jq -cn --arg runtime "$runtime" '{task_id:"t1",target_repository:"sironekotoro/github-actions-test",title:"t",prompt:"x",max_runtime:$runtime}')"
  run_dispatch "$tmp" "$payload"; code=$?
  t "invalid max_runtime=$runtime fails closed" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"
done

tmp="$(make_temp)"; payload='{"task_id":"t1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"x","max_runtime":"045"}'
run_dispatch "$tmp" "$payload"; code=$?
t "valid runtime is canonicalized" "0|45" "$code|$(jq -r .max_runtime "$tmp/task.json")"

# workflow_dispatch exposes `model`; normalize it into requested_model.
tmp="$(make_temp)"; payload='{"task_id":"t1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"x","model":"openrouter/deepseek/deepseek-v4-flash"}'
run_dispatch "$tmp" "$payload"; code=$?
t "workflow dispatch model alias is preserved" "0|openrouter/deepseek/deepseek-v4-flash" "$code|$(jq -r .requested_model "$tmp/task.json")"

tmp="$(make_temp)"; payload='{"task_id":"t1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"x","requested_model":"a/model","model":"b/model"}'
run_dispatch "$tmp" "$payload"; code=$?
t "conflicting model fields fail closed" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

tmp="$(make_temp)"; payload='{"task_id":"t1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"x","requested_model":"bad model"}'
run_dispatch "$tmp" "$payload"; code=$?
t "model grammar rejects whitespace" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

# Prompt size is bounded by UTF-8 bytes while normal multiline prompts remain valid.
tmp="$(make_temp)"
payload="$(node -e 'process.stdout.write(JSON.stringify({task_id:"t1",target_repository:"sironekotoro/github-actions-test",title:"t",prompt:"x".repeat(65537)}))')"
run_dispatch "$tmp" "$payload"; code=$?
t "oversized prompt fails closed" "1|INVALID_PAYLOAD" "$code|$(cut -d: -f1 < "$tmp/stderr.log")"

tmp="$(make_temp)"
payload="$(jq -cn --arg prompt $'line one\nline two' '{task_id:"t1",target_repository:"sironekotoro/github-actions-test",title:"t",prompt:$prompt}')"
run_dispatch "$tmp" "$payload"; code=$?
t "normal multiline prompt remains accepted" "0|line one|line two" "$code|$(jq -r '.prompt | split("\n") | join("|")' "$tmp/task.json")"

finish
