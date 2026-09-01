#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
ADAPTER="$ROOT/scripts/agents/claude-code.sh"

t "Claude adapter requires a nonempty trusted model" "yes" \
  "$(grep -Fq '[ -n "$model" ] || fail_with "$CAT_AGENT_AUTH" "Claude model is required"' "$ADAPTER" && echo yes || echo no)"
t "Claude adapter forwards exact model with --model" "yes" \
  "$(grep -Fq 'claude -p "$prompt" --model "$model"' "$ADAPTER" && echo yes || echo no)"
t "Claude adapter does not substitute an implicit model fallback" "yes" \
  "$(grep -Eq 'ANTHROPIC_MODEL|CLAUDE_MODEL' "$ADAPTER" && echo no || echo yes)"

finish
