#!/usr/bin/env bash
# Provider broker tests - delegates to Node.js test runner.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v node >/dev/null 2>&1; then
  node "$ROOT/tests/test-provider-broker.mjs"
  exit $?
else
  echo "SKIP: node is required for provider broker tests"
  exit 0
fi