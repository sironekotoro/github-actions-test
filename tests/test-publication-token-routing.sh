#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

action="$ROOT/.github/actions/agent-dispatch/action.yml"
dispatcher="$ROOT/.github/workflows/review-repair.yml"
review="$ROOT/.github/workflows/review-repair-executor.yml"

step_block() {
  local file="$1" target="$2"
  awk -v target="$target" '
    /^[[:space:]]+- name: / {
      if (inside) exit
      line=$0
      sub(/^[[:space:]]+- name: /, "", line)
      if (line == target) inside=1
    }
    inside { print }
  ' "$file"
}

contains() {
  local haystack="$1" needle="$2"
  printf '%s\n' "$haystack" | grep -Fq -- "$needle" && echo yes || echo no
}

not_contains() {
  local haystack="$1" needle="$2"
  printf '%s\n' "$haystack" | grep -Fq -- "$needle" && echo no || echo yes
}

app_create="$(step_block "$action" 'Create target-scoped GitHub App token')"
same_checkout="$(step_block "$action" 'Checkout same-repo target separately')"
same_prepare="$(step_block "$action" 'Prepare same-repo agent branch')"
same_commit="$(step_block "$action" 'Commit, push, and create same-repo PR')"
feedback="$(step_block "$action" 'Feedback and step summary')"
dispatcher_app="$(step_block "$dispatcher" 'Create same-repo target marker token')"
dispatcher_reserve="$(step_block "$dispatcher" 'Reserve review id and attempt')"
dispatcher_dispatch="$(step_block "$dispatcher" 'Dispatch self-hosted executor')"
dispatcher_feedback="$(step_block "$dispatcher" 'Dispatcher feedback and summary')"
review_app="$(step_block "$review" 'Create target-scoped executor token')"
review_resume="$(step_block "$review" 'Resume exact existing PR branch')"
review_marker="$(step_block "$review" 'Record executor start on target PR')"
review_commit="$(step_block "$review" 'Test, commit, and push same existing PR branch')"
review_feedback="$(step_block "$review" 'Executor feedback and summary')"
review_context_same="$(step_block "$review" 'Re-fetch and validate same-repo review request')"

# Ordinary Agent Dispatch: live same-repo publication must mint and use the
# target-scoped GitHub App token, while same-repo dry-run remains read-only on
# the workflow token.
t 'ordinary app token includes live same-repo path' yes \
  "$(contains "$app_create" "steps.target.outputs.mode == 'same' && steps.parse.outputs.dry_run != 'true'")"
t 'ordinary same checkout uses App token for live publication' yes \
  "$(contains "$same_checkout" "steps.app_token.outputs.token")"
t 'ordinary same checkout preserves workflow token only for dry-run' yes \
  "$(contains "$same_checkout" "steps.parse.outputs.dry_run == 'true' && inputs.github_token || steps.app_token.outputs.token")"
t 'ordinary same prepare uses App token' yes \
  "$(contains "$same_prepare" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'ordinary same commit and PR use App token' yes \
  "$(contains "$same_commit" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'ordinary same PR provenance uses App bot principal' yes \
  "$(contains "$same_commit" 'DISPATCH_PRINCIPAL: ${{ steps.app_token.outputs.app-slug }}[bot]')"
t 'ordinary same publication no longer uses workflow token' yes \
  "$(not_contains "$same_commit" 'GH_TOKEN: ${{ inputs.github_token }}')"
t 'ordinary control-plane feedback retains workflow token' yes \
  "$(contains "$feedback" 'GH_TOKEN: ${{ inputs.github_token }}')"

# Review Repair dispatcher: every trusted marker on the target PR must be
# authored by the same App principal recorded as the agent PR writer. Workflow
# dispatch itself remains on GITHUB_TOKEN because it is dispatcher control-plane
# traffic rather than target publication.
t 'same-repo dispatcher creates target marker App token' yes \
  "$(contains "$dispatcher_app" 'owner: ${{ steps.target.outputs.target_owner }}')"
t 'same-repo dispatcher scopes marker token to target repository' yes \
  "$(contains "$dispatcher_app" 'repositories: ${{ steps.target.outputs.target_name }}')"
t 'same-repo dispatcher marker token has read contents only' yes \
  "$(contains "$dispatcher_app" 'permission-contents: read')"
t 'same-repo dispatcher marker token has pull request write' yes \
  "$(contains "$dispatcher_app" 'permission-pull-requests: write')"
t 'same-repo reservation marker uses App token' yes \
  "$(contains "$dispatcher_reserve" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'executor workflow dispatch remains on GITHUB_TOKEN' yes \
  "$(contains "$dispatcher_dispatch" 'GH_TOKEN: ${{ github.token }}')"
t 'dispatcher target feedback marker uses App token' yes \
  "$(contains "$dispatcher_feedback" 'TARGET_GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'dispatcher source issue feedback retains GITHUB_TOKEN' yes \
  "$(contains "$dispatcher_feedback" 'DISPATCHER_GH_TOKEN: ${{ github.token }}')"

# Review Repair executor: reading/validation can keep GITHUB_TOKEN for
# same-repo, but branch git auth, marker writes, and the repair push must use the
# App token so provenance stays coherent and synchronize can start normal CI.
t 'review repair target token is created for same and cross repo' yes \
  "$(not_contains "$review_app" "if: steps.target.outputs.mode == 'cross'")"
t 'review repair same context stays read-only on workflow token' yes \
  "$(contains "$review_context_same" 'GH_TOKEN: ${{ github.token }}')"
t 'review repair git resume uses App token' yes \
  "$(contains "$review_resume" 'TARGET_GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'review repair executor-started marker uses App token' yes \
  "$(contains "$review_marker" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'review repair push uses App token' yes \
  "$(contains "$review_commit" 'PUSH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'review repair push no longer selects GITHUB_TOKEN' yes \
  "$(not_contains "$review_commit" 'github.token')"
t 'review repair final target marker uses App token' yes \
  "$(contains "$review_feedback" 'TARGET_GH_TOKEN: ${{ steps.app_token.outputs.token }}')"
t 'review repair source issue feedback retains GITHUB_TOKEN' yes \
  "$(contains "$review_feedback" 'DISPATCHER_GH_TOKEN: ${{ github.token }}')"

# Publication tokens stay narrowly scoped. No Actions/workflow-write permission
# is requested from actions/create-github-app-token.
t 'ordinary publication token requests contents write' yes \
  "$(contains "$app_create" 'permission-contents: write')"
t 'ordinary publication token requests pull requests write' yes \
  "$(contains "$app_create" 'permission-pull-requests: write')"
t 'ordinary publication token does not request actions write' yes \
  "$(not_contains "$app_create" 'permission-actions: write')"
t 'dispatcher marker token does not request actions write' yes \
  "$(not_contains "$dispatcher_app" 'permission-actions: write')"
t 'review publication token does not request actions write' yes \
  "$(not_contains "$review_app" 'permission-actions: write')"

finish
