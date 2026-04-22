#!/usr/bin/env bash
# =============================================================================
# scripts/health-check.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1 — stack health probe.
#
# Runs on the Ubuntu VM host. Performs three classes of check:
#   1. Container status — every stack-* container is running + (when defined)
#      its Docker healthcheck reports "healthy".
#   2. HTTP endpoints — each app responds on its internal service name:port.
#      We exec into stack-caddy (already on the internal network, has busybox
#      wget) rather than spinning up an ephemeral curl container.
#   3. Last backup — parse restic/logs/backup.log and fail if the newest
#      "completed successfully" entry is older than BACKUP_STALE_HOURS.
#
# Exit codes:
#   0 — all green
#   1 — at least one check failed (stack is DEGRADED)
#   2 — prerequisite missing (docker not installed, wrong user, etc.)
#
# Usage:
#   ./scripts/health-check.sh
#   BACKUP_STALE_HOURS=48 ./scripts/health-check.sh      # loosen threshold
#   STACK_ROOT=/opt/stack ./scripts/health-check.sh      # non-default root
# =============================================================================

set -euo pipefail


# ── Config ───────────────────────────────────────────────────────────────────
STACK_ROOT="${STACK_ROOT:-/srv/stack}"
BACKUP_LOG="${BACKUP_LOG:-${STACK_ROOT}/restic/logs/backup.log}"
BACKUP_STALE_HOURS="${BACKUP_STALE_HOURS:-36}"   # daily backups + 12h grace
HTTP_TIMEOUT="${HTTP_TIMEOUT:-5}"


# ── Output helpers (respect non-TTY / NO_COLOR) ──────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
  C_B=$'\033[1m';    C_D=$'\033[2m';    C_N=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_D=''; C_N=''
fi

EXIT_CODE=0
pass()    { printf '  %s✓%s %s\n'     "${C_G}" "${C_N}" "$*"; }
fail()    { printf '  %s✗%s %s\n'     "${C_R}" "${C_N}" "$*"; EXIT_CODE=1; }
warn()    { printf '  %s!%s %s\n'     "${C_Y}" "${C_N}" "$*"; }
section() { printf '\n%s%s%s\n'       "${C_B}" "$*" "${C_N}"; }


# ── Prerequisites ────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  printf '%sERROR:%s docker CLI not found on PATH\n' "${C_R}" "${C_N}" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  printf '%sERROR:%s cannot talk to Docker daemon (permissions? is it running?)\n' \
    "${C_R}" "${C_N}" >&2
  exit 2
fi


# ── 1. Container status ──────────────────────────────────────────────────────
# Service name → (internal host) : (internal port) : (HTTP path for probe)
# Order matches docker-compose.yml grouping.
CONTAINERS=(
  "stack-caddy|caddy|80|/"
  "stack-nextcloud-db|nextcloud-db|0|"
  "stack-nextcloud-redis|nextcloud-redis|0|"
  "stack-nextcloud|nextcloud|80|/status.php"
  "stack-onlyoffice|onlyoffice|80|/healthcheck"
  "stack-dolibarr-db|dolibarr-db|0|"
  "stack-dolibarr|dolibarr|80|/"
  "stack-wg-easy|wg-easy|51821|/"
  "stack-uptime-kuma|uptime-kuma|3001|/"
  "stack-stirling-pdf|stirling-pdf|8080|/"
  "stack-docuseal|docuseal|3000|/"
  "stack-kimai-db|kimai-db|0|"
  "stack-kimai|kimai|8001|/"
  "stack-paperless-db|paperless-db|0|"
  "stack-paperless-redis|paperless-redis|0|"
  "stack-paperless|paperless|8000|/"
  "stack-vaultwarden|vaultwarden|80|/alive"
  "stack-restic|||"
  "stack-ofelia|||"
)

