#!/usr/bin/env bash
# Cleanup helpers for disposable review-repair host staging directories.
set -uo pipefail

cleanup_review_repair_staging() { # <staging-root> <runner-temp>
  local staging_root="$1" runner_temp="$2"
  case "$staging_root" in
    "$runner_temp"/review-repair-agent.*)
      [ -d "$staging_root" ] || return 0
      rm -rf -- "$staging_root"
      ;;
    "")
      return 0
      ;;
    *)
      printf '[ERROR] refusing to remove unexpected review-repair staging path\n' >&2
      return 1
      ;;
  esac
}
