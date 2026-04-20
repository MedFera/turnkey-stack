#!/usr/bin/env bash
# =============================================================================
# scripts/deploy.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1 — one-shot deployment driver.
#
# Runs on the Ubuntu VM host. Takes the raw repo and a pair of flags, produces
# a fully running stack at /srv/stack/ with a populated .env, containers up,
# health-check passed, and an onboarding summary on stdout.
#
# Usage:
#   sudo ./scripts/deploy.sh --domain <domain> --ip <server-ip> [options]
#
# Required:
#   --domain <domain>       e.g. company.com  or  company.localhost
#   --ip <ip>               LAN IP of this server (e.g. 192.168.1.10)
#
# Optional:
#   --client-name <name>    Company name (default: derived from --domain)
#   --admin-email <email>   Admin contact (default: admin@<domain>)
#   --timezone <tz>         IANA zone (default: system tz or UTC)
#   --kimai-email <email>   Kimai admin email (default: --admin-email)
#   --stack-root <path>     Override /srv/stack (default: /srv/stack)
#   --skip-pull             Don't `docker compose pull` (use local images)
#   --help                  Show this help and exit
#
# Idempotency:
#   - Re-running is safe. Existing .env values are preserved.
#   - Only empty variables in .env get filled; nothing is ever overwritten.
#   - docker-compose.yml, Caddyfile, backup.sh are re-copied from the repo
#     (they are treated as code, not config).
#
# Exit codes:
#   0 = deployed and healthy   1 = usage error   2 = runtime error
# =============================================================================

set -euo pipefail


# ── Defaults & CLI parsing ───────────────────────────────────────────────────
DOMAIN=""
SERVER_IP=""
CLIENT_NAME=""
ADMIN_EMAIL=""
KIMAI_ADMIN_EMAIL=""
TIMEZONE=""
STACK_ROOT="/srv/stack"
SKIP_PULL=0

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '2,/^# =\+$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (( $# > 0 )); do
  case "$1" in
    --domain)       DOMAIN="$2"; shift 2 ;;
    --ip)           SERVER_IP="$2"; shift 2 ;;
    --client-name)  CLIENT_NAME="$2"; shift 2 ;;
    --admin-email)  ADMIN_EMAIL="$2"; shift 2 ;;
    --kimai-email)  KIMAI_ADMIN_EMAIL="$2"; shift 2 ;;
    --timezone)     TIMEZONE="$2"; shift 2 ;;
    --stack-root)   STACK_ROOT="$2"; shift 2 ;;
    --skip-pull)    SKIP_PULL=1; shift ;;
    --help|-h)      usage 0 ;;
    *)              printf 'Unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done

[[ -n "${DOMAIN}" ]]    || { printf 'ERROR: --domain is required\n\n' >&2; usage 1; }
[[ -n "${SERVER_IP}" ]] || { printf 'ERROR: --ip is required\n\n' >&2; usage 1; }

# Derive defaults for optional fields.
[[ -n "${CLIENT_NAME}" ]]       || CLIENT_NAME="${DOMAIN%%.*}"
[[ -n "${ADMIN_EMAIL}" ]]       || ADMIN_EMAIL="admin@${DOMAIN}"
[[ -n "${KIMAI_ADMIN_EMAIL}" ]] || KIMAI_ADMIN_EMAIL="${ADMIN_EMAIL}"
if [[ -z "${TIMEZONE}" ]]; then
  if [[ -r /etc/timezone ]]; then
    TIMEZONE="$(tr -d ' \n' < /etc/timezone)"
  else
    TIMEZONE="UTC"
  fi
fi


# ── Output helpers ───────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
  C_B=$'\033[1m';    C_D=$'\033[2m';    C_N=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_D=''; C_N=''
fi

step()  { printf '\n%s▶ %s%s\n' "${C_B}" "$*" "${C_N}"; }
ok()    { printf '  %s✓%s %s\n' "${C_G}" "${C_N}" "$*"; }
info()  { printf '  %s·%s %s\n' "${C_D}" "${C_N}" "$*"; }
abort() { printf '\n%sERROR:%s %s\n' "${C_R}" "${C_N}" "$*" >&2; exit 2; }


# ── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight"

if [[ "${EUID}" -ne 0 ]]; then
  abort "deploy.sh must be run as root (try: sudo $0 ...)"
fi
ok "running as root"

for tool in docker openssl sed awk grep install cp; do
  command -v "${tool}" >/dev/null 2>&1 \
    || abort "required tool '${tool}' not found on PATH"
done
if ! docker compose version >/dev/null 2>&1; then
  abort "'docker compose' plugin not available (need Docker Compose v2)"
fi
ok "docker + compose v2 + secret tooling available"

info "repo dir:     ${REPO_DIR}"
info "stack root:   ${STACK_ROOT}"
info "domain:       ${DOMAIN}"
info "server ip:    ${SERVER_IP}"
info "client name:  ${CLIENT_NAME}"
info "admin email:  ${ADMIN_EMAIL}"
info "timezone:     ${TIMEZONE}"


# ── 1. Provision folders + stackuser ─────────────────────────────────────────
step "Provisioning ${STACK_ROOT}"
STACK_ROOT="${STACK_ROOT}" bash "${REPO_DIR}/scripts/init-folders.sh"


# ── 2. Copy repo artefacts into stack root ───────────────────────────────────
step "Copying stack files"

install -o stackuser -g stackuser -m 640 \
  "${REPO_DIR}/docker-compose.yml" "${STACK_ROOT}/docker-compose.yml"
ok "docker-compose.yml"

install -o stackuser -g stackuser -m 640 \
  "${REPO_DIR}/caddy/Caddyfile" "${STACK_ROOT}/caddy/Caddyfile"
ok "caddy/Caddyfile"

install -o stackuser -g stackuser -m 750 \
  "${REPO_DIR}/restic/scripts/backup.sh" "${STACK_ROOT}/restic/scripts/backup.sh"
ok "restic/scripts/backup.sh"

install -o stackuser -g stackuser -m 750 \
  "${REPO_DIR}/scripts/health-check.sh" "${STACK_ROOT}/scripts/health-check.sh"
ok "scripts/health-check.sh"

# Seed .env from template only if the existing file is empty. This preserves
# any secrets a previous deploy already populated.
ENV_FILE="${STACK_ROOT}/.env"
if [[ ! -s "${ENV_FILE}" ]]; then
  install -o stackuser -g stackuser -m 600 \
    "${REPO_DIR}/.env.template" "${ENV_FILE}"
  ok ".env seeded from template"
else
  info ".env already populated — preserving existing values"
fi


# ── 3. Populate .env ─────────────────────────────────────────────────────────
step "Filling .env"

# Set a named variable in .env. Only writes if the current value is empty,
# so re-runs never overwrite secrets a human has customized.
set_if_empty() {
  local var="$1" val="$2"
  local current
  current=$(awk -F= -v v="${var}" '$1==v {sub(/^[^=]*=/, ""); print; exit}' "${ENV_FILE}")
  if [[ -n "${current}" ]]; then
    return 0
  fi
  # Escape for sed replacement side: backslash, ampersand, pipe (our delimiter).
  local esc
  esc=$(printf '%s' "${val}" | sed -e 's/[\/&|\\]/\\&/g')
  if grep -q "^${var}=" "${ENV_FILE}"; then
    sed -i "s|^${var}=.*|${var}=${esc}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${var}" "${val}" >> "${ENV_FILE}"
  fi
}

# Random-secret helpers. `tr -d '/+='` strips characters that can trip up
# downstream config parsers (Paperless, Kimai URLs, etc.) and keeps values
# safely alphanumeric without losing meaningful entropy.
rand_b64()  { openssl rand -base64 "$1" | tr -d '/+=\n' | cut -c"1-$1"; }
rand_hex()  { openssl rand -hex "$1"; }

# Client identity
set_if_empty CLIENT_NAME        "${CLIENT_NAME}"
set_if_empty DOMAIN             "${DOMAIN}"
set_if_empty SERVER_IP          "${SERVER_IP}"
set_if_empty TIMEZONE           "${TIMEZONE}"
set_if_empty ADMIN_EMAIL        "${ADMIN_EMAIL}"
set_if_empty TRUSTED_CIDRS      "10.8.0.0/24 192.168.0.0/16"