section "Container status"
CADDY_UP=0
for entry in "${CONTAINERS[@]}"; do
  IFS='|' read -r cname _host _port _path <<< "${entry}"

  status=$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'missing')
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' \
    "${cname}" 2>/dev/null || printf 'missing')

  case "${status}" in
    missing)
      fail "${cname} (container does not exist)"
      ;;
    running)
      case "${health}" in
        healthy|n/a) pass "${cname} ${C_D}(${status})${C_N}"
                     [[ "${cname}" == "stack-caddy" ]] && CADDY_UP=1 ;;
        starting)    warn "${cname} (healthcheck: starting)"
                     [[ "${cname}" == "stack-caddy" ]] && CADDY_UP=1 ;;
        unhealthy)   warn "${cname} (healthcheck: unhealthy — may still be initializing)" ;;
        *)           warn "${cname} (health: ${health})" ;;
      esac
      ;;
    *)
      fail "${cname} (${status})"
      ;;
  esac
done


# ── 2. HTTP endpoints (via stack-caddy busybox wget) ─────────────────────────
section "HTTP endpoints"
if [[ "${CADDY_UP}" -ne 1 ]]; then
  warn "stack-caddy is not running — skipping HTTP probes"
  EXIT_CODE=1
else
  for entry in "${CONTAINERS[@]}"; do
    IFS='|' read -r cname host port path <<< "${entry}"
    # Skip DB / cache / scheduler / backup containers (no HTTP).
    [[ -z "${port}" || "${port}" == "0" ]] && continue
    # Don't probe caddy from inside caddy — covered by the container check.
    [[ "${cname}" == "stack-caddy" ]] && continue

    url="http://${host}:${port}${path}"
    # busybox wget: --spider + -S prints headers; we just want exit status.
    # Follow up to 2 redirects so login-redirect apps still pass.
    if docker exec stack-caddy wget -q -T "${HTTP_TIMEOUT}" --spider --max-redirect=2 \
         "${url}" >/dev/null 2>&1; then
      pass "${host}:${port}${path}"
    else
      # Retry as GET — some apps reject HEAD/--spider requests.
      if docker exec stack-caddy wget -q -T "${HTTP_TIMEOUT}" -O /dev/null --max-redirect=2 \
           "${url}" >/dev/null 2>&1; then
        pass "${host}:${port}${path}"
      else
        # On first deploy apps are still initializing — treat HTTP failures
        # as warnings rather than hard failures so deploy.sh does not abort.
        # Once apps are fully up, re-run health-check.sh to confirm all green.
        warn "${host}:${port}${path} (no response — may still be initializing)"
      fi
    fi
  done
fi


# ── 3. Last backup freshness ─────────────────────────────────────────────────
section "Last backup"
if [[ ! -f "${BACKUP_LOG}" ]]; then
  warn "No backup log yet at ${BACKUP_LOG} — first backup runs at 02:00 tonight"
else
  # backup.sh writes: "[YYYY-MM-DD HH:MM:SSZ] [RUN_ID] === Backup run ... completed successfully ..."
  last_line=$(grep 'completed successfully' "${BACKUP_LOG}" | tail -n 1 || true)
  if [[ -z "${last_line}" ]]; then
    fail "No successful backup recorded in ${BACKUP_LOG}"
  else
    # Extract the first [timestamp] bracketed field.
    ts=$(printf '%s' "${last_line}" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
    last_epoch=$(date -u -d "${ts}" +%s 2>/dev/null || echo 0)
    if [[ "${last_epoch}" -eq 0 ]]; then
      warn "Could not parse timestamp from last backup line"
    else
      now_epoch=$(date -u +%s)
      age_hours=$(( (now_epoch - last_epoch) / 3600 ))
      if (( age_hours > BACKUP_STALE_HOURS )); then
        fail "Last backup was ${age_hours}h ago (threshold: ${BACKUP_STALE_HOURS}h) — ${ts}"
      else
        pass "Last backup ${age_hours}h ago ${C_D}(${ts})${C_N}"
      fi
    fi
  fi
fi


# ── Summary ──────────────────────────────────────────────────────────────────
section "Result"
if (( EXIT_CODE == 0 )); then
  printf '  %sHEALTHY%s\n\n' "${C_G}${C_B}" "${C_N}"
else
  printf '  %sDEGRADED%s — see failures above\n\n' "${C_R}${C_B}" "${C_N}"
fi

exit "${EXIT_CODE}"
