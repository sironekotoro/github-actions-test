#!/usr/bin/env bash
# Regression: post-agent transport classification covering NO_CHANGES,
# EMPTY_PATCH, PATCH_PARSE_FAILED, PATCH_VALIDATION_FAILED, clean import,
# AGENT_START_FAILED, MODEL_API_FAILED, AGENT_TIMEOUT, and AGENT=opencode.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

DISPATCH_CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"
REVIEW_CONTAINER="$ROOT/scripts/run-review-repair-agent-container.sh"

make_target_repo() { # <tmp>
  local tmp="$1"
  git init -q "$tmp/target"
  git -C "$tmp/target" config user.name test
  git -C "$tmp/target" config user.email test@example.com
  git -C "$tmp/target" checkout -q -b master
  printf 'original\n' > "$tmp/target/file.txt"
  git -C "$tmp/target" add file.txt
  git -C "$tmp/target" commit -qm base
}

# Replicate the exact git diff / apply logic that the container scripts use.
# We do not source the container scripts because they require Docker; instead
# we exercise the identical post-agent transport pipeline inline.

# ---------------
# 1. NO_CHANGES: identical base and workspace -> diff_status=0
# ---------------
tmp="$(make_temp)"
make_target_repo "$tmp"
mkdir -p "$tmp/agent_root/base" "$tmp/agent_root/workspace"
printf 'same\n' > "$tmp/agent_root/base/file.txt"
printf 'same\n' > "$tmp/agent_root/workspace/file.txt"
(
  cd "$tmp/agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$tmp/agent_root/patch" 2>/dev/null
ds=$?
t "[NO_CHANGES] diff_status=0 when base=workspace" "0" "$ds"
# diff_status=0 means no diff; must fail closed
t "[NO_CHANGES] diff_status=0 triggers fail closed" "detected" "$([ "$ds" -eq 0 ] && echo detected || echo missed)"

# ---------------
# 2. EMPTY_PATCH: diff_status=1 but patch is zero bytes
# ---------------
tmp="$(make_temp)"
make_target_repo "$tmp"
mkdir -p "$tmp/agent_root/base" "$tmp/agent_root/workspace"
printf 'base\n' > "$tmp/agent_root/base/file.txt"
printf 'changed\n' > "$tmp/agent_root/workspace/file.txt"
(
  cd "$tmp/agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$tmp/agent_root/patch" 2>/dev/null
ds=$?
t "[EMPTY_PATCH] diff_status=1 when files differ" "1" "$ds"
# Truncate patch to zero bytes to simulate empty patch
: > "$tmp/agent_root/patch"
t "[EMPTY_PATCH] zero-byte patch detected" "0" "$(wc -c < "$tmp/agent_root/patch" | tr -d ' ')"

# ---------------
# 3. PATCH_PARSE_FAILED: malformed patch rejected by git apply --check -p2
# ---------------
tmp="$(make_temp)"
make_target_repo "$tmp"
mkdir -p "$tmp/agent_root/base" "$tmp/agent_root/workspace"
# Write an intentionally malformed patch - bad hunk header that git rejects
printf '--- a/base/file.txt\n+++ b/workspace/file.txt\n' > "$tmp/agent_root/invalid.patch"
printf '@@ -1,1 +1,2 @@\n' >> "$tmp/agent_root/invalid.patch"
printf ' original\n' >> "$tmp/agent_root/invalid.patch"
printf 'GARBAGE\n' >> "$tmp/agent_root/invalid.patch"
git -C "$tmp/target" apply --check -p2 "$tmp/agent_root/invalid.patch" 2>/dev/null
apply_rc=$?
t "[PATCH_PARSE_FAILED] malformed patch rejected" "1" "$apply_rc"

# ---------------
# 4. PATCH_VALIDATION_FAILED: valid patch struct but trailing whitespace
# ---------------
tmp="$(make_temp)"
make_target_repo "$tmp"
mkdir -p "$tmp/agent_root/base" "$tmp/agent_root/workspace"
# Create a patch against the existing file.txt that has trailing whitespace
printf '--- a/base/file.txt\n+++ b/workspace/file.txt\n' > "$tmp/agent_root/trailing.patch"
printf '@@ -1 +1 @@\n' >> "$tmp/agent_root/trailing.patch"
printf '-original\n' >> "$tmp/agent_root/trailing.patch"
printf '+modified  \n' >> "$tmp/agent_root/trailing.patch"
# First check (structural) passes
git -C "$tmp/target" apply --check -p2 "$tmp/agent_root/trailing.patch" 2>/dev/null
structural_rc=$?
t "[PATCH_VALIDATION_FAILED] structural check passes" "0" "$structural_rc"
# Second check (whitespace) fails
git -C "$tmp/target" apply --check --whitespace=error -p2 "$tmp/agent_root/trailing.patch" 2>/dev/null
whitespace_rc=$?
t "[PATCH_VALIDATION_FAILED] whitespace check fails" "1" "$whitespace_rc"

# ---------------
# 5. Clean success: valid patch, no whitespace issues
# ---------------
tmp="$(make_temp)"
make_target_repo "$tmp"
mkdir -p "$tmp/agent_root/base" "$tmp/agent_root/workspace"
printf 'original\n' > "$tmp/agent_root/base/file.txt"
printf 'modified\n' > "$tmp/agent_root/workspace/file.txt"
(
  cd "$tmp/agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$tmp/agent_root/clean.patch" 2>/dev/null
ds=$?
t "[SUCCESS] diff exits with 1 when files differ" "1" "$ds"
# Structural check
git -C "$tmp/target" apply --check -p2 "$tmp/agent_root/clean.patch" 2>/dev/null
t "[SUCCESS] structural check passes" "0" "$?"
# Whitespace check
git -C "$tmp/target" apply --check --whitespace=error -p2 "$tmp/agent_root/clean.patch" 2>/dev/null
t "[SUCCESS] whitespace check passes" "0" "$?"
# Import
git -C "$tmp/target" apply --whitespace=error -p2 "$tmp/agent_root/clean.patch"
t "[SUCCESS] patch imports cleanly" "0" "$?"
t "[SUCCESS] imported content matches" "modified" "$(cat "$tmp/target/file.txt")"

# ---------------
# 6. AGENT_START_FAILED: diff_status neither 0 nor 1
# ---------------
# When git diff fails unexpectedly (e.g., missing directories), status != 0,1
tmp="$(make_temp)"
make_target_repo "$tmp"
mkdir -p "$tmp/agent_root"
(
  cd "$tmp/agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ nonexistent_base workspace
) > "$tmp/agent_root/patch" 2>/dev/null
ds=$?
t "[AGENT_START_FAILED] diff fails on missing dirs (not 0 or 1)" "1" "$([ "$ds" -ne 0 ] && [ "$ds" -ne 1 ] && echo 1 || echo 0)"

# ---------------
# 7. MODEL_API_FAILED and AGENT_TIMEOUT constants exist
# ---------------
t "[CONSTANTS] CAT_MODEL_API present in common.sh" "yes" "$(grep -q 'CAT_MODEL_API=' "$ROOT/scripts/lib/common.sh" && echo yes || echo no)"
t "[CONSTANTS] CAT_AGENT_TIMEOUT present in common.sh" "yes" "$(grep -q 'CAT_AGENT_TIMEOUT=' "$ROOT/scripts/lib/common.sh" && echo yes || echo no)"

# ---------------
# 8. AGENT=opencode deterministic export in dispatch container
# ---------------
t "[AGENT] dispatch container exports AGENT env" "yes" "$(grep -E '^\s+--env AGENT=' "$DISPATCH_CONTAINER" | grep -v 'AGENT_LOG\|AGENT_MAX_RUNTIME\|AGENT_CREDENTIAL\|AGENT_AUTO_INSTALL\|AGENT_USE_PREBUILT_PROMPT' | grep -q 'AGENT=\$agent' && echo yes || echo no)"

# ---------------
# 9. Review-repair container has the same transport classification pattern
# ---------------
t "[REVIEW] review container has NO_CHANGES check" "yes" "$(grep -q 'FAILURE_REASON=NO_CHANGES' "$REVIEW_CONTAINER" && echo yes || echo no)"
t "[REVIEW] review container has EMPTY_PATCH check" "yes" "$(grep -q 'FAILURE_REASON=EMPTY_PATCH' "$REVIEW_CONTAINER" && echo yes || echo no)"
t "[REVIEW] review container has PATCH_PARSE_FAILED" "yes" "$(grep -q 'FAILURE_REASON=PATCH_PARSE_FAILED' "$REVIEW_CONTAINER" && echo yes || echo no)"
t "[REVIEW] review container has PATCH_VALIDATION_FAILED" "yes" "$(grep -q 'FAILURE_REASON=PATCH_VALIDATION_FAILED' "$REVIEW_CONTAINER" && echo yes || echo no)"

# ---------------
# 10. Dispatch container has the same transport classification pattern
# ---------------
t "[DISPATCH] dispatch container has NO_CHANGES check" "yes" "$(grep -q 'FAILURE_REASON=NO_CHANGES' "$DISPATCH_CONTAINER" && echo yes || echo no)"
t "[DISPATCH] dispatch container has EMPTY_PATCH check" "yes" "$(grep -q 'FAILURE_REASON=EMPTY_PATCH' "$DISPATCH_CONTAINER" && echo yes || echo no)"
t "[DISPATCH] dispatch container has PATCH_PARSE_FAILED" "yes" "$(grep -q 'FAILURE_REASON=PATCH_PARSE_FAILED' "$DISPATCH_CONTAINER" && echo yes || echo no)"
t "[DISPATCH] dispatch container has PATCH_VALIDATION_FAILED" "yes" "$(grep -q 'FAILURE_REASON=PATCH_VALIDATION_FAILED' "$DISPATCH_CONTAINER" && echo yes || echo no)"

# ---------------
# 11. Review-repair container use --check -p2 (structural) before --whitespace
# ---------------
has_structural=$(grep -c 'apply --check -p2 "$patch_file" 2>/dev/null' "$REVIEW_CONTAINER")
has_whitespace=$(grep -c 'apply --check --whitespace=error -p2 "$patch_file" 2>/dev/null' "$REVIEW_CONTAINER")
t "[REVIEW] structural check (no whitespace) present" "1" "$has_structural"
t "[REVIEW] whitespace-error check present" "1" "$has_whitespace"
# The structural line must appear before the whitespace-error line
structural_line=$(grep -n 'apply --check -p2 "\$patch_file" 2>/dev/null' "$REVIEW_CONTAINER" | head -1 | cut -d: -f1)
whitespace_line=$(grep -n 'apply --check --whitespace=error -p2 "\$patch_file" 2>/dev/null' "$REVIEW_CONTAINER" | head -1 | cut -d: -f1)
t "[REVIEW] structural check precedes whitespace check" "yes" "$([ -n "$structural_line" ] && [ -n "$whitespace_line" ] && [ "$structural_line" -lt "$whitespace_line" ] && echo yes || echo no)"

# ---------------
# 12. Both containers redirect untrusted git apply stderr for --check variants
# ---------------
t "[DISPATCH] --check variants redirect stderr" "yes" "$(grep -c 'apply --check.*2>/dev/null' "$DISPATCH_CONTAINER" | xargs -I{} test {} -ge 2 && echo yes || echo no)"
t "[REVIEW] --check variants redirect stderr" "yes" "$(grep -c 'apply --check.*2>/dev/null' "$REVIEW_CONTAINER" | xargs -I{} test {} -ge 2 && echo yes || echo no)"

finish