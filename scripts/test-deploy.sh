#!/usr/bin/env bash
# =============================================================================
# scripts/test-deploy.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1 — lab-VM acceptance test.
#
# Run this on a THROWAWAY lab VM after deploy.sh completes. It goes further
# than health-check.sh: round-trips the backup, verifies a restore, validates
# the Caddy config, and probes the VPN gate. Use it before handing any client
# a deployed stack.
#
# Usage:
#   sudo ./scripts/test-deploy.sh                 # full test suite
#   sudo ./scripts/test-deploy.sh --fix-hosts     # add lab /etc/hosts entries
#   sudo ./scripts/test-deploy.sh --skip-restore  # faster, no restore round-trip
#   sudo ./scripts/test-deploy.sh --teardown      # docker compose down -v
#
# Safety:
#   Refuses to run if DOMAIN in .env does NOT end in `.localhost` unless the
#   `--force` flag is passed. This prevents accidentally running destructive
#   backup/restore round-trips against a production deploy.
#
# Exit:   0 = all tests passed   1 = one or more failed   2 = refused to run
# =============================================================================

set -euo pipefail


# ── Config ───────────────────────────────────────────────────────────────────
STACK_ROOT="${STACK_ROOT:-/srv/stack}"
ENV_FILE="${STACK_ROOT}/.env"
FIX_HOSTS=0
SKIP_RESTORE=0
TEARDOWN=0
FORCE=0

usage() {
  sed -n '2,/^# =\+$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (( $# > 0 )); do
  case "$1" in
    --fix-hosts)     FIX_HOSTS=1; shift ;;
    --skip-restore)  SKIP_RESTORE=1; shift ;;
    --teardown)      TEARDOWN=1; shift ;;
    --force)         FORCE=1; shift ;;
    --help|-h)       usage 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done


# ── Output ───────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
  C_B=$'\033[1m';    C_D=$'\033[2m';    C_N=$'\033[0m'
else C_G=''; C_R=''; C_Y=''; C_B=''; C_D=''; C_N=''; fi

PASS=0; FAIL=0
phase() { printf '\n%s▶ %s%s\n' "${C_B}" "$*" "${C_N}"; }
pass()  { printf '  %s✓%s %s\n'  "${C_G}" "${C_N}" "$*"; PASS=$((PASS+1)); }
fail()  { printf '  %s✗%s %s\n'  "${C_R}" "${C_N}" "$*"; FAIL=$((FAIL+1)); }
skip()  { printf '  %s~%s %s\n'  "${C_Y}" "${C_N}" "$*"; }
info()  { printf '  %s·%s %s\n'  "${C_D}" "${C_N}" "$*"; }
abort() { printf '\n%sERROR:%s %s\n' "${C_R}" "${C_N}" "$*" >&2; exit 2; }


# ── Pre-flight + safety check ────────────────────────────────────────────────
phase "Pre-flight"

[[ "${EUID}" -eq 0 ]] || abort "must run as root (sudo)"
[[ -f "${ENV_FILE}" ]] || abort "${ENV_FILE} not found — run deploy.sh first"

# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

: "${DOMAIN:?DOMAIN missing from .env}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD missing from .env}"

if [[ "${DOMAIN}" != *.localhost && "${FORCE}" -ne 1 ]]; then
  printf '%sDOMAIN=%s does not end in .localhost.%s\n' "${C_R}" "${DOMAIN}" "${C_N}"
  printf 'Pass --force to run destructive tests against a non-lab deploy.\n' >&2
  exit 2
fi

info "stack root: ${STACK_ROOT}"
info "domain:     ${DOMAIN}"
pass "pre-flight ok"


# ── Optional teardown ────────────────────────────────────────────────────────
if (( TEARDOWN )); then
  phase "Teardown"
  (cd "${STACK_ROOT}" && docker compose down -v --remove-orphans)
  pass "stack torn down — exiting"
  exit 0
fi


