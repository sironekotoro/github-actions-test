#!/usr/bin/env sh
set -eu

case "${BROKER_PROVIDER:-openrouter}" in
  anthropic)
    exec node /opt/provider-broker/broker-anthropic.mjs
    ;;
  openrouter|openai)
    exec node /opt/provider-broker/broker.mjs
    ;;
  *)
    printf '%s\n' 'BROKER_PROVIDER must be openrouter, openai, or anthropic' >&2
    exit 1
    ;;
esac
