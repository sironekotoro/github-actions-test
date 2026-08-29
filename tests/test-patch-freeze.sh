#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
ordinary="$ROOT/scripts/run-agent-dispatch-container.sh"
repair="$ROOT/scripts/run-review-repair-agent-container.sh"
helper="$ROOT/scripts/run-isolated-repository-tests.sh"
line_of() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

for wrapper in "$ordinary" "$repair"; do
  patch="$(line_of "$wrapper" 'patch_file="$agent_root/')"
  frozen="$(line_of "$wrapper" 'chmod 400 "$patch_file"')"
  tests="$(line_of "$wrapper" 'run-isolated-repository-tests.sh')"
  apply="$(line_of "$wrapper" 'apply_agent_patch "$target_dir"')"
  name="$(basename "$wrapper")"
  t "$name constructs patch before tests" "yes" "$([ "$patch" -lt "$tests" ] && echo yes || echo no)"
  t "$name freezes patch before tests" "yes" "$([ "$frozen" -lt "$tests" ] && echo yes || echo no)"
  t "$name imports only after tests pass" "yes" "$([ "$tests" -lt "$apply" ] && echo yes || echo no)"
  t "$name no longer executes npm test in agent container" "absent" "$(grep -q 'npm test' "$wrapper" && echo present || echo absent)"
done

t "test helper copies source into disposable workspace" "yes" "$(grep -q 'tar -C "$source_dir" --exclude=.git' "$helper" && grep -q 'tar -C "$test_dir" -xf -' "$helper" && echo yes || echo no)"
t "test container mounts only disposable test workspace" "yes" "$(grep -q 'src=\$test_dir,dst=/workspace' "$helper" && ! grep -q 'src=\$source_dir,dst=/workspace' "$helper" && echo yes || echo no)"
t "repository tests have no network" "yes" "$(grep -q -- '--network none' "$helper" && echo yes || echo no)"
t "repository tests scrub provider and GitHub credentials" "yes" "$(grep -q 'unset OPENROUTER_API_KEY OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY' "$helper" && grep -q 'unset AGENT_CREDENTIAL_VALUE AGENT_CREDENTIAL_PROFILE GH_TOKEN GITHUB_TOKEN' "$helper" && echo yes || echo no)"
t "test container receives no provider credential env" "yes" "$(! grep -Eq -- '--env (OPENROUTER_API_KEY|OPENAI_API_KEY|CODEX_API_KEY|ANTHROPIC_API_KEY|AGENT_CREDENTIAL_VALUE|GH_TOKEN|GITHUB_TOKEN)' "$helper" && echo yes || echo no)"

finish
