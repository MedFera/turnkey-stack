#!/usr/bin/env bash
# =============================================================================
# scripts/deploy.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1 — deployment driver.
#
# Philosophy: validator + sync tool, not a thin cp wrapper. Every stage
# validates what it's about to touch and fails early with a precise message.
#
# Pipeline (each stage can fail independently):
#   1. parse_args              flags + required inputs
#   2. init_logging            color + dry-run-aware run() helper
#   3. preflight_checks        shell, tools, docker daemon, buildx, rsync
#   4. validate_repo           repo structure + build contexts at source
#   5. validate_domain_ip      catch .localhost with non-loopback IP, etc.
#   6. prepare_target          init-folders.sh — creates /srv/stack + user
#   7. sync_files              rsync WHOLE directories (not individual files)
#   8. verify_sync             every expected target file is present
#   9. render_env              fill .env with secrets (preserves existing vals)
#  10. validate_compose        `docker compose config` catches YAML / var bugs
#  11. build_images            stack-restic from ./restic/Dockerfile
#  12. pull_images             registry images (skippable)
#  13. start_stack             docker compose up -d
#  14. wait_for_containers     poll until every container is "running"
#  15. run_health_check        scripts/health-check.sh
#  16. print_summary           onboarding URLs + next steps
#
# Usage:
#   sudo ./scripts/deploy.sh --domain <domain> --ip <server-ip> [options]
#
# Required:
#   --domain <domain>         e.g. company.com  or  company.test
#   --ip <ip>                 LAN IP of this server (e.g. 192.168.1.10)
#
# Optional:
#   --client-name <name>      Company name (default: first label of domain)
#   --admin-email <email>     Admin contact (default: admin@<domain>)
#   --kimai-email <email>     Kimai admin (default: --admin-email)
#   --timezone <tz>           IANA zone (default: system tz or UTC)
#   --stack-root <path>       Override /srv/stack (default: /srv/stack)
#   --skip-pull               Don't pull registry images (offline deploys)
#   --dry-run                 Print every mutation instead of running it
#   --force                   Bypass domain/IP sanity check
#   --help                    Show help
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'


# ── Constants ────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Required paths inside the repo. sync_files / verify_sync consume these.
# Any compose build context listed in docker-compose.yml MUST appear here.
REQUIRED_REPO_PATHS=(
  "docker-compose.yml"
  ".env.template"
  "caddy/Caddyfile"
  "restic/Dockerfile"
  "restic/scripts/backup.sh"
  "scripts/init-folders.sh"
  "scripts/health-check.sh"
  "scripts/configure-apps.sh"
)

# Directories copied as a whole unit (preserves everything — future files too).
SYNC_DIRS=(
  "caddy"
  "restic"
  "scripts"
)

# Compose `build.context` entries, relative to compose file location.
# Every entry here is validated BEFORE AND AFTER the sync step.
BUILD_CONTEXTS=(
  "restic"
)

# Expected containers post-up (kept in one place, referenced by wait_for_containers).
EXPECTED_CONTAINERS=(
  stack-caddy
  stack-nextcloud-db stack-nextcloud-redis stack-nextcloud
  stack-onlyoffice
  stack-dolibarr-db stack-dolibarr
  stack-wg-easy
  stack-uptime-kuma
  stack-stirling-pdf
  stack-docuseal
  stack-kimai-db stack-kimai
  stack-paperless-db stack-paperless-redis stack-paperless
  stack-vaultwarden
  stack-restic stack-ofelia
)


# ── Defaults (filled by parse_args) ──────────────────────────────────────────
DOMAIN=""
SERVER_IP=""
CLIENT_NAME=""
ADMIN_EMAIL=""
KIMAI_ADMIN_EMAIL=""
TIMEZONE=""
STACK_ROOT="/srv/stack"
SKIP_PULL=0
DRY_RUN=0
FORCE=0


# ── Logging helpers ──────────────────────────────────────────────────────────
init_logging() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
    C_B=$'\033[1m';    C_D=$'\033[2m';    C_N=$'\033[0m'
  else
    C_G=''; C_R=''; C_Y=''; C_B=''; C_D=''; C_N=''
  fi
}

