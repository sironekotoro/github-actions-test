#!/usr/bin/env bash
# Run the full local test suite for the agent-dispatch infrastructure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"

echo "== agent-dispatch test suite =="
overall=0
for t in "$TESTS"/test-*.sh; do
  echo ""
  echo "### $(basename "$t")"
  if bash "$t"; then
    echo "SUITE_OK: $(basename "$t")"
  else
    echo "SUITE_FAIL: $(basename "$t")"
    overall=1
  fi
done

# Run Node.js-based test suites
for t in "$TESTS"/test-*.mjs; do
  echo ""
  echo "### $(basename "$t")"
  if node "$t"; then
    echo "SUITE_OK: $(basename "$t")"
  else
    echo "SUITE_FAIL: $(basename "$t")"
    overall=1
  fi
done
echo ""
echo "== summary =="
[ "$overall" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$overall"