#!/usr/bin/env bash
# Actor authorization: every actor involved in triggering the task must be in
# the allowlist. Public actors can never start the agent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ALLOWLIST="${ACTOR_ALLOWLIST:-sironekotoro}"
EVENT_NAME="${EVENT_NAME:-}"
GH_ACTOR="${GH_ACTOR:-}"
ISSUE_AUTHOR="${ISSUE_AUTHOR:-}"
ISSUE_SENDER="${ISSUE_SENDER:-}"

case "$EVENT_NAME" in
  workflow_dispatch)
    check_actor="$GH_ACTOR"
    label="actor"
    ;;
  issues)
    # both the issue author and whoever applied the label must be trusted
    check_actor="$ISSUE_AUTHOR $ISSUE_SENDER"
    label="issue author/labeler"
    ;;
  *)
    fail_with "$CAT_UNAUTHORIZED" "unsupported event $EVENT_NAME"
    ;;
esac

for a in $check_actor; do
  if [ -z "$a" ] || ! case "|$ALLOWLIST|" in *"|$a|"*) true;; *) false;; esac; then
    log_error "actor '$a' ($label) is not in the allowlist"
    fail_with "$CAT_UNAUTHORIZED" "actor '$a' is not authorized"
  fi
done

log_info "actor authorization OK ($check_actor)"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| authorized actor | \`$check_actor\` |"