log()  { printf '\n%s▶ %s%s\n' "${C_B}" "$*" "${C_N}"; }
ok()   { printf '  %s✓%s %s\n'  "${C_G}" "${C_N}" "$*"; }
info() { printf '  %s·%s %s\n'  "${C_D}" "${C_N}" "$*"; }
warn() { printf '  %s!%s %s\n'  "${C_Y}" "${C_N}" "$*" >&2; }
die()  { printf '\n  %s✗ %s%s\n\n' "${C_R}" "$*" "${C_N}" >&2; exit 1; }

# Run a command. In dry-run mode, echo it instead of executing. All real
# filesystem / docker mutations go through run() so `--dry-run` is meaningful.
run() {
  if (( DRY_RUN )); then
    printf '  %s[dry-run]%s %s\n' "${C_Y}" "${C_N}" "$*"
    return 0
  fi
  "$@"
}

# ERR trap — precise failure location. Avoid calling die() (it would recurse
# through the trap handler); just echo and exit.
on_err() {
  local exit_code=$? line=$1 cmd=$2
  printf '\n%s✗ deploy.sh failed%s (line %s, exit %s):\n    %s\n\n' \
    "${C_R}${C_B}" "${C_N}" "${line}" "${exit_code}" "${cmd}" >&2
  exit "${exit_code}"
}


# ── Stage 1: parse_args ──────────────────────────────────────────────────────
parse_args() {
  local arg
  while (( $# > 0 )); do
    arg="$1"
    case "${arg}" in
      --domain)       DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
      --ip)           SERVER_IP="${2:?--ip needs a value}"; shift 2 ;;
      --client-name)  CLIENT_NAME="${2:?}"; shift 2 ;;
      --admin-email)  ADMIN_EMAIL="${2:?}"; shift 2 ;;
      --kimai-email)  KIMAI_ADMIN_EMAIL="${2:?}"; shift 2 ;;
      --timezone)     TIMEZONE="${2:?}"; shift 2 ;;
      --stack-root)   STACK_ROOT="${2:?}"; shift 2 ;;
      --skip-pull)    SKIP_PULL=1; shift ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --force)        FORCE=1; shift ;;
      --help|-h)      usage; exit 0 ;;
      *)              printf 'Unknown argument: %s\n\n' "${arg}" >&2; usage; exit 1 ;;
    esac
  done

  [[ -n "${DOMAIN}" ]]    || { printf 'ERROR: --domain is required\n\n' >&2; usage; exit 1; }
  [[ -n "${SERVER_IP}" ]] || { printf 'ERROR: --ip is required\n\n' >&2; usage; exit 1; }

  # Derive optional-field defaults.
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
}

usage() {
  sed -n '2,/^# =\+$/p' "$0" | sed 's/^# \{0,1\}//'
}


# ── Stage 2: preflight_checks ────────────────────────────────────────────────
require_cmd() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    local msg="Missing required command: ${cmd}"
    [[ -n "${hint}" ]] && msg="${msg}  (${hint})"
    die "${msg}"
  fi
  ok "${cmd}"
}

preflight_checks() {
  log "Preflight"

  if [[ "${EUID}" -ne 0 ]]; then
    die "deploy.sh must run as root (try: sudo $0 ...)"
  fi
  ok "running as root"

  # Core POSIX tools the script relies on. rsync is NOT universally present
  # on minimal Ubuntu images — call it out explicitly.
  require_cmd bash
  require_cmd awk
  require_cmd sed
  require_cmd grep
  require_cmd install
  require_cmd openssl
  require_cmd rsync   "install with: apt-get install -y rsync"
  require_cmd docker  "install with: apt-get install -y docker.io"

  # Docker installed AND daemon reachable. These are separate failures.
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but not usable.
  - Is the daemon running?    systemctl status docker
  - Does this user have access to /var/run/docker.sock?
  - Try:  sudo systemctl start docker  &&  sudo usermod -aG docker \"\$USER\""
  fi
  ok "docker daemon reachable"

  # Compose v2 plugin.
  if ! docker compose version >/dev/null 2>&1; then
    die "'docker compose' plugin missing. Install with:
  apt-get install -y docker-compose-plugin
or for Ubuntu 24.04:
  apt-get install -y docker-compose-v2"
  fi
  ok "docker compose v2 plugin"

  # Buildx — needed to build stack-restic via compose v2's BuildKit frontend.
  if ! docker buildx version >/dev/null 2>&1; then
    die "Docker buildx missing — compose v2 needs it to build stack-restic.
  Install with: apt-get install -y docker-buildx-plugin"
  fi
  ok "docker buildx"

  info "repo dir:     ${REPO_DIR}"
  info "stack root:   ${STACK_ROOT}"
  info "domain:       ${DOMAIN}"
  info "server ip:    ${SERVER_IP}"
  info "client:       ${CLIENT_NAME}"
  info "admin email:  ${ADMIN_EMAIL}"
  info "timezone:     ${TIMEZONE}"
  if (( DRY_RUN )); then warn "DRY-RUN mode: no files or containers will be touched"; fi
}


