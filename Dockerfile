FROM python:3.13-slim-bookworm

# OCI Labels
LABEL org.opencontainers.image.title="Gasclaw"
LABEL org.opencontainers.image.description="Gastown + OpenClaw + KimiGas in one container"
LABEL org.opencontainers.image.source="https://github.com/gastown-publish/gasclaw"
LABEL org.opencontainers.image.licenses="MIT"

# Build arguments for versions
ARG GO_VERSION=1.24.1
ARG NODE_VERSION=22

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git tmux ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Go
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Dolt
RUN curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Claude Code (required)
RUN npm install -g @anthropic-ai/claude-code

# OpenClaw (optional but recommended)
RUN npm install -g openclaw || echo "Warning: OpenClaw installation failed"

# KimiGas (kimi-cli) (optional but recommended)
RUN pip install --no-cache-dir kimi-cli || echo "Warning: Kimi CLI installation failed"

# Gastown (gt) (optional but recommended)
RUN pip install --no-cache-dir gastown || echo "Warning: Gastown installation failed"

# Create non-root user for security
RUN useradd -m -u 1000 gasclaw && \
    mkdir -p /opt/gasclaw /workspace/gt /project && \
    chown -R gasclaw:gasclaw /opt/gasclaw /workspace/gt /project

# Install gasclaw
WORKDIR /opt/gasclaw
COPY --chown=gasclaw:gasclaw pyproject.toml .
COPY --chown=gasclaw:gasclaw src/ src/
COPY --chown=gasclaw:gasclaw skills/ skills/
RUN pip install --no-cache-dir .

# Switch to non-root user
USER gasclaw

# Volume mount point
VOLUME /project

# OpenClaw gateway port
EXPOSE 18789

# Entrypoint
ENTRYPOINT ["gasclaw"]
CMD ["start"]