# ── /etc/hosts for .localhost subdomains (lab-only) ──────────────────────────
SUBS=(cloud docs crm sign pdf time archive vault vpn status)
if [[ "${DOMAIN}" == *.localhost ]]; then
  phase "/etc/hosts entries for ${DOMAIN}"
  MISSING=()
  for s in "${SUBS[@]}"; do
    host="${s}.${DOMAIN}"
    if grep -qE "[[:space:]]${host}([[:space:]]|$)" /etc/hosts; then
      pass "${host}"
    else
      MISSING+=("${host}")
      fail "${host} missing from /etc/hosts"
    fi
  done
  if (( ${#MISSING[@]} > 0 )) && (( FIX_HOSTS )); then
    info "adding ${#MISSING[@]} entries to /etc/hosts (--fix-hosts)"
    for h in "${MISSING[@]}"; do
      printf '127.0.0.1 %s\n' "${h}" >> /etc/hosts
    done
    # Reset counters to re-test
    FAIL=$(( FAIL - ${#MISSING[@]} ))
    PASS=$(( PASS + ${#MISSING[@]} ))
    pass "/etc/hosts fixed"
  elif (( ${#MISSING[@]} > 0 )); then
    info "re-run with --fix-hosts to auto-add these entries"
  fi
fi


# ── Phase 1: Containers ──────────────────────────────────────────────────────
phase "Containers running"
EXPECTED=(
  stack-caddy stack-nextcloud-db stack-nextcloud-redis stack-nextcloud
  stack-onlyoffice stack-dolibarr-db stack-dolibarr stack-wg-easy
  stack-uptime-kuma stack-stirling-pdf stack-docuseal stack-kimai-db
  stack-kimai stack-paperless-db stack-paperless-redis stack-paperless
  stack-vaultwarden stack-restic stack-ofelia
)
for c in "${EXPECTED[@]}"; do
  state=$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo "absent")
  [[ "${state}" == "running" ]] && pass "${c}" || fail "${c} (${state})"
done


# ── Phase 2: TLS + HTTP reachability through Caddy ───────────────────────────
phase "TLS + HTTP via Caddy"
# Use -k because Caddy issues internal CA certs for .localhost — the VM
# doesn't trust them without importing Caddy's root.
for s in "${SUBS[@]}"; do
  url="https://${s}.${DOMAIN}/"
  # Follow up to 2 redirects; VPN-gated services return 403 (still a pass for
  # reachability — that's tested separately in Phase 6).
  code=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 -L --max-redirs 2 "${url}" || echo "000")
  case "${code}" in
    2??|3??|403) pass "${url} → HTTP ${code}" ;;
    000)         fail "${url} → no response" ;;
    *)           fail "${url} → unexpected HTTP ${code}" ;;
  esac
done


# ── Phase 3: DB connectivity (via stack-restic) ──────────────────────────────
phase "Database connectivity"
db_probe_pg() {
  local host="$1" user="$2" pass="$3" db="$4"
  if docker exec -e PGPASSWORD="${pass}" stack-restic \
       psql -h "${host}" -U "${user}" -d "${db}" -c 'SELECT 1' >/dev/null 2>&1; then
    pass "postgres ${user}@${host}/${db}"
  else
    fail "postgres ${user}@${host}/${db}"
  fi
}
db_probe_maria() {
  local host="$1" user="$2" pass="$3" db="$4"
  if docker exec stack-restic \
       mariadb -h "${host}" -u "${user}" -p"${pass}" -e 'SELECT 1' "${db}" >/dev/null 2>&1; then
    pass "mariadb ${user}@${host}/${db}"
  else
    fail "mariadb ${user}@${host}/${db}"
  fi
}
db_probe_pg    nextcloud-db  nextcloud  "${NC_DB_PASS}"        nextcloud
db_probe_pg    paperless-db  paperless  "${PAPERLESS_DB_PASS}" paperless
db_probe_maria dolibarr-db   dolibarr   "${DOLI_DB_PASS}"      dolibarr
db_probe_maria kimai-db      kimai      "${KIMAI_DB_PASS}"     kimai


# ── Phase 4: Backup round-trip ───────────────────────────────────────────────
phase "Backup round-trip"
info "triggering backup.sh (this may take 30–120s)..."
if docker exec stack-restic /scripts/backup.sh >/dev/null 2>&1; then
  pass "backup.sh exited 0"
else
  fail "backup.sh failed — see ${STACK_ROOT}/restic/logs/backup.log"
fi

SNAP_COUNT=$(docker exec stack-restic restic snapshots --json 2>/dev/null \
  | grep -o '"id":' | wc -l || echo 0)
if (( SNAP_COUNT >= 1 )); then
  pass "restic snapshots found: ${SNAP_COUNT}"
else
  fail "no restic snapshots found after backup"
fi


# ── Phase 5: Restore round-trip ──────────────────────────────────────────────
if (( SKIP_RESTORE )); then
  phase "Restore round-trip"
  skip "--skip-restore set"
else
  phase "Restore round-trip"
  # Plant a canary file in the Caddy config path (always backed up), run a
  # fresh backup, wipe the canary, then restore it.
  CANARY="${STACK_ROOT}/caddy/config/.test-canary-$$"
  CANARY_CONTENT="turnkey-stack test $(date -u +%s)"
  printf '%s' "${CANARY_CONTENT}" > "${CANARY}"
  info "canary planted: ${CANARY}"

  if docker exec stack-restic /scripts/backup.sh >/dev/null 2>&1; then
    pass "snapshot with canary created"
  else
    fail "canary-snapshot backup failed"
  fi

  rm -f "${CANARY}"
  info "canary deleted, restoring from latest snapshot..."

  RESTORE_DIR="$(mktemp -d)"
  if docker exec stack-restic restic restore latest \
       --target /tmp/restore-canary \
       --include "${CANARY}" >/dev/null 2>&1; then
    # The container's /tmp is ephemeral; copy the restored file out.
    docker cp "stack-restic:/tmp/restore-canary${CANARY}" "${RESTORE_DIR}/canary" 2>/dev/null || true
    if [[ -f "${RESTORE_DIR}/canary" ]] \
       && [[ "$(cat "${RESTORE_DIR}/canary")" == "${CANARY_CONTENT}" ]]; then
      pass "restored canary content matches original"
    else
      fail "restored canary missing or corrupt"
    fi
  else
    fail "restic restore command failed"
  fi
  rm -rf "${RESTORE_DIR}"
  docker exec stack-restic rm -rf /tmp/restore-canary >/dev/null 2>&1 || true
fi


# ── Phase 6: VPN gate returns 403 from untrusted source ──────────────────────
phase "VPN gate (expect 403 from lab host)"
# curl from the VM's localhost appears to Caddy as a docker-bridge address,
# which is NOT inside the default TRUSTED_CIDRS. VPN-only services must 403.
for s in crm vpn status; do
  url="https://${s}.${DOMAIN}/"
  code=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 "${url}" || echo "000")
  if [[ "${code}" == "403" ]]; then
    pass "${url} → 403 (gate working)"
  else
    fail "${url} → ${code} (expected 403; leak?)"
  fi
done


# ── Phase 7: Caddy config validation ─────────────────────────────────────────
phase "Caddy configuration"
if docker exec stack-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
     >/dev/null 2>&1; then
  pass "Caddyfile validates"
else
  fail "Caddyfile failed caddy validate"
fi


# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n%s════════════════════════════════════════%s\n' "${C_B}" "${C_N}"
printf '  Passed: %s%d%s    Failed: %s%d%s\n' \
  "${C_G}" "${PASS}" "${C_N}" "${C_R}" "${FAIL}" "${C_N}"
printf '%s════════════════════════════════════════%s\n\n' "${C_B}" "${C_N}"

if (( FAIL > 0 )); then
  printf '%sLab acceptance test: FAILED%s\n' "${C_R}${C_B}" "${C_N}"
  exit 1
fi
printf '%sLab acceptance test: PASSED%s\n' "${C_G}${C_B}" "${C_N}"
exit 0
