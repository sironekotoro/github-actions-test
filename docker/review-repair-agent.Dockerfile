# Built solely from the trusted dispatcher checkout. Target repository code is
# supplied only at runtime as an isolated .git-free working copy.
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

ARG CODEX_CLI_VERSION=0.147.0
ARG CLAUDE_CODE_VERSION=2.1.165

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates coreutils git jq \
    && npm install --global \
      opencode-ai@1.18.16 \
      "@openai/codex@${CODEX_CLI_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/run-agent.sh scripts/build-agent-prompt.sh scripts/build-review-prompt.sh scripts/agent-dispatcher.sh /opt/review-repair-runner/
COPY scripts/agents/ /opt/review-repair-runner/agents/
COPY scripts/lib/common.sh scripts/lib/credentials.sh /opt/review-repair-runner/lib/
RUN chmod 555 /opt/review-repair-runner/*.sh /opt/review-repair-runner/agents/*.sh /opt/review-repair-runner/lib/*.sh
RUN mkdir -p /runtime

# The image is rebuilt from pinned CLI versions; agent jobs cannot update the
# tools or install an unpinned host fallback at runtime.
ENV OPENCODE_DISABLE_AUTOUPDATE=true \
    DISABLE_AUTOUPDATER=1

WORKDIR /workspace
