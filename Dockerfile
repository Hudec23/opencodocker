FROM ghcr.io/anomalyco/opencode:2.2.0
USER root
RUN apk add --no-cache \
    git \
    docker-cli \
    docker-cli-buildx \
    docker-cli-compose \
    python3 \
    file \
    bash \
    curl \
    wget \
    ca-certificates \
    jq \
    ripgrep \
    fd \
    tree \
    unzip \
    zip \
    openssh-client \
    procps \
    htop \
    less \
    tmux \
    make \
    which
