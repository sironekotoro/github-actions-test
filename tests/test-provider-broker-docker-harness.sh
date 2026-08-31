#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT/scripts/provider-broker-docker-e2e.sh"

bash -n "$HARNESS"

grep -Fq 'docker exec -i "$agent_name" node - <<'"'"'EOF'"'"'' "$HARNESS" || {
  echo 'FAIL: broker E2E request probe must keep stdin open with docker exec -i' >&2
  exit 1
}

if grep -Fq 'docker exec "$agent_name" node - <<'"'"'EOF'"'"'' "$HARNESS"; then
  echo 'FAIL: non-interactive docker exec would discard the heredoc probe' >&2
  exit 1
fi

echo 'PASS: broker E2E heredoc is delivered through docker exec -i'
