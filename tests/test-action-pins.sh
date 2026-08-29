#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

tmp="$(make_temp)"
refs="$tmp/action-refs.txt"
bad="$tmp/unpinned-action-refs.txt"
: > "$refs"
: > "$bad"

grep -RInE '^[[:space:]]*uses:[[:space:]]+' \
  "$ROOT/.github/workflows" "$ROOT/.github/actions" > "$refs" || true

while IFS= read -r line; do
  value="$(printf '%s\n' "$line" | sed -E 's#^.*uses:[[:space:]]*([^[:space:]#]+).*$#\1#')"
  case "$value" in
    ./*|docker://*) continue ;;
  esac
  if [[ "$value" != *@* ]]; then
    printf '%s\n' "$line" >> "$bad"
    continue
  fi
  revision="${value##*@}"
  if ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$line" >> "$bad"
  fi
done < "$refs"

t "all external GitHub Actions use immutable commit SHAs" "" "$(cat "$bad")"
t "checkout pin matches verified v4 commit" "yes" \
  "$(grep -Rq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$ROOT/.github" && echo yes || echo no)"
t "setup-node pin matches verified v4 commit" "yes" \
  "$(grep -Rq 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020' "$ROOT/.github" && echo yes || echo no)"
t "GitHub App token pin matches verified v3 commit" "yes" \
  "$(grep -Rq 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' "$ROOT/.github" && echo yes || echo no)"

finish
