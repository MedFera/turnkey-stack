#!/usr/bin/env bash
# =============================================================================
# scripts/configure-apps.sh
# -----------------------------------------------------------------------------
# Turnkey Self-Hosted Business Server v1 — post-deploy application wiring.
#
# deploy.sh brings the stack UP. configure-apps.sh wires the apps TOGETHER:
# Nextcloud ↔ ONLYOFFICE (JWT), Nextcloud SMTP, Nextcloud polish (trusted
# domains, phone region, locale, cron), Paperless starter tags. Then prints
# the items that still require a browser (Uptime Kuma admin user, DocuSeal
# admin, Vaultwarden first user, wg-easy peers).
#
# Philosophy:
#   - Idempotent. Re-running never duplicates state.
#   - Safe-by-default. Every stage is skippable. --print-only never mutates.
#   - Reads /srv/stack/.env — never takes secrets on the command line.
#   - Dry-run supported, same pattern as deploy.sh.
#
# Pipeline:
#   1. parse_args              flags
#   2. init_logging            color + dry-run-aware run() helper
#   3. preflight_checks        docker, stack dir, .env, containers running
#   4. load_env                read values from /srv/stack/.env
#   5. wait_for_nextcloud      occ status → installed:true (or timeout)
#   6. configure_nextcloud_onlyoffice   app:install + JWT + doc server URL
#   7. configure_nextcloud_smtp         if SMTP_HOST is set
#   8. configure_nextcloud_polish       trusted domains, region, cron, previews
#   9. seed_paperless_tags     Invoice / Receipt / Contract / Tax
#  10. print_manual_steps      browser-only items
#  11. print_summary
#
# Usage:
#   sudo ./scripts/configure-apps.sh
#   sudo ./scripts/configure-apps.sh --print-only          # just show steps
#   sudo ./scripts/configure-apps.sh --dry-run             # show commands
#   sudo ./scripts/configure-apps.sh --skip-smtp --skip-paperless
#
# Options:
#   --stack-root <path>       Override /srv/stack (default: /srv/stack)
#   --skip-nextcloud          Skip all Nextcloud configuration
#   --skip-onlyoffice         Skip ONLYOFFICE connector wiring only
#   --skip-smtp               Skip SMTP config even if SMTP_HOST is set
#   --skip-paperless          Skip Paperless tag seeding
#   --print-only              Print manual steps + exit (no mutations)
#   --dry-run                 Print every mutation instead of running it
#   --nc-wait-seconds <n>     Seconds to wait for Nextcloud install (default 300)
#   --help                    Show help
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'


# ── Constants ────────────────────────────────────────────────────────────────
NC_CONTAINER="stack-nextcloud"
PAPERLESS_CONTAINER="stack-paperless"
INTERNAL_NET="stack-internal"

# Starter tag set for Paperless. Color is Paperless' hex-without-hash convention.
# Format: "Name|#RRGGBB"
PAPERLESS_TAGS=(
  "Invoice|#2e7d32"
  "Receipt|#1565c0"
  "Contract|#6a1b9a"
  "Tax|#c62828"
)


# ── Defaults (filled by parse_args) ──────────────────────────────────────────
STACK_ROOT="/srv/stack"
SKIP_NEXTCLOUD=0
SKIP_ONLYOFFICE=0
SKIP_SMTP=0
SKIP_PAPERLESS=0
PRINT_ONLY=0
DRY_RUN=0
NC_WAIT_SECONDS=300


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
skip() { printf '  %s~%s %s (skipped)\n' "${C_Y}" "${C_N}" "$*"; }
warn() { printf '  %s!%s %s\n'  "${C_Y}" "${C_N}" "$*" >&2; }
die()  { printf '\n  %s✗ %s%s\n\n' "${C_R}" "$*" "${C_N}" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    printf '  %s[dry-run]%s %s\n' "${C_Y}" "${C_N}" "$*"
    return 0
  fi
  "$@"
}

