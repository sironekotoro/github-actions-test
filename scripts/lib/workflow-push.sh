#!/usr/bin/env bash
# Helpers for deciding whether a trusted workflow-write credential is needed.
# These operate only on the checked-out repository state; task/prompt text
# never participates in credential selection.
set -uo pipefail

workflow_push_paths() {
  {
    git diff --name-only -z
    git diff --cached --name-only -z
    git ls-files --others --exclude-standard -z
  } | sort -zu
}

workflow_push_validate_paths() {
  local path
  while IFS= read -r -d '' path; do
    case "$path" in
      ''|/*|.|..|../*|*/../*)
        fail_with "$CAT_REPO_MISMATCH" "repository diff contains an invalid path"
        ;;
    esac
  done < <(workflow_push_paths)
}

workflow_push_diff_contains_workflows() {
  local path
  while IFS= read -r -d '' path; do
    [ "$path" = .github/workflows ] && return 0
    case "$path" in .github/workflows/*) return 0 ;; esac
  done < <(workflow_push_paths)
  return 1
}