# ── Stage 3: validate_repo ───────────────────────────────────────────────────
validate_repo() {
  log "Validating repo structure"
  local path
  for path in "${REQUIRED_REPO_PATHS[@]}"; do
    if [[ ! -e "${REPO_DIR}/${path}" ]]; then
      die "Required repo path missing: ${REPO_DIR}/${path}"
    fi
    ok "${path}"
  done

  # Every compose build context must have a Dockerfile at its root.
  # This is the check that would have caught the original bug (backup.sh
  # was copied, Dockerfile was not, compose build failed with a cryptic
  # Docker error) BEFORE any filesystem mutation.
  local ctx
  for ctx in "${BUILD_CONTEXTS[@]}"; do
    [[ -d "${REPO_DIR}/${ctx}" ]] \
      || die "Missing build context directory: ${REPO_DIR}/${ctx}"
    [[ -f "${REPO_DIR}/${ctx}/Dockerfile" ]] \
      || die "Missing Dockerfile in build context: ${REPO_DIR}/${ctx}/Dockerfile"
    ok "build context ${ctx}/ has Dockerfile"
  done
}


# ── Stage 4: validate_domain_ip ──────────────────────────────────────────────
# .localhost is reserved for loopback (RFC 6761). Pairing it with a LAN IP
# means *.company.localhost won't resolve from other machines on the LAN —
# clients hitting the URL will connect to their OWN 127.0.0.1. This is a
# silent-failure class bug.
validate_domain_ip() {
  log "Validating domain / IP pairing"

  local is_loopback=0
  case "${SERVER_IP}" in
    127.*|::1|localhost) is_loopback=1 ;;
  esac

  case "${DOMAIN}" in
    *.localhost)
      if (( is_loopback )); then
        ok "${DOMAIN} + loopback IP — OK for on-VM testing only"
      elif (( FORCE )); then
        warn "${DOMAIN} + non-loopback IP ${SERVER_IP} — bypassed with --force"
      else
        die "Domain '${DOMAIN}' is under .localhost (RFC 6761 loopback-only),
  but server IP ${SERVER_IP} is a LAN/public address.

  Other machines on the LAN will NOT resolve *.localhost to this VM — their
  browsers will try to connect to their own 127.0.0.1 and fail.

  Fix one of:
    - Use a reserved lab TLD: --domain company.test   (RFC 2606)
    - Use an internal TLD:    --domain company.internal  /  company.lab
    - Use a real domain with wildcard DNS: --domain company.com
    - Override (local-only testing): add --force"
      fi
      ;;
    *.test|*.internal|*.lab|*.home.arpa|*.intranet)
      ok "${DOMAIN} — reserved lab/internal TLD"
      info "clients must map *.${DOMAIN} in /etc/hosts or via local DNS"
      ;;
    *)
      # Anything else is assumed to be a real, publicly registered domain.
      ok "${DOMAIN} — Caddy will request Let's Encrypt certs on first hit"
      ;;
  esac
}


# ── Stage 5: prepare_target ──────────────────────────────────────────────────
prepare_target() {
  log "Preparing ${STACK_ROOT}"
  # init-folders.sh is idempotent — runs happily on pre-existing trees.
  run env STACK_ROOT="${STACK_ROOT}" bash "${REPO_DIR}/scripts/init-folders.sh"
}


