# The agent itself has no egress route. This proxy is the only component with
# external connectivity, and Squid permits CONNECT only to OpenRouter HTTPS.
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

RUN apk add --no-cache squid
COPY docker/review-repair-squid.conf /etc/squid/squid.conf
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
