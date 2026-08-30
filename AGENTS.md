# AGENTS.md

Guidance for AI coding agents working in this repository. Operator documentation lives in `README.md`.

## Project overview

Docker image packaging the **multica daemon** (local task executor that registers with a Multica server and claims issues) together with **opencode** (the AI agent CLI the daemon spawns per task). One container = one daemon instance; DaemonID/DeviceName default to the hostname (= container ID), so `docker compose up --scale runtime=N` yields N independent executors.

The build lives in `multica-opencode/` (self-contained); the repo root holds documentation only.

## Repository layout

| File | Purpose |
|---|---|entrypo
| `multica-opencode/Dockerfile` | Build: apt deps, pinned multica + opencode binaries from GitHub Releases, env defaults, `HEALTHCHECK`, entrypoint wiring |
| `multica-opencode/entrypoint.sh` | Startup flow (see Invariants) |
| `multica-opencode/example/docker-compose.yml` | Deployment kit consuming a prebuilt image (`MULTICA_RUNTIME_IMAGE`, default `ghcr.io/z-mor/multica-opencode-runtime:latest`); `env_file`, per-replica `workspaces` volume, `deploy.replicas`, active opencode-config mount, commented SSH-key mount |
| `multica-opencode/example/.env.example` | All supported env vars; operators copy it to `.env` next to the compose file |
| `multica-opencode/example/opencode.example.json` | opencode config template (`{env:...}` key usage); operators copy it to `opencode.json` |
| `.github/workflows/docker-publish.yml` | CI: multi-arch build + publish to ghcr.io (see CI invariants below) |

## Build & verification

```bash
docker build --build-arg MULTICA_VERSION=0.4.36 --build-arg OPENCODE_VERSION=1.18.25 \
  -t multica-opencode-runtime:latest multica-opencode
cd multica-opencode/example
cp .env.example .env && cp opencode.example.json opencode.json   # local only, gitignored
docker compose config    # validate compose file + env interpolation
docker compose up -d && docker compose ps   # wait for healthy
docker compose exec runtime multica version
docker compose exec runtime opencode --version
docker compose exec runtime curl -s 127.0.0.1:19514/health | jq .
```

The Dockerfile `RUN` steps fail the build if the pinned binaries do not download and report their versions. `/health` returns `status: "running"` and `agents: ["opencode"]` once a valid `MULTICA_TOKEN` is provided; without one, the container exits during `multica login` with an auth error — that is the expected smoke-test failure mode.

## Invariants — do not break

- **Release asset naming differs between the two tools.** multica: `multica-cli-<version>-linux-<arch>.tar.gz` where `<arch>` is `amd64`/`arm64` (matches `TARGETARCH` directly). opencode: `opencode-linux-<arch>.tar.gz` where `<arch>` is `x64`/`arm64` (keep the `TARGETARCH` mapping in the Dockerfile). Both tarballs contain a single root-level binary (`multica`, `opencode`).
- **The build context is `multica-opencode/`** — the Dockerfile COPYs `entrypoint.sh` from the context root. Keep Dockerfile + entrypoint.sh together in `multica-opencode/`; the repo root holds documentation only. The compose file in `example/` has no `build` section — it consumes a prebuilt image (`MULTICA_RUNTIME_IMAGE`, default `ghcr.io/z-mor/multica-opencode-runtime:latest`); do not reintroduce `build` there.
- **Committed files in `example/` are templates only** — the real `.env`, `opencode.json` and `secrets/` are created by the operator next to them (gitignored); the compose file must keep working with them in place.
- **Versions are pinned via build-args only** (`MULTICA_VERSION`, `OPENCODE_VERSION`) — the defaults live in the `Dockerfile` and nowhere else. To upgrade, bump them there and rebuild. CI reads `MULTICA_VERSION` from the Dockerfile for image tagging — do not duplicate the version into the workflow.
- **Entrypoint order matters**: server `multica config set` (self-host only) → `multica login --token` → git identity → HTTPS token → SSH key → device-name prefix derivation (explicit `MULTICA_DAEMON_DEVICE_NAME` wins over `MULTICA_DEVICE_NAME_PREFIX`) → `exec multica daemon start --foreground`. Login must happen before the daemon starts; `exec` must be the final command so the daemon replaces the entrypoint as the foreground process under tini.
- **The image is immutable**: every self-update path is disabled (`MULTICA_DAEMON_AUTO_RELOAD=0`, `multica config set disable_auto_reload true`, `OPENCODE_DISABLE_AUTOUPDATE=true`). Do not re-enable them.
- **Healthcheck**: the daemon serves loopback-only `127.0.0.1:19514/health` (port follows `MULTICA_DAEMON_PORT`); JSON `status` is `starting` until registration completes, then `running`. The Docker `HEALTHCHECK` must keep gating on `status == "running"`, not on mere reachability.
- **Non-root `agent` user (uid 1000)** runs everything; `tini` stays PID 1 (the daemon spawns agent subprocesses that need signal forwarding and zombie reaping).
- **`workspaces` volume is per-replica by design**: the `.repos/` git cache assumes a single owner — never share it between replicas.
- **Shell scripts** use `set -euo pipefail` and log through the `log()` helper to stderr.
- **Release tag scheme**: `v<MULTICA_VERSION>-<packaging>` (e.g. `v0.4.36-1`). The workflow extracts `MULTICA_VERSION` from the Dockerfile and fails the release if the tag references a different version — bump the Dockerfile `ARG` first. Tags produce image tags `X.Y.Z-N`, `X.Y.Z` and `latest`; `main` produces `<multica>-edge` and `sha-<short>`; PRs build without pushing. The first published package on ghcr.io is private until visibility is switched to public manually.

## Gotchas

- **Two unrelated `opencode.json` files.** The repo-root one configures opencode sessions working on this repo; `multica-opencode/example/opencode.json` is the container's runtime config (operator-created, mounted `:ro` to the image's `OPENCODE_CONFIG` path, re-read by every task-spawned opencode process) — never mix them up.
- opencode auth is env-based: standard `*_API_KEY` names are auto-detected, there is no `auth.json`. Custom providers go through `example/opencode.json` — do not bake credentials into the image.
- SSH keys are mounted read-only; the entrypoint copies the key to `~/.ssh/container_key` before `chmod 600` (ssh refuses permissive keys). Never chmod the mount itself.

## Conventions

- Documentation and code comments are written in English.
- Never print, log, or commit secrets (`MULTICA_TOKEN`, `*_API_KEY`, `GIT_HTTPS_TOKEN`); `.env` is never committed; the entrypoint must never echo them.
- CI (`.github/workflows/docker-publish.yml`) builds both platforms on every PR and push; image publishing happens on `main` and `v*` tags only. Local verification steps remain as above.