# ── Stage 6: sync_files ──────────────────────────────────────────────────────
# rsync WHOLE directories — never individual files from a directory that is
# also a build context. Missing a single file in a build context means the
# Docker build fails with a confusing error (the original bug).
sync_files() {
  log "Syncing stack files with rsync"

  # Top-level docker-compose.yml (not inside any SYNC_DIRS).
  run rsync -a --chmod=D750,F640 \
    "${REPO_DIR}/docker-compose.yml" "${STACK_ROOT}/docker-compose.yml"
  ok "docker-compose.yml"

  local d
  for d in "${SYNC_DIRS[@]}"; do
    if [[ ! -d "${REPO_DIR}/${d}" ]]; then
      # Already enforced by validate_repo; defensive double-check.
      die "Source directory missing: ${REPO_DIR}/${d}"
    fi
    # --delete removes stale files (e.g. renamed Dockerfile in restic/).
    # Trailing slash on SOURCE + bare TARGET = "copy contents into target".
    run rsync -a --delete \
      "${REPO_DIR}/${d}/" "${STACK_ROOT}/${d}/"
    ok "${d}/"
  done

  # Seed .env from template only if the current file is empty.
  # init-folders.sh pre-creates an empty 600 .env; we never clobber a
  # populated one.
  local env_file="${STACK_ROOT}/.env"
  if [[ ! -s "${env_file}" ]]; then
    run install -o stackuser -g stackuser -m 600 \
      "${REPO_DIR}/.env.template" "${env_file}"
    ok ".env seeded from template"
  else
    info ".env already populated — preserving existing values"
  fi

  # Enforce ownership + executable bits in one pass. rsync -a preserves
  # source uid/gid (which would be root after git clone), which is not
  # what we want for runtime files.
  run chown -R stackuser:stackuser "${STACK_ROOT}/caddy" \
    "${STACK_ROOT}/restic" "${STACK_ROOT}/scripts" \
    "${STACK_ROOT}/docker-compose.yml"
  run chmod 755 "${STACK_ROOT}/scripts" "${STACK_ROOT}/restic/scripts"
  run find "${STACK_ROOT}/scripts" "${STACK_ROOT}/restic/scripts" \
    -type f -name '*.sh' -exec chmod 755 {} +
  run chown stackuser:stackuser "${env_file}"
  run chmod 600 "${env_file}"
  ok "ownership + executable bits set"
}


# ── Stage 7: verify_sync ─────────────────────────────────────────────────────
# Post-copy verification. Mirrors REQUIRED_REPO_PATHS but checked on the
# TARGET side. Any missing file here = sync bug; fail before we try to build.
verify_sync() {
  log "Verifying synced layout"
  local required=(
    "${STACK_ROOT}/.env"
    "${STACK_ROOT}/docker-compose.yml"
    "${STACK_ROOT}/caddy/Caddyfile"
    "${STACK_ROOT}/restic/Dockerfile"
    "${STACK_ROOT}/restic/scripts/backup.sh"
    "${STACK_ROOT}/scripts/health-check.sh"
  )
  local p
  for p in "${required[@]}"; do
    [[ -e "${p}" ]] || die "Sync verification failed — missing: ${p}"
    ok "${p#${STACK_ROOT}/}"
  done

  # Re-check build contexts on the TARGET side — guards against a
  # --dry-run misconfiguration or a partial rsync.
  local ctx
  for ctx in "${BUILD_CONTEXTS[@]}"; do
    if (( DRY_RUN == 0 )); then
      [[ -d "${STACK_ROOT}/${ctx}" ]] \
        || die "Build context missing at target: ${STACK_ROOT}/${ctx}"
      [[ -f "${STACK_ROOT}/${ctx}/Dockerfile" ]] \
        || die "Dockerfile missing at target: ${STACK_ROOT}/${ctx}/Dockerfile"
    fi
    ok "build context ${STACK_ROOT}/${ctx} complete"
  done
}