# WireGuard routing defaults (server IP is a sane lab default for WG_HOST)
set_if_empty WG_HOST            "${SERVER_IP}"
set_if_empty WG_PORT            "51820"

# Backup defaults
set_if_empty RESTIC_REPOSITORY  "/srv/backups"
set_if_empty BACKUP_SCHEDULE    "0 2 * * *"

# Non-secret identity defaults
set_if_empty NC_ADMIN_USER       "admin"
set_if_empty PAPERLESS_ADMIN_USER "admin"
set_if_empty KIMAI_ADMIN_EMAIL   "${KIMAI_ADMIN_EMAIL}"

# Generated secrets — 32-char base64 for passwords, hex for keys/JWT.
set_if_empty NC_DB_PASS          "$(rand_b64 32)"
set_if_empty NC_ADMIN_PASS       "$(rand_b64 32)"
set_if_empty ONLYOFFICE_JWT      "$(rand_hex 32)"
set_if_empty DOLI_DB_PASS        "$(rand_b64 32)"
set_if_empty DOLI_ADMIN_PASS     "$(rand_b64 32)"
set_if_empty KIMAI_DB_PASS       "$(rand_b64 32)"
set_if_empty KIMAI_ADMIN_PASS    "$(rand_b64 32)"
set_if_empty PAPERLESS_DB_PASS   "$(rand_b64 32)"
set_if_empty PAPERLESS_SECRET    "$(rand_hex 32)"
set_if_empty PAPERLESS_ADMIN_PASS "$(rand_b64 32)"
set_if_empty DOCUSEAL_SECRET     "$(rand_hex 64)"
set_if_empty VAULTWARDEN_ADMIN   "$(rand_b64 48)"
set_if_empty WG_PASSWORD         "$(rand_b64 24)"
set_if_empty RESTIC_PASSWORD     "$(rand_b64 48)"

# Ensure mode is locked even if install step above was skipped.
chown stackuser:stackuser "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
ok ".env filled and locked to 600"


# ── 4. Build local images + pull registry images ─────────────────────────────
step "Building local images (stack-restic)"
(cd "${STACK_ROOT}" && docker compose build)

if (( SKIP_PULL == 0 )); then
  step "Pulling registry images"
  # Compose pull will attempt the build-tagged image against the registry and
  # warn (not fail) when it's not found — expected and harmless.
  (cd "${STACK_ROOT}" && docker compose pull || true)
else
  info "skipping image pull (--skip-pull)"
fi


# ── 5. Bring up the stack ────────────────────────────────────────────────────
step "Starting stack"
(cd "${STACK_ROOT}" && docker compose up -d --remove-orphans)


# ── 6. Wait for containers ───────────────────────────────────────────────────
step "Waiting for containers to stabilize"
# Poll docker ps until every expected container is "running" OR 5 minutes
# elapse. We defer HTTP checks to health-check.sh afterwards.
EXPECTED=(
  stack-caddy stack-nextcloud-db stack-nextcloud-redis stack-nextcloud
  stack-onlyoffice stack-dolibarr-db stack-dolibarr stack-wg-easy
  stack-uptime-kuma stack-stirling-pdf stack-docuseal stack-kimai-db
  stack-kimai stack-paperless-db stack-paperless-redis stack-paperless
  stack-vaultwarden stack-restic stack-ofelia
)
DEADLINE=$(( $(date +%s) + 300 ))
while :; do
  missing=0
  for c in "${EXPECTED[@]}"; do
    state=$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo "absent")
    [[ "${state}" == "running" ]] || { missing=1; break; }
  done
  (( missing == 0 )) && break
  if (( $(date +%s) > DEADLINE )); then
    printf '\n'
    abort "Timed out waiting for containers to come up. Run: docker compose ps"
  fi
  printf '.'
  sleep 5
done
printf '\n'
ok "all ${#EXPECTED[@]} containers running"


