#!/usr/bin/env bash
# Multica runtime container entrypoint.
#
# Flow: configure server endpoint (if self-hosted) -> headless token login ->
# git identity + credentials (HTTPS token and/or mounted SSH key) ->
# exec the agent daemon in the foreground as PID 1 (via tini).
set -euo pipefail

log() { printf '[multica-opencode-runtime] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v multica  >/dev/null 2>&1 || die "multica CLI not found on PATH"
command -v opencode >/dev/null 2>&1 || die "opencode not found on PATH"

: "${MULTICA_TOKEN:?MULTICA_TOKEN is required (personal access token, mul_...; Settings -> API Tokens)}"

# --- 1. Server endpoint (leave unset for Multica Cloud) ----------------------
if [ -n "${MULTICA_SERVER_URL:-}" ]; then
    log "server: ${MULTICA_SERVER_URL} (self-hosted)"
    multica config set server_url "${MULTICA_SERVER_URL}"
    if [ -n "${MULTICA_APP_URL:-}" ]; then
        multica config set app_url "${MULTICA_APP_URL}"
    fi
else
    log "server: Multica Cloud (multica.ai)"
fi

# --- 2. Headless authentication ----------------------------------------------
log "authenticating with personal access token"
multica login --token "${MULTICA_TOKEN}"

# The image is immutable: forbid the daemon from restarting into a self-updated
# binary. Belt and suspenders next to MULTICA_DAEMON_AUTO_RELOAD=0.
multica config set disable_auto_reload true >/dev/null 2>&1 || true

# --- 3. Git identity for agent commits ---------------------------------------
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "${GIT_USER_EMAIL}"
fi

# --- 4a. Git over HTTPS: token in a git credential store ---------------------
if [ -n "${GIT_HTTPS_TOKEN:-}" ]; then
    git_host="${GIT_HOST:-github.com}"
    git_user="${GIT_HTTPS_USER:-x-access-token}"
    cred_file="${HOME}/.git-credentials"
    printf 'https://%s:%s@%s\n' "${git_user}" "${GIT_HTTPS_TOKEN}" "${git_host}" > "${cred_file}"
    chmod 600 "${cred_file}"
    git config --global credential.helper "store --file=${cred_file}"
    log "git HTTPS credentials configured for ${git_host}"
fi

# --- 4b. Git over SSH: mounted key (may be read-only) -> private copy --------
ssh_key="${GIT_SSH_KEY:-}"
if [ -z "${ssh_key}" ]; then
    for candidate in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_ecdsa" "${HOME}/.ssh/id_rsa"; do
        if [ -f "${candidate}" ]; then
            ssh_key="${candidate}"
            break
        fi
    done
fi
if [ -n "${ssh_key}" ]; then
    [ -f "${ssh_key}" ] || die "GIT_SSH_KEY points to a missing file: ${ssh_key}"
    # ssh refuses keys with permissive permissions; the mount is often :ro, so
    # work on a copy owned by the agent user.
    key_copy="${HOME}/.ssh/container_key"
    cp "${ssh_key}" "${key_copy}"
    chmod 600 "${key_copy}"
    git config --global core.sshCommand \
        "ssh -i ${key_copy} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    log "git SSH configured (key: ${ssh_key})"
fi

# --- 4c. Per-replica display name (optional) ---------------------------------
# Fleet naming: every replica registers as PREFIX-<container suffix>.
# An explicitly set MULTICA_DAEMON_DEVICE_NAME always wins over the prefix.
if [ -n "${MULTICA_DEVICE_NAME_PREFIX:-}" ] && [ -z "${MULTICA_DAEMON_DEVICE_NAME:-}" ]; then
    suffix="${HOSTNAME:-$(hostname)}"
    export MULTICA_DAEMON_DEVICE_NAME="${MULTICA_DEVICE_NAME_PREFIX}-${suffix:0:8}"
    log "device name: ${MULTICA_DAEMON_DEVICE_NAME}"
fi

# --- 5. Daemon (foreground; tini forwards signals, reaps agent children) -----
log "starting multica daemon in foreground (daemon id: ${MULTICA_DAEMON_ID:-$(hostname)})"
exec multica daemon start --foreground