# ── Stage 8: render_env ──────────────────────────────────────────────────────
# Fill .env with deploy values + auto-generated secrets, but ONLY where the
# field is currently empty. Re-running deploy.sh on a populated .env never
# clobbers operator edits.
render_env() {
  log "Rendering .env"

  local env_file="${STACK_ROOT}/.env"

  # In dry-run we can't actually mutate .env (and we shouldn't — the file
  # may already hold real secrets). Skip gracefully.
  if (( DRY_RUN )); then
    info "dry-run: skipping .env mutation"
    return 0
  fi

  # Helper: set a variable only if its current value is empty.
  set_if_empty() {
    local var="$1" val="$2"
    local current
    current=$(awk -F= -v v="${var}" '$1==v {sub(/^[^=]*=/, ""); print; exit}' "${env_file}")
    if [[ -n "${current}" ]]; then
      return 0
    fi
    # Escape for sed replacement: backslash, ampersand, pipe (delimiter).
    local esc
    esc=$(printf '%s' "${val}" | sed -e 's/[\/&|\\]/\\&/g')
    if grep -q "^${var}=" "${env_file}"; then
      sed -i "s|^${var}=.*|${var}=${esc}|" "${env_file}"
    else
      printf '%s=%s\n' "${var}" "${val}" >> "${env_file}"
    fi
  }

  # Strip /+= to keep values URL-safe (matters for DATABASE_URL and similar).
  rand_b64() { openssl rand -base64 "$1" | tr -d '/+=\n' | cut -c"1-$1"; }
  rand_hex() { openssl rand -hex "$1"; }

  # Identity
  set_if_empty CLIENT_NAME         "${CLIENT_NAME}"
  set_if_empty DOMAIN              "${DOMAIN}"
  set_if_empty SERVER_IP           "${SERVER_IP}"
  set_if_empty TIMEZONE            "${TIMEZONE}"
  set_if_empty ADMIN_EMAIL         "${ADMIN_EMAIL}"
  set_if_empty TRUSTED_CIDRS       "10.8.0.0/24 192.168.0.0/16"

  # WireGuard defaults
  set_if_empty WG_HOST             "${SERVER_IP}"
  set_if_empty WG_PORT             "51820"

  # Backup defaults
  set_if_empty RESTIC_REPOSITORY   "/srv/backups"
  set_if_empty BACKUP_SCHEDULE     "0 2 * * *"

  # Non-secret identity
  set_if_empty NC_ADMIN_USER         "admin"
  set_if_empty PAPERLESS_ADMIN_USER  "admin"
  set_if_empty KIMAI_ADMIN_EMAIL     "${KIMAI_ADMIN_EMAIL}"

  # Generated secrets
  set_if_empty NC_DB_PASS           "$(rand_b64 32)"
  set_if_empty NC_ADMIN_PASS        "$(rand_b64 32)"
  set_if_empty ONLYOFFICE_JWT       "$(rand_hex 32)"
  set_if_empty DOLI_DB_PASS         "$(rand_b64 32)"
  set_if_empty DOLI_ADMIN_PASS      "$(rand_b64 32)"
  set_if_empty KIMAI_DB_PASS        "$(rand_b64 32)"
  set_if_empty KIMAI_ADMIN_PASS     "$(rand_b64 32)"
  set_if_empty PAPERLESS_DB_PASS    "$(rand_b64 32)"
  set_if_empty PAPERLESS_SECRET     "$(rand_hex 32)"
  set_if_empty PAPERLESS_ADMIN_PASS "$(rand_b64 32)"
  set_if_empty DOCUSEAL_SECRET      "$(rand_hex 64)"
  set_if_empty VAULTWARDEN_ADMIN    "$(rand_b64 48)"
  set_if_empty WG_PASSWORD          "$(rand_b64 24)"
  set_if_empty RESTIC_PASSWORD      "$(rand_b64 48)"

  chown stackuser:stackuser "${env_file}"
  chmod 600 "${env_file}"
  ok ".env rendered and locked to 600"
}


# ── Stage 9: validate_compose ────────────────────────────────────────────────
# `docker compose config` fully parses the file and resolves every ${VAR}
# against the target .env. Catches: YAML errors, undefined env vars,
# malformed service refs, bad volume paths, etc.
validate_compose() {
  log "Validating compose configuration"
  if (( DRY_RUN )); then
    info "dry-run: skipping compose config (.env not populated in dry mode)"
    return 0
  fi
  if ! (cd "${STACK_ROOT}" && docker compose config >/dev/null); then
    die "docker compose config failed — fix YAML or env vars before proceeding.
  Run interactively to see the full parser error:
    cd ${STACK_ROOT} && docker compose config"
  fi
  ok "compose config valid"
}


# ── Stage 10: build_images ───────────────────────────────────────────────────
build_images() {
  log "Building local images (stack-restic)"
  run bash -c "cd '${STACK_ROOT}' && docker compose build"
}


