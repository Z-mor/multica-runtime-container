# AGENTS.md

Guidance for AI coding agents working in this repository. Operator documentation lives in `README.md`.

## Project overview

Docker images packaging the **multica daemon** (local task executor that registers with a Multica server and claims issues) together with one AI agent CLI that the daemon spawns per task. One container = one daemon instance; DaemonID/DeviceName default to the hostname (= container ID), so `docker compose up --scale runtime=N` yields N independent executors.

Two self-contained build kits, one per bundled agent (same daemon wiring, entrypoint flow and env contract):

- `multica-opencode/` → image `ghcr.io/z-mor/multica-opencode-runtime` (daemon + **opencode**)
- `multica-pi/` → image `ghcr.io/z-mor/multica-pi-runtime` (daemon + **pi coding agent**)

The repo root holds documentation only. Both images are also meant to be usable as base images for derived, toolchain-specialized images — keep them dependency-complete and their conventions uniform.

## Repository layout

| File | Purpose |
|---|---|
| `multica-opencode/Dockerfile` | Build: apt deps, pinned multica + opencode binaries from GitHub Releases, env defaults, `HEALTHCHECK`, entrypoint wiring |
| `multica-opencode/entrypoint.sh` | Startup flow (see Invariants) |
| `multica-opencode/example/docker-compose.yml` | Deployment kit consuming a prebuilt image (`MULTICA_RUNTIME_IMAGE`, default `ghcr.io/z-mor/multica-opencode-runtime:latest`); `env_file`, per-replica `workspaces` volume, `deploy.replicas`, active opencode-config mount, commented SSH-key mount |
| `multica-opencode/example/.env.example` | All supported env vars; operators copy it to `.env` next to the compose file |
| `multica-opencode/example/opencode.example.json` | opencode config template (`{env:...}` key usage); operators copy it to `opencode.json` |
| `multica-pi/Dockerfile` | Same recipe for the pi flavor: pinned multica + pi release tarballs, `ripgrep` added to apt deps |
| `multica-pi/entrypoint.sh` | Startup flow identical to the opencode flavor (log tag `[multica-pi-runtime]`, checks `pi` on PATH) |
| `multica-pi/example/docker-compose.yml` | Deployment kit for the pi image (default `ghcr.io/z-mor/multica-pi-runtime:latest`); commented `./pi-agent` ~/.pi/agent mount, no opencode.json equivalent |
| `multica-pi/example/.env.example` | Env vars for the pi flavor (pi provider keys, `MULTICA_PI_MODEL`) |
| `multica-pi/example/pi-agent.example/` | Templates for the optional `~/.pi/agent` mount (`mcp.json`, `settings.json`, `models.json`, `AGENTS.md`); operators copy to `pi-agent/` next to the compose file (gitignored) |
| `.github/workflows/docker-publish.yml` | CI: matrix over both kits, multi-arch build + publish to ghcr.io (see CI invariants below) |

## Build & verification

```bash
docker build --build-arg MULTICA_VERSION=0.8.1 --build-arg OPENCODE_VERSION=1.19.5 \
  -t multica-opencode-runtime:latest multica-opencode
docker build --build-arg MULTICA_VERSION=0.8.1 --build-arg PI_VERSION=1.5.0 \
  -t multica-pi-runtime:latest multica-pi
cd multica-opencode/example
cp .env.example .env && cp opencode.example.json opencode.json   # local only, gitignored
docker compose config    # validate compose file + env interpolation
cd ../../multica-pi/example
cp .env.example .env     # local only, gitignored
docker compose config
docker compose up -d && docker compose ps   # wait for healthy
docker compose exec runtime multica version
docker compose exec runtime opencode --version   # (pi flavor: pi --version)
docker compose exec runtime curl -s 127.0.0.1:19514/health | jq .
```

The Dockerfile `RUN` steps fail the build if the pinned binaries do not download and report their versions. `/health` returns `status: "running"` and `agents: ["opencode"]` (pi flavor: `["pi"]`) once a valid `MULTICA_TOKEN` is provided; without one, the container exits during `multica login` with an auth error — that is the expected smoke-test failure mode.

## Invariants — do not break

