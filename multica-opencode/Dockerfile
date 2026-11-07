# syntax=docker/dockerfile:1
#
# Multica runtime container: multica daemon + opencode agent CLI.
# One container = one daemon instance (unique DaemonID defaults to hostname,
# i.e. the container ID), so N replicas form an N-daemon runtime fleet.
#
# Build-time pins (override with --build-arg):
#   MULTICA_VERSION  — multica CLI release, https://github.com/multica-ai/multica/releases
#   OPENCODE_VERSION — opencode release, https://github.com/anomalyco/opencode/releases

ARG MULTICA_VERSION=0.8.1
ARG OPENCODE_VERSION=1.19.5

FROM debian:bookworm-slim

ARG MULTICA_VERSION
ARG OPENCODE_VERSION
ARG TARGETARCH

# git/git-lfs: daemon clones repos into a shared cache and checks out per-task
# worktrees; agents commit and push from them.
# openssh-client: git over SSH. tini: PID 1 — forwards signals and reaps the
# agent subprocesses the daemon spawns. jq: healthcheck.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        git-lfs \
        jq \
        openssh-client \
        procps \
        tini \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for the daemon and every agent process it launches.
RUN useradd --create-home --uid 1000 --shell /bin/bash agent \
    && mkdir -p /data/workspaces /home/agent/.config/opencode /home/agent/.ssh \
    && chown -R agent:agent /data /home/agent

# --- multica CLI (provides the agent daemon) ---------------------------------
RUN set -eux; \
    curl -fsSL -o /tmp/multica.tar.gz \
        "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    tar -xzf /tmp/multica.tar.gz -C /tmp multica; \
    install -m 0755 /tmp/multica /usr/local/bin/multica; \
    rm -f /tmp/multica.tar.gz /tmp/multica; \
    multica version

# --- opencode (AI coding agent driven by the daemon) --------------------------
# Release tarballs contain a single `opencode` binary (no Node.js required).
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) oc_arch=x64 ;; \
        arm64) oc_arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/opencode.tar.gz \
        "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-${oc_arch}.tar.gz"; \
    tar -xzf /tmp/opencode.tar.gz -C /tmp opencode; \
    install -m 0755 /tmp/opencode /usr/local/bin/opencode; \
    rm -f /tmp/opencode.tar.gz /tmp/opencode; \
    opencode --version

COPY --chown=agent:agent entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER agent
WORKDIR /home/agent

RUN git lfs install

ENV MULTICA_WORKSPACES_ROOT=/data/workspaces \
    MULTICA_DAEMON_AUTO_RELOAD=false \
    MULTICA_DAEMON_AUTO_UPDATE=false \
    MULTICA_AGENT_RUNTIME_NAME="Docker runtime" \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_CONFIG=/home/agent/.config/opencode/opencode.json

# Per-task worktree checkouts + shared repo cache (`.repos/`); persist it to
# avoid re-cloning every repository on each container start.
VOLUME ["/data/workspaces"]

# Daemon-local health endpoint: GET 127.0.0.1:19514/health returns
# {"status":"running"} once registered and able to claim tasks.
# Port follows MULTICA_DAEMON_PORT. Bound to loopback only (by design), which
# is fine — HEALTHCHECK runs inside the container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -sf "http://127.0.0.1:${MULTICA_DAEMON_PORT:-19514}/health" | jq -e '.status == "running"' >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
