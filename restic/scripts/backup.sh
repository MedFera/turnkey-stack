#!/usr/bin/env bash
# =============================================================================
# restic/scripts/backup.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1 — nightly backup job.
#
# Runs INSIDE the stack-restic container. Ofelia triggers it on
# BACKUP_SCHEDULE (see docker-compose.yml labels). Can also be run manually:
#
#   docker exec stack-restic /scripts/backup.sh
#
# Flow:
#   1. Dump every PostgreSQL + MariaDB via network clients (pg_dump, mariadb-dump)
#      into /tmp/dumps/. (The stack-restic container is on the internal Docker
#      network, so it can reach nextcloud-db, dolibarr-db, kimai-db, paperless-db
#      by service name. No docker.sock required.)
#   2. restic backup /srv/stack + /tmp/dumps, with excludes for live DB data
#      dirs (we have dumps), logs, and the backup tooling itself.
#   3. Apply retention: keep 30 daily / 12 monthly / 3 yearly snapshots.
#   4. Run a metadata-only integrity check (`restic check`).
#   5. Log every step timestamped to /var/log/restic/backup.log.
#   6. Exit non-zero on any failure — Ofelia records the status.
# =============================================================================

set -euo pipefail


# ── Config ───────────────────────────────────────────────────────────────────
SOURCE_ROOT="${SOURCE_ROOT:-/srv/stack}"
STAGING_DIR="${STAGING_DIR:-/tmp/dumps}"
LOG_DIR="${LOG_DIR:-/var/log/restic}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/backup.log}"

# Retention policy
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

# Runtime bookkeeping
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
START_EPOCH="$(date +%s)"


# ── Logging ──────────────────────────────────────────────────────────────────
mkdir -p "${LOG_DIR}"
log() {
  printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${RUN_ID}" "$*" \
    | tee -a "${LOG_FILE}"
}

fail() {
  local rc=$?
  log "ERROR: backup failed (line ${BASH_LINENO[0]}, exit ${rc})"
  rm -rf "${STAGING_DIR}" || true
  exit "${rc}"
}
trap fail ERR


# ── Pre-flight ───────────────────────────────────────────────────────────────
log "=== Backup run ${RUN_ID} started ==="

for tool in restic pg_dump mariadb-dump gzip; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log "Required tool '${tool}' not in PATH — aborting"
    exit 2
  fi
done

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is not set}"

# Ensure staging dir is clean
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
chmod 700 "${STAGING_DIR}"


# ── Database dumps ───────────────────────────────────────────────────────────
# Each dump is atomic and transactionally consistent. Compressed at source
# (pg_dump -Fc or mariadb-dump | gzip) so the subsequent restic pass has
# nothing useful to deduplicate on anyway.

pg_dump_one() {
  # Usage: pg_dump_one <host> <db> <user> <password>
  local host="$1" db="$2" user="$3" pass="$4"
  local out="${STAGING_DIR}/${host}_${db}.dump"
  log "pg_dump  ${db} @ ${host} → ${out}"
  PGPASSWORD="${pass}" pg_dump \
    --host="${host}" \
    --port=5432 \
    --username="${user}" \
    --dbname="${db}" \
    --format=custom \
    --compress=6 \
    --file="${out}"
}

maria_dump_one() {
  # Usage: maria_dump_one <host> <db> <user> <password>
  local host="$1" db="$2" user="$3" pass="$4"
  local out="${STAGING_DIR}/${host}_${db}.sql.gz"
  log "mariadb-dump ${db} @ ${host} → ${out}"
  mariadb-dump \
    --host="${host}" \
    --port=3306 \
    --user="${user}" \
    --password="${pass}" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    --routines \
    --triggers \
    --events \
    --default-character-set=utf8mb4 \
    "${db}" \
    | gzip -6 > "${out}"
}

# Credentials come from the container environment (set in docker-compose.yml).
pg_dump_one    nextcloud-db  nextcloud  nextcloud  "${NC_DB_PASS}"
pg_dump_one    paperless-db  paperless  paperless  "${PAPERLESS_DB_PASS}"
maria_dump_one dolibarr-db   dolibarr   dolibarr   "${DOLI_DB_PASS}"
maria_dump_one kimai-db      kimai      kimai      "${KIMAI_DB_PASS}"

DUMP_SIZE="$(du -sh "${STAGING_DIR}" | awk '{print $1}')"
log "DB dumps complete — staging size: ${DUMP_SIZE}"


# ── Restic repository init (idempotent) ──────────────────────────────────────
if ! restic cat config >/dev/null 2>&1; then
  log "Restic repo not found at ${RESTIC_REPOSITORY} — initializing"
  restic init
fi


# ── Backup run ───────────────────────────────────────────────────────────────
# Excludes:
#   */db            — raw DB data dirs (we have consistent dumps instead)
#   */logs          — app logs (noisy, rotate via Docker json-file)
#   /srv/stack/restic — don't back up the backup tooling / log files
#   *.tmp, *.part   — in-flight files
#
# Note: caddy/data IS backed up (contains ACME account + issued certs).
# Note: wireguard/config IS backed up (peer keys + QR-code configs).
log "Starting restic backup..."
restic backup \
  --verbose=1 \
  --tag "nightly" \
  --tag "run=${RUN_ID}" \
  --host "stack-restic" \
  --exclude "${SOURCE_ROOT}/*/db" \
  --exclude "${SOURCE_ROOT}/*/logs" \
  --exclude "${SOURCE_ROOT}/stirling-pdf/logs" \
  --exclude "${SOURCE_ROOT}/onlyoffice/logs" \
  --exclude "${SOURCE_ROOT}/restic" \
  --exclude "*.tmp" \
  --exclude "*.part" \
  "${SOURCE_ROOT}" \
  "${STAGING_DIR}" \
  2>&1 | tee -a "${LOG_FILE}"


# ── Retention ────────────────────────────────────────────────────────────────
log "Applying retention: keep ${KEEP_DAILY}d / ${KEEP_MONTHLY}m / ${KEEP_YEARLY}y"
restic forget \
  --tag "nightly" \
  --keep-daily "${KEEP_DAILY}" \
  --keep-monthly "${KEEP_MONTHLY}" \
  --keep-yearly "${KEEP_YEARLY}" \
  --prune \
  2>&1 | tee -a "${LOG_FILE}"


# ── Integrity check (metadata only — fast) ───────────────────────────────────
# Full --read-data check is expensive; schedule it separately (weekly) if
# needed. The metadata check catches repo corruption and broken pack refs.
log "Running restic check (metadata)..."
restic check 2>&1 | tee -a "${LOG_FILE}"


# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "${STAGING_DIR}"

DURATION=$(( $(date +%s) - START_EPOCH ))
log "=== Backup run ${RUN_ID} completed successfully in ${DURATION}s ==="
exit 0