- **Release asset naming differs between the tools.** multica: `multica-cli-<version>-linux-<arch>.tar.gz` where `<arch>` is `amd64`/`arm64` (matches `TARGETARCH` directly). opencode: `opencode-linux-<arch>.tar.gz` where `<arch>` is `x64`/`arm64`. pi: `pi-linux-<arch>.tar.gz` where `<arch>` is `x64`/`arm64` (keep the `TARGETARCH` mapping in each Dockerfile). The multica and opencode tarballs contain a single root-level binary; **the pi tarball contains a self-contained `pi/` directory** (bun-compiled `pi/pi` binary + assets resolved relative to it) — install the directory (e.g. under `/opt`) and symlink the binary onto PATH, do not copy the binary out alone.
- **The build contexts are `multica-opencode/` and `multica-pi/`** — each Dockerfile COPYs its `entrypoint.sh` from its context root. Keep Dockerfile + entrypoint.sh together in their kit; the repo root holds documentation only. The compose files in `example/` have no `build` section — they consume prebuilt images (`MULTICA_RUNTIME_IMAGE`, default `ghcr.io/z-mor/multica-opencode-runtime:latest` / `ghcr.io/z-mor/multica-pi-runtime:latest`); do not reintroduce `build` there.
- **Committed files in `example/` are templates only** — the real `.env`, `opencode.json`, `pi-agent/` and `secrets/` are created by the operator next to them (gitignored); the compose files must keep working with them in place.
- **Versions are pinned via build-args only** (`MULTICA_VERSION`, `OPENCODE_VERSION` / `PI_VERSION`) — the defaults live in the `Dockerfile`s and nowhere else. To upgrade, bump them there and rebuild. CI reads `MULTICA_VERSION` from each Dockerfile for image tagging — do not duplicate the version into the workflow.
- **pi version floor**: keep `PI_VERSION` ≥ **1.4.0** — multica 0.8.1 enforces no hard minimum or maximum for pi, but capability floors exist (≥ 1.4.0: RPC mode for in-flight task supplements/steering; ≥ 0.99.0: managed MCP delivery; older pi registers but silently loses features). When bumping `MULTICA_VERSION`, recheck the floors in upstream `server/pkg/agent/version.go` (`MinVersions`, `SupportsTaskSupplement`) and `pi.go` (`piMcpMinVersion`).
- **Entrypoint order matters**: server `multica config set` (self-host only) → `multica login --token` → git identity → HTTPS token → SSH key → device-name prefix derivation (explicit `MULTICA_DAEMON_DEVICE_NAME` wins over `MULTICA_DEVICE_NAME_PREFIX`) → `exec multica daemon start --foreground`. Login must happen before the daemon starts; `exec` must be the final command so the daemon replaces the entrypoint as the foreground process under tini.
- **The image is immutable**: every self-update path is disabled (`MULTICA_DAEMON_AUTO_RELOAD=false`, `MULTICA_DAEMON_AUTO_UPDATE=false`, `multica config set disable_auto_reload true`, `multica config set disable_auto_update true`; opencode: `OPENCODE_DISABLE_AUTOUPDATE=true`; pi: `PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0`). Do not re-enable them.
- **Healthcheck**: the daemon serves loopback-only `127.0.0.1:19514/health` (port follows `MULTICA_DAEMON_PORT`); JSON `status` is `starting` until registration completes, then `running`. The Docker `HEALTHCHECK` must keep gating on `status == "running"`, not on mere reachability.
- **Non-root `agent` user (uid 1000)** runs everything; `tini` stays PID 1 (the daemon spawns agent subprocesses that need signal forwarding and zombie reaping).
- **`workspaces` volume is per-replica by design**: the `.repos/` git cache assumes a single owner — never share it between replicas.
- **Shell scripts** use `set -euo pipefail` and log through the `log()` helper to stderr.
- **Release tag scheme**: `v<MULTICA_VERSION>-<packaging>` (e.g. `v0.8.1-1`). One tag releases **both** images. The workflow extracts `MULTICA_VERSION` from each kit's Dockerfile and fails the release if the tag references a different version — bump the Dockerfile `ARG`s first. Tags produce image tags `X.Y.Z-N`, `X.Y.Z` and `latest`; `main` produces `<multica>-edge` and `sha-<short>`; PRs build without pushing. The first published package on ghcr.io is private until visibility is switched to public manually (per package).

## Gotchas

- **Two unrelated `opencode.json` files.** The repo-root one configures opencode sessions working on this repo; `multica-opencode/example/opencode.json` is the container's runtime config (operator-created, mounted `:ro` to the image's `OPENCODE_CONFIG` path, re-read by every task-spawned opencode process) — never mix them up.
- Agent auth is env-based in both flavors: standard `*_API_KEY` names are auto-detected (opencode: incl. `ZHIPU_API_KEY`; pi: incl. `ZAI_API_KEY`/`ZAI_CODING_CN_API_KEY` instead — the Z.AI key names differ between the agents). Custom opencode providers go through `example/opencode.json`; pi customization goes through `~/.pi/agent` (optional `./pi-agent` mount, writable) — do not bake credentials into an image.
- The multica daemon detects agent CLIs on PATH and invokes pi in headless JSON mode (`pi -p --mode json`); per-agent model overrides exist as env vars (`MULTICA_OPENCODE_MODEL`, `MULTICA_PI_MODEL`) — keep them documented in the matching `.env.example`.
- The optional pi `~/.pi/agent` mount must be writable (pi appends `mcp.log` and saves MCP exposure changes there — never `:ro`). A local `mcp.json` entry overrides a multica-managed MCP server with the same name. OAuth sign-in (`/mcp login`, `/login`) is interactive and unavailable in the container — HTTP MCP authenticates via `headers` with `${ENV_VAR}`, LLM providers via env keys; stdio MCP servers need their runtime (nodejs/python) baked into a derived image. Never set `selfUpdateCommand` or add update sources in settings (immutability).
- SSH keys are mounted read-only; the entrypoint copies the key to `~/.ssh/container_key` before `chmod 600` (ssh refuses permissive keys). Never chmod the mount itself.

## Conventions

- Documentation and code comments are written in English.
- Never print, log, or commit secrets (`MULTICA_TOKEN`, `*_API_KEY`, `GIT_HTTPS_TOKEN`); `.env` is never committed; the entrypoint must never echo them.
- CI (`.github/workflows/docker-publish.yml`) is a matrix over both kits and builds both platforms on every PR and push; image publishing happens on `main` and `v*` tags only. Local verification steps remain as above.
