#!/usr/bin/env bash
# Run untrusted repository tests on a disposable copy only after the
# agent-produced patch has already been frozen by the trusted wrapper.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

source_dir="${TEST_SOURCE_DIR:-}"
staging_root="${TEST_STAGING_ROOT:-}"
image="${TEST_IMAGE:-}"
runner_uid="${TEST_RUNNER_UID:-}"
runner_gid="${TEST_RUNNER_GID:-}"

[ -d "$source_dir" ] || fail_with "$CAT_AGENT_START" "isolated test source is missing"
[ -d "$staging_root" ] || fail_with "$CAT_AGENT_START" "isolated test staging root is missing"
[ -n "$image" ] || fail_with "$CAT_AGENT_START" "isolated test image is missing"
[ -n "$runner_uid" ] && [ -n "$runner_gid" ] \
  || fail_with "$CAT_AGENT_START" "isolated test uid/gid is missing"

test_dir="$staging_root/test-workspace"
rm -rf -- "$test_dir"
mkdir -p "$test_dir"
tar -C "$source_dir" --exclude=.git -cf - . | tar -C "$test_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not create disposable repository test workspace"

# Provider and GitHub credentials are intentionally unavailable to tests.
unset OPENROUTER_API_KEY OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY
unset AGENT_CREDENTIAL_VALUE AGENT_CREDENTIAL_PROFILE GH_TOKEN GITHUB_TOKEN

docker run --rm --init \
  --network none \
  --read-only \
  --user "$runner_uid:$runner_gid" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit="${ISOLATED_TEST_CONTAINER_PIDS_LIMIT:-512}" \
  --memory="${ISOLATED_TEST_CONTAINER_MEMORY:-4g}" \
  --mount "type=bind,src=$test_dir,dst=/workspace" \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=1g \
  --tmpfs /home/agent:rw,nosuid,nodev,noexec,mode=1777,size=512m \
  --workdir /workspace \
  --env HOME=/home/agent \
  --env XDG_CONFIG_HOME=/home/agent/.config \
  --env XDG_CACHE_HOME=/home/agent/.cache \
  --env RUNNER_TEMP=/tmp \
  "$image" bash -ceu '
    if [ -f package.json ]; then
      npm test
    fi
  '
