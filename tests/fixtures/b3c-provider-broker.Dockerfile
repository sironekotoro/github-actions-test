FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/provider-broker
COPY docker/provider-broker-package.json /opt/provider-broker/package.json
RUN npm install && npm cache clean --force

COPY scripts/provider-broker.mjs /opt/provider-broker/broker.mjs
COPY scripts/provider-broker-anthropic.mjs /opt/provider-broker/broker-anthropic.mjs
COPY scripts/lib/anthropic-spend-guard.mjs /opt/provider-broker/lib/anthropic-spend-guard.mjs
COPY scripts/provider-broker-entrypoint.sh /opt/provider-broker/entrypoint.sh
RUN chmod 555 /opt/provider-broker/broker.mjs /opt/provider-broker/broker-anthropic.mjs /opt/provider-broker/entrypoint.sh \
    && chmod 444 /opt/provider-broker/lib/anthropic-spend-guard.mjs

USER nobody
EXPOSE 3080
CMD ["sh", "/opt/provider-broker/entrypoint.sh"]