on_err() {
  local exit_code=$? line=$1 cmd=$2
  printf '\n%s✗ configure-apps.sh failed%s (line %s, exit %s):\n    %s\n\n' \
    "${C_R}${C_B}" "${C_N}" "${line}" "${exit_code}" "${cmd}" >&2
  exit "${exit_code}"
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR


# ── Stage 1: parse_args ──────────────────────────────────────────────────────
parse_args() {
  local arg
  while (( $# > 0 )); do
    arg="$1"
    case "${arg}" in
      --stack-root)        STACK_ROOT="${2:?}"; shift 2 ;;
      --skip-nextcloud)    SKIP_NEXTCLOUD=1; shift ;;
      --skip-onlyoffice)   SKIP_ONLYOFFICE=1; shift ;;
      --skip-smtp)         SKIP_SMTP=1; shift ;;
      --skip-paperless)    SKIP_PAPERLESS=1; shift ;;
      --print-only)        PRINT_ONLY=1; shift ;;
      --dry-run)           DRY_RUN=1; shift ;;
      --nc-wait-seconds)   NC_WAIT_SECONDS="${2:?}"; shift 2 ;;
      --help|-h)           usage; exit 0 ;;
      *)                   printf 'Unknown argument: %s\n\n' "${arg}" >&2; usage; exit 1 ;;
    esac
  done
}

usage() {
  sed -n '2,/^# =\+$/p' "$0" | sed 's/^# \{0,1\}//'
}


# ── Stage 2: preflight_checks ────────────────────────────────────────────────
preflight_checks() {
  log "Preflight"

  if [[ "${EUID}" -ne 0 ]]; then
    die "configure-apps.sh must run as root (try: sudo $0 ...)"
  fi
  ok "running as root"

  command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
  docker info >/dev/null 2>&1        || die "docker daemon not reachable"
  ok "docker daemon reachable"

  [[ -d "${STACK_ROOT}" ]]            || die "Stack root not found: ${STACK_ROOT}"
  [[ -r "${STACK_ROOT}/.env" ]]       || die "Cannot read ${STACK_ROOT}/.env (run deploy.sh first)"
  ok "stack dir: ${STACK_ROOT}"

  # Only enforce container presence for stages we're actually going to run.
  if (( ! PRINT_ONLY )); then
    if (( ! SKIP_NEXTCLOUD )); then
      container_running "${NC_CONTAINER}" \
        || die "${NC_CONTAINER} is not running — bring the stack up first (deploy.sh)"
      ok "${NC_CONTAINER} running"
    fi
    if (( ! SKIP_PAPERLESS )); then
      container_running "${PAPERLESS_CONTAINER}" \
        || die "${PAPERLESS_CONTAINER} is not running — bring the stack up first (deploy.sh)"
      ok "${PAPERLESS_CONTAINER} running"
    fi
  fi

  if (( DRY_RUN ));    then warn "DRY-RUN mode: no changes will be made"; fi
  if (( PRINT_ONLY )); then warn "PRINT-ONLY mode: will only print manual steps and exit"; fi
}

container_running() {
  local name="$1"
  [[ "$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)" == "running" ]]
}


