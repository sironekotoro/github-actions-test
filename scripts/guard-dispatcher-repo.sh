#!/usr/bin/env bash
# Verify that the central workflow is actually running from the expected
# dispatcher checkout. This is the first half of the cross-repo double guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

expected="$(canonicalize_repo "${GITHUB_REPOSITORY:-}")"
remote="$(canonicalize_repo "$(repo_remote_url)")"

if [ -z "$expected" ] || [ -z "$remote" ] || [ "$expected" != "$remote" ]; then
  log_error "dispatcher repository identity mismatch expected=$expected remote=$remote"
  log_error "AGENT_NOT_STARTED=REPOSITORY_IDENTITY_MISMATCH"
  fail_with "$CAT_REPO_MISMATCH" "dispatcher expected=$expected remote=$remote AGENT_NOT_STARTED"
fi

echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| dispatcher checkout | \`$remote\` |"
log_info "dispatcher repository identity OK ($expected)"
