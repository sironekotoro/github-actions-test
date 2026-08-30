FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/provider-broker
COPY docker/provider-broker-package.json /opt/provider-broker/package.json
RUN npm install && npm cache clean --force

COPY scripts/provider-broker.mjs /opt/provider-broker/broker.mjs
RUN chmod 555 /opt/provider-broker/broker.mjs

USER nobody
EXPOSE 3080
CMD ["node", "/opt/provider-broker/broker.mjs"]