# ── Stage 3: load_env ────────────────────────────────────────────────────────
# Read values from .env without `source` — that would execute any command on
# the RHS. Use a line-by-line parser that only recognizes KEY=VALUE form.
load_env() {
  log "Loading ${STACK_ROOT}/.env"

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Skip blanks and comments.
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    # Must be KEY=VALUE.
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Strip matched surrounding quotes.
    if [[ "${value}" =~ ^\"(.*)\"$ ]] || [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done < "${STACK_ROOT}/.env"

  : "${DOMAIN:?DOMAIN missing from .env}"
  : "${ONLYOFFICE_JWT:?ONLYOFFICE_JWT missing from .env}"
  : "${PAPERLESS_ADMIN_USER:?PAPERLESS_ADMIN_USER missing from .env}"
  : "${PAPERLESS_ADMIN_PASS:?PAPERLESS_ADMIN_PASS missing from .env}"

  ok "DOMAIN=${DOMAIN}"
  info "SMTP configured: $([[ -n "${SMTP_HOST:-}" ]] && echo yes || echo 'no (will skip SMTP stage)')"
}


# ── occ helper ───────────────────────────────────────────────────────────────
# All Nextcloud ops go through `occ`, which must run as the www-data user.
occ() {
  run docker exec -u www-data "${NC_CONTAINER}" php /var/www/html/occ "$@"
}

# occ with output capture (NOT run through run(), since dry-run has nothing
# meaningful to capture — callers handle the dry-run case themselves).
occ_capture() {
  docker exec -u www-data "${NC_CONTAINER}" php /var/www/html/occ "$@"
}


# ── Stage 4: wait_for_nextcloud ──────────────────────────────────────────────
# The image completes its initial `occ maintenance:install` inside entrypoint
# the first time it boots. Hitting `occ` before that returns an error. Poll.
wait_for_nextcloud() {
  if (( SKIP_NEXTCLOUD )); then skip "wait_for_nextcloud"; return 0; fi
  if (( DRY_RUN ));        then info "would wait up to ${NC_WAIT_SECONDS}s for Nextcloud install"; return 0; fi

  log "Waiting for Nextcloud install (timeout ${NC_WAIT_SECONDS}s)"
  local deadline=$(( $(date +%s) + NC_WAIT_SECONDS ))
  local out

  while (( $(date +%s) < deadline )); do
    if out="$(occ_capture status --output=json 2>/dev/null)"; then
      if grep -q '"installed":true' <<< "${out}"; then
        ok "Nextcloud reports installed:true"
        return 0
      fi
    fi
    info "still installing…"
    sleep 5
  done

  die "Timed out waiting for Nextcloud install. Check:  docker logs ${NC_CONTAINER}"
}


# ── Stage 5: configure_nextcloud_onlyoffice ──────────────────────────────────
configure_nextcloud_onlyoffice() {
  if (( SKIP_NEXTCLOUD )) || (( SKIP_ONLYOFFICE )); then
    skip "Nextcloud ↔ ONLYOFFICE wiring"
    return 0
  fi

  log "Wiring Nextcloud ↔ ONLYOFFICE (JWT)"

  # Idempotency: only install if missing. `app:list` is the authoritative source.
  local installed="no"
  if ! (( DRY_RUN )); then
    if occ_capture app:list --output=json 2>/dev/null \
       | grep -q '"onlyoffice":'; then
      installed="yes"
    fi
  fi

  if [[ "${installed}" == "yes" ]]; then
    info "onlyoffice connector already installed — reconfiguring only"
  else
    occ app:install onlyoffice
    ok "installed onlyoffice connector"
  fi

  occ app:enable onlyoffice
  ok "enabled onlyoffice connector"

  # Document server URL: browser-facing (users load the editor in an iframe
  # directly from docs.<domain>). Internal-only traffic from Nextcloud → DS
  # also uses this URL because both sit behind Caddy with JWT anyway.
  occ config:app:set onlyoffice DocumentServerUrl    --value="https://docs.${DOMAIN}/"
  occ config:app:set onlyoffice jwt_secret           --value="${ONLYOFFICE_JWT}"
  occ config:app:set onlyoffice jwt_header           --value="AuthorizationJwt"
  # Let Nextcloud hit the DS through Caddy on the same LAN — no cert-verify
  # dance because Caddy uses a valid cert (Let's Encrypt or internal CA
  # bundled into each container's trust store via Nextcloud's built-in
  # "add trusted cert" is handled at the reverse-proxy layer).
  ok "set DocumentServerUrl, jwt_secret, jwt_header"
}


# ── Stage 6: configure_nextcloud_smtp ────────────────────────────────────────
configure_nextcloud_smtp() {
  if (( SKIP_NEXTCLOUD )) || (( SKIP_SMTP )); then
    skip "Nextcloud SMTP"
    return 0
  fi
  if [[ -z "${SMTP_HOST:-}" ]]; then
    skip "Nextcloud SMTP (SMTP_HOST not set in .env)"
    return 0
  fi

  log "Configuring Nextcloud SMTP"

  local smtp_port="${SMTP_PORT:-587}"
  local smtp_secure="tls"
  [[ "${smtp_port}" == "465" ]] && smtp_secure="ssl"

  occ config:system:set mail_smtpmode      --value="smtp"
  occ config:system:set mail_smtphost      --value="${SMTP_HOST}"
  occ config:system:set mail_smtpport      --value="${smtp_port}"
  occ config:system:set mail_smtpsecure    --value="${smtp_secure}"
  occ config:system:set mail_smtpauthtype  --value="LOGIN"

  if [[ -n "${SMTP_USER:-}" ]]; then
    occ config:system:set mail_smtpauth   --value="1"          --type=boolean
    occ config:system:set mail_smtpname   --value="${SMTP_USER}"
    occ config:system:set mail_smtppassword --value="${SMTP_PASS:-}"
  else
    occ config:system:set mail_smtpauth   --value="0"          --type=boolean
  fi

  # From: parse "Name <addr@example.com>" into domain + local part if possible;
  # otherwise fall back to ADMIN_EMAIL.
  local from="${SMTP_FROM:-${ADMIN_EMAIL:-admin@${DOMAIN}}}"
  local from_addr="${from##*<}"; from_addr="${from_addr%>}"
  local local_part="${from_addr%@*}"
  local domain_part="${from_addr#*@}"
  occ config:system:set mail_from_address --value="${local_part}"
  occ config:system:set mail_domain       --value="${domain_part}"
  ok "SMTP configured via ${SMTP_HOST}:${smtp_port} (${smtp_secure}) from ${from_addr}"
}


# ── Stage 7: configure_nextcloud_polish ──────────────────────────────────────
# Items that don't belong to a specific app but make Nextcloud behave
# correctly on first boot.
configure_nextcloud_polish() {
  if (( SKIP_NEXTCLOUD )); then skip "Nextcloud polish"; return 0; fi

  log "Nextcloud polish"

  # Trusted domains: the compose env already seeds trusted_domains[0] =
  # cloud.DOMAIN, but re-assert it so a re-run after DOMAIN change repairs.
  occ config:system:set trusted_domains 0 --value="cloud.${DOMAIN}"
  ok "trusted_domains[0] = cloud.${DOMAIN}"

  # Overwrite host/protocol: harmless to re-set; keeps URL generation correct
  # when behind Caddy.
  occ config:system:set overwrite.cli.url --value="https://cloud.${DOMAIN}"
  occ config:system:set overwriteprotocol --value="https"
  occ config:system:set overwritehost     --value="cloud.${DOMAIN}"
  ok "overwrite.cli.url / overwriteprotocol / overwritehost"

  # Default phone region — required for the user-profile phone fields to
  # render validation correctly. Best-effort guess from TIMEZONE.
  local region="US"
  case "${TIMEZONE:-}" in
    Europe/London|Europe/Dublin)                      region="GB" ;;
    Europe/Berlin|Europe/Vienna|Europe/Zurich)        region="DE" ;;
    Europe/Paris)                                     region="FR" ;;
    Europe/Madrid)                                    region="ES" ;;
    Europe/Rome)                                      region="IT" ;;
    Europe/Amsterdam)                                 region="NL" ;;
    Australia/*)                                      region="AU" ;;
    Asia/Tokyo)                                       region="JP" ;;
    Asia/Kolkata|Asia/Calcutta)                       region="IN" ;;
    America/Toronto|America/Vancouver|America/Montreal) region="CA" ;;
    America/Mexico_City)                              region="MX" ;;
    America/Sao_Paulo)                                region="BR" ;;
  esac
  occ config:system:set default_phone_region --value="${region}"
  ok "default_phone_region = ${region}"

  # Background jobs: cron mode is strictly better than AJAX. The system cron
  # on the Ubuntu VM is NOT invoking nextcloud's cron.php here — the compose
  # file's stack-ofelia handles scheduling elsewhere, BUT Nextcloud's
  # internal cron can also be driven by hitting `php cron.php` from Ofelia.
  # For v1 we just set the mode; Ofelia cron trigger is v1.1.
  occ background:cron
  ok "background jobs = cron"

  # Preview providers: enables thumbnails for images/PDFs/Office docs.
  occ config:system:set enabledPreviewProviders 0 --value='OC\Preview\Image'
  occ config:system:set enabledPreviewProviders 1 --value='OC\Preview\MarkDown'
  occ config:system:set enabledPreviewProviders 2 --value='OC\Preview\MP3'
  occ config:system:set enabledPreviewProviders 3 --value='OC\Preview\TXT'
  occ config:system:set enabledPreviewProviders 4 --value='OC\Preview\PDF'
  occ config:system:set enabledPreviewProviders 5 --value='OC\Preview\OpenDocument'
  ok "preview providers enabled"

  # Make sure index is healthy. Cheap to re-run.
  occ db:add-missing-indices
  ok "db:add-missing-indices"
}


# ── Stage 8: seed_paperless_tags ─────────────────────────────────────────────
# Paperless exposes a REST API at /api/tags/. Hitting it from outside the
# container would go through Caddy; easier and auth-cheaper to call it on the
# internal docker network. We use an ephemeral curl container attached to
# stack-internal and talking to `paperless:8000` by service name.
seed_paperless_tags() {
  if (( SKIP_PAPERLESS )); then skip "Paperless tags"; return 0; fi

  log "Seeding Paperless starter tags"

  local user="${PAPERLESS_ADMIN_USER}"
  local pass="${PAPERLESS_ADMIN_PASS}"
  local base="http://paperless:8000/api/tags/"

  # Fetch existing tag names once so we can skip duplicates.
  local existing=""
  if ! (( DRY_RUN )); then
    existing="$(
      docker run --rm --network "${INTERNAL_NET}" curlimages/curl:8.6.0 \
        -sS -u "${user}:${pass}" \
        -H 'Accept: application/json' \
        "${base}?page_size=500" 2>/dev/null \
      | tr ',' '\n' | grep -oE '"name":"[^"]+"' || true
    )"
  fi

  local pair name color
  for pair in "${PAPERLESS_TAGS[@]}"; do
    name="${pair%%|*}"
    color="${pair#*|}"

    if grep -Fq "\"name\":\"${name}\"" <<< "${existing}"; then
      skip "tag ${name} (already exists)"
      continue
    fi

    # --data-raw + --json ensures correct Content-Type. Use a heredoc-safe
    # inline JSON. `is_inbox_tag=false` and `matching_algorithm=0` are
    # Paperless defaults for a plain tag.
    local body
    body="$(printf '{"name":"%s","color":"%s","is_inbox_tag":false,"matching_algorithm":0}' \
              "${name}" "${color}")"

    if (( DRY_RUN )); then
      info "[dry-run] POST ${base}  name=${name} color=${color}"
      continue
    fi

    local http_code
    http_code="$(
      docker run --rm --network "${INTERNAL_NET}" curlimages/curl:8.6.0 \
        -sS -o /dev/null -w '%{http_code}' \
        -u "${user}:${pass}" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -X POST --data-raw "${body}" \
        "${base}" || true
    )"

    case "${http_code}" in
      201|200) ok "created tag ${name} (${color})" ;;
      400)     warn "tag ${name}: 400 — likely already exists under different match" ;;
      401|403) die "tag ${name}: auth failed (${http_code}) — PAPERLESS_ADMIN_USER/PASS mismatch" ;;
      *)       warn "tag ${name}: unexpected HTTP ${http_code}" ;;
    esac
  done
}


# ── Stage 9: print_manual_steps ──────────────────────────────────────────────
# Things we deliberately don't automate because they either (a) require a
# browser/UI or (b) produce secrets the operator should see personally.
print_manual_steps() {
  local d="${DOMAIN:-<your-domain>}"
  cat <<EOF

${C_B}═══ Manual steps that require a browser ═══${C_N}

  ${C_B}1. Uptime Kuma${C_N}   →  https://status.${d}/   (VPN-only)
     First visit creates the admin user. Pick a strong password; store in
     Vaultwarden. Then add monitors for each service (v1.1 will seed these
     via API on first deploy).

  ${C_B}2. DocuSeal${C_N}      →  https://sign.${d}/
     First visit creates the owner account. Configure company name, logo,
     and — if you use SMTP — test an envelope send to confirm delivery.

  ${C_B}3. Vaultwarden${C_N}   →  https://vault.${d}/
     First user who registers becomes the admin. Register your admin
     account NOW, then disable signups via /admin (token = VAULTWARDEN_ADMIN
     from .env — do not share).

  ${C_B}4. wg-easy${C_N}       →  https://vpn.${d}/   (VPN-only, bootstrap via LAN)
     Log in with WG_PASSWORD from .env. Create a peer per user/device,
     download .conf or scan QR from the WireGuard mobile/desktop app.

  ${C_B}5. Dolibarr${C_N}      →  https://crm.${d}/   (VPN-only)
     Log in as admin / DOLI_ADMIN_PASS. Run the setup wizard, pick modules
     you'll actually use (less is more), and set your company info.

  ${C_B}6. Kimai${C_N}         →  https://time.${d}/
     Log in with KIMAI_ADMIN_EMAIL / KIMAI_ADMIN_PASS. Create customers +
     projects before inviting users.

  ${C_B}7. Nextcloud${C_N}     →  https://cloud.${d}/
     Log in as ${NC_ADMIN_USER:-admin}. Verify the ONLYOFFICE connector by
     opening Settings → Administration → ONLYOFFICE — the server check
     should be green. Create user accounts (use real email addresses so the
     future Keycloak migration is painless).

  ${C_B}8. Paperless-ngx${C_N} →  https://archive.${d}/
     Log in as ${PAPERLESS_ADMIN_USER:-admin}. The starter tags (Invoice,
     Receipt, Contract, Tax) are already seeded — wire them to mail rules
     or auto-match patterns as needed.

EOF
}


# ── Stage 10: print_summary ──────────────────────────────────────────────────
print_summary() {
  cat <<EOF

${C_G}${C_B}✓ configure-apps.sh finished${C_N}

  Log for this run is stdout only — if anything surprised you, re-run with
  --dry-run to see every occ/curl command that would be issued.

  Next:  complete the manual steps above, then run:

      sudo scripts/health-check.sh
      sudo scripts/test-deploy.sh --domain ${DOMAIN:-<domain>} --ip <ip>

EOF
}


# ── main ─────────────────────────────────────────────────────────────────────
main() {
  init_logging
  parse_args "$@"

  if (( PRINT_ONLY )); then
    # Pull DOMAIN from .env if we can so the URLs are real; tolerate a
    # missing .env in --print-only mode since the operator may just want
    # the checklist.
    [[ -r "${STACK_ROOT}/.env" ]] && load_env || true
    print_manual_steps
    exit 0
  fi

  preflight_checks
  load_env
  wait_for_nextcloud
  configure_nextcloud_onlyoffice
  configure_nextcloud_smtp
  configure_nextcloud_polish
  seed_paperless_tags
  print_manual_steps
  print_summary
}

main "$@"
