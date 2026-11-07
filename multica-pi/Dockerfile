# syntax=docker/dockerfile:1
#
# Multica runtime container: multica daemon + pi coding agent.
# One container = one daemon instance (unique DaemonID defaults to hostname,
# i.e. the container ID), so N replicas form an N-daemon runtime fleet.
#
# Build-time pins (override with --build-arg):
#   MULTICA_VERSION — multica CLI release, https://github.com/multica-ai/multica/releases
#   PI_VERSION      — pi coding agent release, https://github.com/earendil-works/pi/releases
#
# Compatibility (verified against multica 0.8.1 sources: server/pkg/agent/
# version.go and pi.go): multica enforces no hard minimum or maximum for pi,
# but capability floors exist — pi >= 1.4.0 enables the RPC mode used for
# in-flight task supplements/steering, >= 0.99.0 enables managed MCP delivery.
# Older pi still registers but silently loses those features. Keep PI_VERSION
# >= 1.4.0 and recheck the floors when bumping MULTICA_VERSION.

ARG MULTICA_VERSION=0.8.1
ARG PI_VERSION=1.5.0

FROM debian:bookworm-slim

ARG MULTICA_VERSION
ARG PI_VERSION
ARG TARGETARCH

# git/git-lfs: daemon clones repos into a shared cache and checks out per-task
# worktrees; agents commit and push from them.
# openssh-client: git over SSH. tini: PID 1 — forwards signals and reaps the
# agent subprocesses the daemon spawns. jq: healthcheck.
# ripgrep: shipped in the official pi Dockerfile; pi uses it for repo search.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        git-lfs \
        jq \
        openssh-client \
        procps \
        ripgrep \
        tini \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for the daemon and every agent process it launches.
RUN useradd --create-home --uid 1000 --shell /bin/bash agent \
    && mkdir -p /data/workspaces /home/agent/.pi/agent /home/agent/.ssh \
    && chown -R agent:agent /data /home/agent

# --- multica CLI (provides the agent daemon) ---------------------------------
RUN set -eux; \
    curl -fsSL -o /tmp/multica.tar.gz \
        "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    tar -xzf /tmp/multica.tar.gz -C /tmp multica; \
    install -m 0755 /tmp/multica /usr/local/bin/multica; \
    rm -f /tmp/multica.tar.gz /tmp/multica; \
    multica version

# --- pi coding agent (AI coding agent driven by the daemon) -------------------
# Unlike multica/opencode, the release tarball is not a single binary: it holds
# a self-contained `pi/` directory (bun-compiled `pi` binary — no Node.js
# required — plus assets the binary resolves relative to itself). Install the
# whole directory under /opt and expose the binary on PATH via a symlink.
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) pi_arch=x64 ;; \
        arm64) pi_arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/pi.tar.gz \
        "https://github.com/earendil-works/pi/releases/download/v${PI_VERSION}/pi-linux-${pi_arch}.tar.gz"; \
    tar -xzf /tmp/pi.tar.gz -C /opt; \
    chmod 0755 /opt/pi/pi; \
    ln -s /opt/pi/pi /usr/local/bin/pi; \
    rm -f /tmp/pi.tar.gz; \
    pi --version

COPY --chown=agent:agent entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER agent
WORKDIR /home/agent

RUN git lfs install

# PI_SKIP_VERSION_CHECK/PI_TELEMETRY: pi has no startup auto-update; these stop
# the pi.dev version ping and telemetry so a container without tasks performs
# no outbound requests at all.
ENV MULTICA_WORKSPACES_ROOT=/data/workspaces \
    MULTICA_DAEMON_AUTO_RELOAD=false \
    MULTICA_DAEMON_AUTO_UPDATE=false \
    MULTICA_AGENT_RUNTIME_NAME="Docker runtime" \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0

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