# ── Stage 11: pull_images ────────────────────────────────────────────────────
pull_images() {
  if (( SKIP_PULL )); then
    log "Pulling registry images"; info "skipped (--skip-pull)"
    return 0
  fi
  log "Pulling registry images"
  # compose pull attempts the locally-tagged build image against registry
  # and warns when it's not found — expected and harmless, hence `|| true`.
  run bash -c "cd '${STACK_ROOT}' && docker compose pull || true"
}


# ── Stage 12: start_stack ────────────────────────────────────────────────────
start_stack() {
  log "Starting stack"
  run bash -c "cd '${STACK_ROOT}' && docker compose up -d --remove-orphans"
}


# ── Stage 13: wait_for_containers ────────────────────────────────────────────
wait_for_containers() {
  log "Waiting for containers to stabilize"
  if (( DRY_RUN )); then
    info "dry-run: skipping wait"
    return 0
  fi

  local deadline=$(( $(date +%s) + 300 ))
  local c state missing
  while :; do
    missing=0
    for c in "${EXPECTED_CONTAINERS[@]}"; do
      state=$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo "absent")
      [[ "${state}" == "running" ]] || { missing=1; break; }
    done
    (( missing == 0 )) && break
    if (( $(date +%s) > deadline )); then
      printf '\n'
      die "Timed out waiting for containers. Inspect with:
    docker compose ps
    docker compose logs --tail=50"
    fi
    printf '.'
    sleep 5
  done
  printf '\n'
  ok "all ${#EXPECTED_CONTAINERS[@]} containers running"
}


# ── Stage 14: run_health_check ───────────────────────────────────────────────
run_health_check() {
  log "Running health-check.sh"
  if (( DRY_RUN )); then
    info "dry-run: skipping health check"
    HEALTH_RC=0
    return 0
  fi
  info "allowing 30s for first-run DB migrations..."
  sleep 30
  set +e
  "${STACK_ROOT}/scripts/health-check.sh"
  HEALTH_RC=$?
  set -e
}


# ── Stage 15: print_summary ──────────────────────────────────────────────────
print_summary() {
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

  printf '%sCredentials%s — generated in %s (chmod 600, stackuser)\n' \
    "${C_B}" "${C_N}" "${STACK_ROOT}/.env"
  printf '  View:  %ssudo -u stackuser cat %s/.env%s\n\n' "${C_B}" "${STACK_ROOT}" "${C_N}"

  printf '%sNext steps%s\n' "${C_B}" "${C_N}"
  printf '  1. %sRun the app-wiring script:%s  %ssudo scripts/configure-apps.sh%s\n' "${C_B}" "${C_N}" "${C_B}" "${C_N}"
  printf '     (wires Nextcloud↔ONLYOFFICE JWT, SMTP, Paperless tags, and prints\n'
  printf '      the browser-only manual steps you still need to complete.)\n'
  printf '  2. DNS: point %s*.%s%s to %s%s%s (or map in /etc/hosts for labs)\n' "${C_B}" "${DOMAIN}" "${C_N}" "${C_B}" "${SERVER_IP}" "${C_N}"
  printf '  3. Firewall: open %sTCP 443%s + %sUDP $WG_PORT%s on the router\n' "${C_B}" "${C_N}" "${C_B}" "${C_N}"
  printf '  4. VPN: visit %shttps://vpn.%s%s (from LAN) and create first peer\n' "${C_B}" "${DOMAIN}" "${C_N}"
  printf '  5. Verify backups tomorrow: %stail %s/restic/logs/backup.log%s\n\n' "${C_B}" "${STACK_ROOT}" "${C_N}"

  if (( ${HEALTH_RC:-0} != 0 )); then
    printf '%s⚠ health-check.sh reported DEGRADED — investigate before onboarding users.%s\n\n' "${C_Y}" "${C_N}"
    return 2
  fi
  return 0
}


# ── main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  init_logging
  trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

  preflight_checks
  validate_repo
  validate_domain_ip
  prepare_target
  sync_files
  verify_sync
  render_env
  validate_compose
  build_images
  pull_images
  start_stack
  wait_for_containers
  run_health_check
  print_summary
}

main "$@"
