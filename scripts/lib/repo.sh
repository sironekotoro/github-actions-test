#!/usr/bin/env bash
# Repository helpers: canonical identity, remotes, default branch detection.
set -uo pipefail

# canonicalize_repo <owner/name|url> -> owner/name (lowercase, .git stripped)
canonicalize_repo() {
  local input="$1" out
  out="${input#https://github.com/}"
  out="${out#http://github.com/}"
  out="${out#git@github.com:}"
  out="${out#ssh://git@github.com/}"
  out="${out#git://github.com/}"
  out="${out#github.com/}"
  out="${out%.git}"
  out="${out%/}"
  out="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$out"
}

repo_remote_url() {
  git remote get-url origin 2>/dev/null || echo ""
}

# detect_default_branch <owner/name> -> branch name
detect_default_branch() {
  local repo="$1" b
  b="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && { b="${b#origin/}"; [ -n "$b" ] && { echo "$b"; return 0; }; }
  if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    b="$(gh api "repos/$repo" --jq .default_branch 2>/dev/null)" \
      && [ -n "$b" ] \
      && { echo "$b"; return 0; }
  fi
  for cand in master main; do
    if git ls-remote --heads origin "$cand" 2>/dev/null | grep -q "refs/heads/$cand$"; then
      echo "$cand"; return 0
    fi
  done
  echo "master"
}

# branch_exists_remote <branch> -> 0/1
branch_exists_remote() {
  git ls-remote --heads origin "$1" 2>/dev/null | grep -q "refs/heads/$1$"
}

# open_pr_for_branch <head_branch> -> 0/1 (needs GH_TOKEN)
open_pr_for_branch() {
  command -v gh >/dev/null 2>&1 || return 1
  local n
  n="$(gh pr list --head "$1" --state open --json number --jq 'length' 2>/dev/null || echo 0)"
  [ "$n" != "0" ]
}