#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
ADAPTER="$ROOT/scripts/agents/claude-code.sh"
RUN_AGENT="$ROOT/scripts/run-agent.sh"

t "Claude adapter requires a nonempty trusted model" "yes" \
  "$(grep -Fq '[ -n "$model" ] || fail_with "$CAT_AGENT_AUTH" "Claude model is required"' "$ADAPTER" && echo yes || echo no)"
t "Claude adapter forwards exact model with --model" "yes" \
  "$(grep -Fq 'claude -p "$prompt" --model "$model"' "$ADAPTER" && echo yes || echo no)"
t "Claude adapter does not substitute an implicit model fallback" "yes" \
  "$(grep -Eq 'ANTHROPIC_MODEL|CLAUDE_MODEL' "$ADAPTER" && echo no || echo yes)"
t "Claude broker route is explicit trusted metadata" "yes" \
  "$(grep -Fq 'ANTHROPIC_BROKER_BASE_URL' "$ADAPTER" && grep -Fq 'ANTHROPIC_BASE_URL=$ANTHROPIC_BROKER_BASE_URL' "$ADAPTER" && echo yes || echo no)"
t "Claude direct path does not require broker base" "yes" \
  "$(grep -Fq 'if [ -n "${ANTHROPIC_BROKER_BASE_URL:-}" ]' "$ADAPTER" && grep -Fq 'else' "$ADAPTER" && echo yes || echo no)"
t "Claude fallback has dedicated agent branch" "yes" \
  "$(grep -Fq 'claude-code)' "$RUN_AGENT" && echo yes || echo no)"
t "Claude fallback uses Claude-specific model only" "yes" \
  "$(grep -Fq '${CLAUDE_MODEL:-claude-sonnet-5}' "$RUN_AGENT" && echo yes || echo no)"
t "Claude fallback never inherits OpenRouter default" "yes" \
  "$(awk '/claude-code\)/,/;;/' "$RUN_AGENT" | grep -Fq 'OPENROUTER_MODEL' && echo no || echo yes)"

finish
