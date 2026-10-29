FROM ghcr.io/anomalyco/opencode:2.2.0
USER root
RUN apk add --no-cache git docker-cli docker-cli-buildx
