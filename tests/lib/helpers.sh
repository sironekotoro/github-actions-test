#!/usr/bin/env bash
# Minimal assertion helpers for the test suite.
PASS=0
FAIL=0

t() { # <desc> <expected> <actual>
  local desc="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (expected [$exp] got [$act])"
  fi
}

finish() {
  echo "----"
  echo "PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ]
}

make_temp() {
  mktemp -d "${TMPDIR:-/tmp}/agent-tests.XXXXXX"
}