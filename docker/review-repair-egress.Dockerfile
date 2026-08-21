# The agent itself has no egress route. This proxy is the only component with
# external connectivity, and Squid permits CONNECT only to OpenRouter HTTPS.
FROM alpine:3.21

RUN apk add --no-cache squid
COPY docker/review-repair-squid.conf /etc/squid/squid.conf
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
