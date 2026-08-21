# Built solely from the trusted dispatcher checkout. Target repository code is
# supplied only at runtime as an isolated .git-free working copy.
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates coreutils git jq \
    && npm install --global opencode-ai@1.18.16 \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/run-agent.sh scripts/build-agent-prompt.sh scripts/build-review-prompt.sh /opt/review-repair-runner/
COPY scripts/lib/common.sh /opt/review-repair-runner/lib/common.sh
RUN chmod 555 /opt/review-repair-runner/*.sh /opt/review-repair-runner/lib/common.sh
RUN mkdir -p /runtime

WORKDIR /workspace
