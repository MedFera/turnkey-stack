#!/usr/bin/env bash
# =============================================================================
# init-folders.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1
# Provisions the /srv/stack/ directory tree, creates the non-root "stackuser"
# system account, and applies the standard ownership/permission model.
#
# Usage:
#   sudo ./scripts/init-folders.sh
#
# Notes:
#   - Must be run as root (uses useradd, chown, chmod on system paths).
#   - Idempotent: safe to re-run. Existing dirs/users are left intact.
#   - Does NOT install Docker, create .env, or pull images — that is deploy.sh.
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
STACK_ROOT="${STACK_ROOT:-/srv/stack}"
STACK_USER="${STACK_USER:-stackuser}"
STACK_GROUP="${STACK_GROUP:-stackuser}"
DIR_MODE="750"
ENV_FILE_MODE="600"

# ── Pre-flight checks ────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: init-folders.sh must be run as root (try: sudo $0)" >&2
  exit 1
fi

log() { printf '[init-folders] %s\n' "$*"; }

# ── Create system user ───────────────────────────────────────────────────────
# Non-login system account that owns /srv/stack/ and runs Docker containers
# via its UID/GID being referenced in docker-compose.yml where appropriate.
if id -u "${STACK_USER}" >/dev/null 2>&1; then
  log "User '${STACK_USER}' already exists — skipping creation"
else
  log "Creating system user '${STACK_USER}'"
  useradd \
    --system \
    --user-group \
    --shell /usr/sbin/nologin \
    --home-dir "${STACK_ROOT}" \
    --no-create-home \
    "${STACK_USER}"
fi

# Add stackuser to the docker group if it exists (lets non-root ops manage the
# stack without sudo once Docker is installed).
if getent group docker >/dev/null 2>&1; then
  if ! id -nG "${STACK_USER}" | tr ' ' '\n' | grep -qx docker; then
    log "Adding '${STACK_USER}' to 'docker' group"
    usermod -aG docker "${STACK_USER}"
  fi
fi

# ── Directory tree ───────────────────────────────────────────────────────────
# Full /srv/stack/ layout per spec. Each app gets its own subtree so that
# backups and restores are scoped per-service.
DIRS=(
  "${STACK_ROOT}"
  "${STACK_ROOT}/caddy"
  "${STACK_ROOT}/caddy/data"
  "${STACK_ROOT}/caddy/config"
  "${STACK_ROOT}/nextcloud"
  "${STACK_ROOT}/nextcloud/data"
  "${STACK_ROOT}/nextcloud/config"
  "${STACK_ROOT}/nextcloud/db"
  "${STACK_ROOT}/onlyoffice"
  "${STACK_ROOT}/onlyoffice/data"
  "${STACK_ROOT}/onlyoffice/logs"
  "${STACK_ROOT}/dolibarr"
  "${STACK_ROOT}/dolibarr/documents"
  "${STACK_ROOT}/dolibarr/db"
  "${STACK_ROOT}/wireguard"
  "${STACK_ROOT}/wireguard/config"
  "${STACK_ROOT}/uptime-kuma"
  "${STACK_ROOT}/uptime-kuma/data"
  "${STACK_ROOT}/stirling-pdf"
  "${STACK_ROOT}/stirling-pdf/training-data"
  "${STACK_ROOT}/stirling-pdf/tessdata"
  "${STACK_ROOT}/stirling-pdf/logs"
  "${STACK_ROOT}/docuseal"
  "${STACK_ROOT}/docuseal/data"
  "${STACK_ROOT}/kimai"
  "${STACK_ROOT}/kimai/data"
  "${STACK_ROOT}/kimai/db"
  "${STACK_ROOT}/paperless"
  "${STACK_ROOT}/paperless/data"
  "${STACK_ROOT}/paperless/media"
  "${STACK_ROOT}/paperless/export"
  "${STACK_ROOT}/paperless/consume"
  "${STACK_ROOT}/paperless/db"
  "${STACK_ROOT}/vaultwarden"
  "${STACK_ROOT}/vaultwarden/data"
  "${STACK_ROOT}/restic"
  "${STACK_ROOT}/restic/scripts"
  "${STACK_ROOT}/restic/logs"
  "${STACK_ROOT}/scripts"
)

log "Creating directory tree under ${STACK_ROOT}"
for d in "${DIRS[@]}"; do
  if [[ ! -d "${d}" ]]; then
    install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m "${DIR_MODE}" "${d}"
  else
    # Re-apply ownership/mode in case something drifted (idempotent)
    chown "${STACK_USER}:${STACK_GROUP}" "${d}"
    chmod "${DIR_MODE}" "${d}"
  fi
done

# ── .env placeholder ─────────────────────────────────────────────────────────
# We do NOT generate the .env here (that's deploy.sh's job). But we pre-create
# the file with 600 perms so secrets written later are never world-readable,
# even for a split second.
ENV_FILE="${STACK_ROOT}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  log "Creating empty ${ENV_FILE} (chmod ${ENV_FILE_MODE})"
  install -o "${STACK_USER}" -g "${STACK_GROUP}" -m "${ENV_FILE_MODE}" \
    /dev/null "${ENV_FILE}"
else
  chown "${STACK_USER}:${STACK_GROUP}" "${ENV_FILE}"
  chmod "${ENV_FILE_MODE}" "${ENV_FILE}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
log "Directory tree ready at ${STACK_ROOT}"
log "Owner: ${STACK_USER}:${STACK_GROUP}   Dir mode: ${DIR_MODE}   .env mode: ${ENV_FILE_MODE}"
log "Next step: copy .env.template → ${ENV_FILE} and run scripts/deploy.sh"
