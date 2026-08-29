#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

# Every external Docker base used by the isolated executor must be immutable.
# Tags may remain as human-readable context, but a sha256 digest is mandatory.
unpinned="$(grep -HnE '^FROM[[:space:]]+' "$ROOT"/docker/*.Dockerfile \
  | grep -Ev '^.*:FROM[[:space:]]+[^[:space:]]+@sha256:[0-9a-f]{64}([[:space:]]|$)' || true)"
t "all Docker base images are digest pinned" "" "$unpinned"

t "agent base is the production-verified node digest" "yes" \
  "$(grep -Fxq 'FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5' "$ROOT/docker/review-repair-agent.Dockerfile" && echo yes || echo no)"

t "egress base is the production-verified alpine digest" "yes" \
  "$(grep -Fxq 'FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d' "$ROOT/docker/review-repair-egress.Dockerfile" && echo yes || echo no)"

finish