# ── 7. Final health check ────────────────────────────────────────────────────
step "Running health-check.sh"
# Give apps a grace period to finish their first-run DB migrations before we
# probe HTTP — large migrations (Nextcloud, Paperless) can take 30–90s.
info "allowing 30s for first-run migrations..."
sleep 30
set +e
"${REPO_DIR}/scripts/health-check.sh"
HEALTH_RC=$?
set -e


# ── 8. Onboarding summary ────────────────────────────────────────────────────
printf '\n%s%s╔════════════════════════════════════════════════════════════╗%s\n' "${C_B}" "${C_G}" "${C_N}"
printf '%s%s║             TURNKEY STACK — DEPLOYMENT COMPLETE            ║%s\n'   "${C_B}" "${C_G}" "${C_N}"
printf '%s%s╚════════════════════════════════════════════════════════════╝%s\n\n' "${C_B}" "${C_G}" "${C_N}"

printf '%sClient:%s  %s\n' "${C_B}" "${C_N}" "${CLIENT_NAME}"
printf '%sDomain:%s  %s\n' "${C_B}" "${C_N}" "${DOMAIN}"
printf '%sServer:%s  %s\n\n' "${C_B}" "${C_N}" "${SERVER_IP}"

printf '%sService URLs%s\n' "${C_B}" "${C_N}"
printf '  %s✓%s cloud.%s       %s→%s Nextcloud files & collaboration\n'    "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s docs.%s        %s→%s ONLYOFFICE document editor\n'         "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s crm.%s         %s→%s Dolibarr CRM %s(VPN only)%s\n'        "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}" "${C_Y}" "${C_N}"
printf '  %s✓%s sign.%s        %s→%s DocuSeal document signing\n'          "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s pdf.%s         %s→%s Stirling-PDF editor\n'                "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s time.%s        %s→%s Kimai time tracking\n'                "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s archive.%s     %s→%s Paperless document archive\n'         "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s vault.%s       %s→%s Vaultwarden passwords\n'              "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}"
printf '  %s✓%s vpn.%s         %s→%s WireGuard VPN %s(VPN only)%s\n'       "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}" "${C_Y}" "${C_N}"
printf '  %s✓%s status.%s      %s→%s Uptime Kuma %s(VPN only)%s\n\n'       "${C_G}" "${C_N}" "${DOMAIN}" "${C_D}" "${C_N}" "${C_Y}" "${C_N}"

printf '%sAdmin credentials%s (copy to Vaultwarden / offline vault)\n' "${C_B}" "${C_N}"
printf '  Generated secrets live in: %s%s%s  (chmod 600, stackuser:stackuser)\n' "${C_B}" "${ENV_FILE}" "${C_N}"
printf '  View with: %ssudo -u stackuser cat %s%s\n\n' "${C_B}" "${ENV_FILE}" "${C_N}"

printf '%sNext steps%s\n' "${C_B}" "${C_N}"
printf '  1. DNS: point %s*.%s%s to %s%s%s (wildcard A-record)\n' "${C_B}" "${DOMAIN}" "${C_N}" "${C_B}" "${SERVER_IP}" "${C_N}"
printf '  2. Firewall: open %sTCP 443%s and %sUDP $WG_PORT%s on the router\n' "${C_B}" "${C_N}" "${C_B}" "${C_N}"
printf '  3. VPN: visit %shttps://vpn.%s%s (from LAN) to create your first peer\n' "${C_B}" "${DOMAIN}" "${C_N}"
printf '  4. Log into Nextcloud at %shttps://cloud.%s%s and wire ONLYOFFICE to %shttps://docs.%s%s\n' "${C_B}" "${DOMAIN}" "${C_N}" "${C_B}" "${DOMAIN}" "${C_N}"
printf '  5. Verify backups tomorrow: %stail %s/restic/logs/backup.log%s\n\n' "${C_B}" "${STACK_ROOT}" "${C_N}"

if (( HEALTH_RC != 0 )); then
  printf '%s⚠ health-check.sh reported DEGRADED — investigate before onboarding users.%s\n\n' "${C_Y}" "${C_N}"
  exit 2
fi

exit 0
