# multica-runtime-container

Docker runtime images for [Multica](https://github.com/multica-ai/multica): each container runs the **multica daemon** (the task executor) and one AI agent CLI that the daemon launches for every task. Every container is a separate runtime with its own DaemonID, so a fleet of N replicas gives you N parallel task executors.

Two flavors of the same base recipe (daemon wiring, entrypoint, healthcheck and env contract are identical — only the bundled agent differs):

| Image | Agent CLI | Build context |
|---|---|---|
| `ghcr.io/z-mor/multica-opencode-runtime` | [opencode](https://opencode.ai) | `multica-opencode/` |
| `ghcr.io/z-mor/multica-pi-runtime` | [pi coding agent](https://github.com/earendil-works/pi) | `multica-pi/` |

```
┌──────────────────── container ──────────────────────┐
│  multica daemon (foreground, PID 1 via tini)       │
│    └── agent CLI: opencode / pi (spawned per task) │
│  /data/workspaces — task git worktrees + repo cache│
└──────────────────┬──────────────────────────────────┘
                   │ WebSocket / HTTPS
                   ▼
       Multica Cloud or a self-hosted server
```

## Quick start (opencode)

```bash
# 1. Deploy from the example kit (pulls ghcr.io/z-mor/multica-opencode-runtime:latest by default;
#    to build locally instead, see Build below)
cd multica-opencode/example
cp .env.example .env
cp opencode.example.json opencode.json
# set the minimum in .env: MULTICA_TOKEN and at least one *_API_KEY for opencode

docker compose up -d                  # starts MULTICA_RUNTIME_REPLICAS containers
docker compose ps                     # healthcheck: /health on :19514 inside the container
docker compose logs -f runtime
```

## Quick start (pi)

```bash
# 1. Deploy from the example kit (pulls ghcr.io/z-mor/multica-pi-runtime:latest by default;
#    to build locally instead, see Build below)
cd multica-pi/example
cp .env.example .env
# set the minimum in .env: MULTICA_TOKEN and at least one provider key for pi
# (e.g. ANTHROPIC_API_KEY / OPENAI_API_KEY / ZAI_API_KEY)

docker compose up -d
docker compose ps
docker compose logs -f runtime
```

All `docker compose ...` commands in this README assume you are in the matching `example/` directory — your `.env` (and for opencode also `opencode.json`) live next to the compose file and are never committed (gitignored).

The token is created under **Settings → API Tokens** (Cloud: https://multica.ai/settings?tab=tokens); it starts with `mul_`.

Once the containers start they show up under **Settings → Runtimes** in the web app. Create an agent based on the bundled CLI (OpenCode for the opencode image, Pi for the pi image), assign it an issue — a free replica picks it up.

### Scaling

```bash
docker compose up -d --scale runtime=5   # 5 parallel runtimes
docker compose up -d --scale runtime=1   # back to a single one
```

DaemonID/DeviceName default to the hostname (the container ID), so they are unique per replica automatically. Each replica gets its own `workspaces` volume; the repository cache is not shared between replicas (that is deliberate: `.repos/` is designed for a single owner).

### Connecting to a self-hosted server

```bash
# in .env:
MULTICA_SERVER_URL=https://api.example.com
MULTICA_APP_URL=https://app.example.com
```

If these variables are not set, the container connects to Multica Cloud.

### Self-signed certificates

If the self-hosted server (or the git host, or an LLM gateway) uses a self-signed certificate, keep verification on and trust your CA instead:

1. Save the CA certificate to `example/secrets/ca.crt` and uncomment the `./secrets/ca.crt:/certs/ca.crt:ro` mount in `docker-compose.yml`.
2. Set the variables you need in `.env` (see `.env.example` → TLS):

| Variable | Consumer | Note |
|---|---|---|
| `SSL_CERT_FILE` | multica daemon (Go) | Replaces the system CA bundle — fine, the daemon only talks to your server |
| `NODE_EXTRA_CA_CERTS` | opencode / pi | Appends to the system bundle (LLM endpoints) |
| `GIT_SSL_CAINFO` | git over HTTPS | Clone/push |

If only the git host is self-signed, `GIT_SSL_CAINFO` alone is enough. Disabling verification instead (`git config http.sslVerify false`, `NODE_TLS_REJECT_UNAUTHORIZED=0`) works for git and the agents but is discouraged; the daemon has no insecure mode at all — a trusted CA is the only path there.

## Environment variables

### Required

| Variable | Description |
|---|---|
| `MULTICA_TOKEN` | Personal access token (`mul_...`). The entrypoint runs `multica login --token` on every start |

### Server

| Variable | Default | Description |
|---|---|---|
| `MULTICA_SERVER_URL` | — (Cloud) | API URL of a self-hosted server |
| `MULTICA_APP_URL` | — | Web app URL of a self-hosted server |

### Instance identity

| Variable | Default | Description |
|---|---|---|
| `MULTICA_DAEMON_ID` | hostname (container ID) | Daemon ID on the server |
| `MULTICA_DAEMON_DEVICE_NAME` | hostname | Human-readable device name |
| `MULTICA_DEVICE_NAME_PREFIX` | — | Fleet naming: each replica registers as `PREFIX-<container suffix>` (e.g. `agent-05350488`); ignored when `MULTICA_DAEMON_DEVICE_NAME` is set |
| `MULTICA_AGENT_RUNTIME_NAME` | `Docker runtime` | Runtime name (shown on the agent) |

Use an explicit `MULTICA_DAEMON_DEVICE_NAME` for a single instance. For a fleet (`--scale runtime=N`) set only the prefix — every replica then gets a readable, collision-free name. Plain Compose cannot provide sequential per-replica numbers, so the suffix is the short container ID.

### opencode (opencode image only)

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`, `ZHIPU_API_KEY`, `KIMI_API_KEY`, `MOONSHOT_API_KEY` | Provider keys; opencode picks up the standard env names automatically. `ZHIPU_API_KEY` covers both the Z.AI GLM Coding Plan and the regular Z.AI API; `KIMI_API_KEY` is the Kimi For Coding plan (`MOONSHOT_API_KEY` for pay-as-you-go Kimi models) |
| `MULTICA_OPENCODE_MODEL` | Model for opencode tasks, in `provider/model` format (e.g. `anthropic/claude-sonnet-4-5`, `zai-coding-plan/glm-5.3`, `kimi-for-coding/kimi-for-coding`) |

The container's opencode config lives in `multica-opencode/example/opencode.json` (created from `opencode.example.json`, which also shows an OpenAI-compatible gateway example using `{env:CUSTOM_LLM_API_KEY}`) and is mounted read-only into the image — the `OPENCODE_CONFIG` env baked into the image points at the mount target. Edit it to set model defaults, custom providers, permissions, etc. opencode is spawned per task and reads the config on startup, so edits apply to newly claimed tasks without rebuilding the image.

### pi (pi image only)

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`, `KIMI_API_KEY`, `MOONSHOT_API_KEY`, `ZAI_API_KEY`, `ZAI_CODING_CN_API_KEY` | Provider keys; pi picks up the standard env names automatically. `ZAI_API_KEY` / `ZAI_CODING_CN_API_KEY` are the Z.AI Coding Plan (Global / China); `KIMI_API_KEY` is the Kimi For Coding plan. [Full list of pi providers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md) |
| `MULTICA_PI_MODEL` | Model for pi tasks, in `provider/model` format (e.g. `anthropic/claude-sonnet-4-6`, `openai/gpt-5.3-codex`) |

**Version compatibility**: multica 0.8.1 has no hard minimum or maximum pi version, but two capability floors apply — pi **≥ 1.4.0** enables the RPC mode used for in-flight task supplements/steering, and pi **≥ 0.99.0** enables managed MCP delivery. Older versions still register and run tasks, but silently lose those features — keep `PI_VERSION` at or above 1.4.0.

Provider keys are all the pi image needs — no config file is required. For deeper customization (default model, custom providers, skills, extensions) pi reads `settings.json` / `models.json` from `~/.pi/agent`; mount your own directory via the commented `./pi-agent:/home/agent/.pi/agent` volume in `multica-pi/example/docker-compose.yml` (writable, not `:ro`).

### Git

| Variable | Description |
|---|---|
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | Commit identity used by agents |
| `GIT_HTTPS_TOKEN` | Token for clone/push over HTTPS (git credential store) |
| `GIT_HOST` | Host for the HTTPS token (default `github.com`) |
| `GIT_HTTPS_USER` | Token user (default `x-access-token`; for GitLab use `oauth2`) |
| `GIT_SSH_KEY` | Path to a mounted SSH key; `~/.ssh/id_ed25519` is picked up by default |

### Daemon

| Variable | Default | Description |
|---|---|---|
| `MULTICA_DAEMON_MAX_CONCURRENT_TASKS` | `20` | Max concurrent tasks per container |
| `MULTICA_DAEMON_POLL_INTERVAL` | `30s` | Fallback polling (work arrives via WebSocket wake signals) |
| `MULTICA_DAEMON_PORT` | `19514` | Daemon-local health port |

## Build

Each image's build context is its own directory (Dockerfile and entrypoint live together there). The compose files in `example/` consume the prebuilt images from ghcr.io by default; set `MULTICA_RUNTIME_IMAGE` in `.env` to point them elsewhere (e.g. a locally built tag). Versions are pinned with build arguments:

```bash
# opencode flavor
cd multica-opencode
docker build \
  --build-arg MULTICA_VERSION=0.8.1 \
  --build-arg OPENCODE_VERSION=1.19.5 \
  -t multica-opencode-runtime:latest .

# pi flavor
cd multica-pi
docker build \
  --build-arg MULTICA_VERSION=0.8.1 \
  --build-arg PI_VERSION=1.5.0 \
  -t multica-pi-runtime:latest .
```

- multica CLI: `multica-cli-<ver>-linux-<arch>.tar.gz` from [releases](https://github.com/multica-ai/multica/releases)
- opencode: `opencode-linux-<arch>.tar.gz` from [releases](https://github.com/anomalyco/opencode/releases) (native binary, Node.js is not required)
- pi: `pi-linux-<arch>.tar.gz` from [releases](https://github.com/earendil-works/pi/releases) (self-contained `pi/` directory with a bun-compiled binary, Node.js is not required)

`linux/amd64` and `linux/arm64` are supported.

## Using an image as a base

The images are plain Debian-slim containers with the daemon, the agent CLI, git and the entrypoint already wired — derive a specialized image when your repositories need a specific toolchain:

```dockerfile
# Dockerfile.runtime
FROM ghcr.io/z-mor/multica-pi-runtime:latest
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential python3 nodejs \
    && rm -rf /var/lib/apt/lists/*
```

```bash
docker build -t my-multica-pi-runtime -f Dockerfile.runtime .
# then in multica-pi/example/.env: MULTICA_RUNTIME_IMAGE=my-multica-pi-runtime:latest
```

The entrypoint, `HEALTHCHECK` and user/permission setup are inherited as-is; install extra packages and go. Keep the derived image immutable as well — never enable the daemon or agent self-update paths that the base image disables.

## CI & releases

GitHub Actions (`.github/workflows/docker-publish.yml`) builds and publishes **both images** to ghcr.io — no secrets needed, it authenticates with the built-in `GITHUB_TOKEN`. Each image is an independent matrix job with its own tag set: **ghcr.io/z-mor/multica-opencode-runtime** and **ghcr.io/z-mor/multica-pi-runtime**.

| Event | Image tags (per image) |
|---|---|
| tag `vX.Y.Z-N` | `X.Y.Z-N` (exact), `X.Y.Z` (latest packaging of that multica version), `latest` |
| push to `main` | `<multica>-edge` (mutable), `sha-<short>` |
| pull request | build only (both platforms), no push |

`X.Y.Z` is the multica CLI version pinned via `ARG MULTICA_VERSION` in the corresponding Dockerfile; `N` is the packaging revision. Each job reads the version from its Dockerfile (single source of truth) and **fails the release if the tag references a different version** — bump the `ARG` first, then tag.

To release:

```bash
git tag v0.8.1-1 && git push origin v0.8.1-1
```

The first successful push creates the packages on ghcr.io; they are private by default — switch each to public once in the package settings on GitHub if you want it publicly pullable.

## Healthcheck

The daemon listens on loopback `127.0.0.1:19514` and serves `GET /health`:

```json
{"status": "running", "daemon_id": "...", "agents": ["opencode"], "workspaces": [...]}
```

(`agents` is `["pi"]` for the pi image.) `status` becomes `running` once the runtimes are registered; the Docker HEALTHCHECK baked into the image gates on exactly that. Check manually:

```bash
docker compose exec runtime curl -s 127.0.0.1:19514/health | jq .
```

## Troubleshooting

| Symptom | What to check |
|---|---|
| Container exits immediately | `docker compose logs runtime` — most often an invalid `MULTICA_TOKEN` |
| `x509: certificate signed by unknown authority` | Self-signed cert on the server/git host — mount the CA and set `SSL_CERT_FILE` / `GIT_SSL_CAINFO` / `NODE_EXTRA_CA_CERTS` (see [Self-signed certificates](#self-signed-certificates)) |
| `pull access denied for ghcr.io/z-mor/multica-*-runtime` | No release tag pushed yet, or the ghcr.io package is still private — see [CI & releases](#ci--releases) |
| `status: starting` never becomes `running` | Daemon logs: server unreachable, token expired, or the agent CLI not found (it is definitely in the image; check `docker compose exec runtime opencode --version` / `docker compose exec runtime pi --version`) |
| Tasks are not picked up | The agent in the web UI is based on a different CLI than the image bundles (OpenCode for `multica-opencode-runtime`, Pi for `multica-pi-runtime`), or the issue is assigned to another user's agent |
| `unhealthy` | `docker compose exec runtime curl -s 127.0.0.1:19514/health` — the `skipped_agents` field shows why a CLI was rejected |
| Daemon logs | `docker compose exec runtime multica daemon logs -n 100` |
| Pushes to the repository fail | Check git credentials: `docker compose exec runtime git ls-remote https://github.com/org/repo` (or the SSH variant) |

## Design notes

- **Non-root**: the daemon and the agents run as user `agent` (uid 1000).
- **tini as PID 1**: the daemon spawns agent subprocesses; tini forwards SIGTERM correctly and reaps zombies.
- **Auto-update disabled** (multica: `MULTICA_DAEMON_AUTO_RELOAD=false`, `MULTICA_DAEMON_AUTO_UPDATE=false`, `disable_auto_reload=true`, `disable_auto_update=true`; opencode: `OPENCODE_DISABLE_AUTOUPDATE=true`; pi: `PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0`): the image is immutable; an upgrade means rebuilding with a new build-arg.
- **Why debian-slim and not alpine**: the whole value of this runtime is the agents' ability to build arbitrary repositories. On musl, Python manylinux wheels, a number of npm native modules, and most prebuilt binaries the agents download are broken. The ~60 MB size difference is negligible next to the agent binaries themselves.
- **Token in env**: `MULTICA_TOKEN` is visible via `docker inspect`; when sharing the environment, use docker secrets or CI variables. The entrypoint never logs the token.
