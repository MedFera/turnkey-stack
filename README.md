# Turnkey Self-Hosted Business Server v1

A production-grade, repeatable Docker stack for small business clients (6–20
users). One identical deployment for every client — only `.env` values differ.

All services sit behind a single Caddy reverse proxy with auto-TLS. Remote
access is VPN-first via WireGuard. Backups run before the stack is considered
live. Windows clients interact with the server via browser and WireGuard only
— no SMB, no Active Directory, no domain joining.

---

## What gets deployed

| Subdomain | Service | Purpose | Access |
|---|---|---|---|
| `cloud.DOMAIN` | Nextcloud + PostgreSQL + Redis | Files, sync, shared folders | Public |
| `docs.DOMAIN` | ONLYOFFICE | Browser-based doc editor (JWT-linked to Nextcloud) | Public |
| `crm.DOMAIN` | Dolibarr + MariaDB | CRM, invoicing, contacts | **VPN only** |
| `sign.DOMAIN` | DocuSeal | Document signing | Public |
| `pdf.DOMAIN` | Stirling-PDF | Browser PDF editor | Public |
| `time.DOMAIN` | Kimai + MariaDB | Time tracking | Public |
| `archive.DOMAIN` | Paperless-ngx + PostgreSQL | Document archive + OCR | Public |
| `vault.DOMAIN` | Vaultwarden | Password manager | Public |
| `vpn.DOMAIN` | wg-easy | WireGuard admin UI | **VPN only** |
| `status.DOMAIN` | Uptime Kuma | Service monitoring | **VPN only** |

Also running (no subdomain): Restic backup engine, Ofelia scheduler.

---

## Architecture

```
  Client LAN / Internet
          │
          ▼
   ┌─────────────┐
   │   Caddy     │  (only container with published ports: 80, 443, 443/udp)
   └─────────────┘
          │  internal Docker network
          ▼
   ┌──────────────────────────────────────────┐
   │  Nextcloud · ONLYOFFICE · Dolibarr · …   │  apps
   │  Paperless · Kimai · Vaultwarden · …     │
   ├──────────────────────────────────────────┤
   │  Postgres · MariaDB · Redis              │  databases (no host ports)
   ├──────────────────────────────────────────┤
   │  Restic · Ofelia                         │  backup + scheduler
   └──────────────────────────────────────────┘

  wg-easy publishes UDP/51820 for the WireGuard tunnel (separate from 443).
```

Infrastructure layers:

1. **Proxmox VE** on bare metal (Mini PC or small rack server).
2. **Ubuntu Server 24.04 LTS VM** — 8 vCPU, 28 GB RAM, 1.8 TB disk.
3. **Docker + Docker Compose v2** — this repo.

---

## Requirements

**Hardware (recommended)**

- Ryzen 5 / i5 class CPU, 32 GB RAM
- 2× 2 TB SSD in ZFS mirror (Proxmox)
- Gigabit LAN

**Inside the Ubuntu VM**

- Ubuntu Server 24.04 LTS, fully updated
- `docker.io`, `docker-compose-v2`, `docker-buildx-plugin` (compose v2 needs buildx)
- `rsync`, `openssl`, `git`, `awk`, `sed`, `grep` (GNU coreutils usually present)
- Root / sudo access

`deploy.sh` validates every one of these at preflight and fails with an
actionable message (including the `apt-get install` command) if any are
missing. No silent failures later in the pipeline.

**Network**

- Static LAN IP for the VM (e.g. `192.168.1.10`)
- Wildcard DNS: `*.DOMAIN` → server IP (production only)
- Router port-forwards: `TCP/443`, `UDP/51820` → VM

---

## Quick start — lab deployment

Use this to test the stack on a throwaway VM before deploying to a client.

**Pick the right TLD for your lab:**

| Scenario | Domain to use | Why |
|---|---|---|
| Everything from the VM itself (`curl localhost`) | `company.localhost` + `--ip 127.0.0.1` | `.localhost` is RFC 6761 loopback-only |
| Other LAN machines need to reach the stack | `company.test` + `--ip 192.168.1.10` | `.test` is RFC 2606 reserved — fine for LAN, won't leak to the internet |
| Matches your existing internal naming | `company.internal` / `.lab` | Same as `.test` — all lab TLDs are unresolvable in public DNS |

**Do not** pair `.localhost` with a LAN IP. Other machines on the LAN will
try to resolve `*.company.localhost` to their own loopback and fail silently.
`deploy.sh` rejects this pairing unless you pass `--force`.

```bash
# 1. Install prerequisites on the Ubuntu VM
sudo apt update
sudo apt install -y docker.io docker-compose-v2 docker-buildx-plugin \
                    rsync openssl git

# 2. Clone / copy the repo
git clone <your-repo> turnkey-stack
cd turnkey-stack

# 3. Deploy against a lab domain (Caddy auto-issues internal certs)
sudo ./scripts/deploy.sh \
  --domain company.test \
  --ip 192.168.1.10

# 4. On each client machine that should reach the stack, add to /etc/hosts
#    (or the Windows equivalent):
#       192.168.1.10  cloud.company.test
#       192.168.1.10  docs.company.test
#       ...etc for all 10 subdomains.
#    Or run the acceptance test on the VM itself:
sudo ./scripts/test-deploy.sh --fix-hosts
```

The `--fix-hosts` flag adds `127.0.0.1 <sub>.company.<tld>` entries to the
VM's `/etc/hosts` so the smoke test can run without a separate resolver.
Browsers will flag the internal certs as untrusted — accept the warning for
lab use, or import Caddy's root from
`/srv/stack/caddy/data/caddy/pki/authorities/local/root.crt` into the OS
trust store.

---

## Quick start — production deployment

```bash
# 1. DNS: create a wildcard A record pointing at your server IP:
#        *.company.com  →  203.0.113.10
#
# 2. Firewall: forward from the router to the VM:
#        TCP 80, 443     (Caddy + Let's Encrypt HTTP-01 challenge)
#        UDP 51820       (WireGuard tunnel)
#
# 3. SMTP: pick a relay (Mailgun / SendGrid / Postmark) — you'll fill
#          SMTP_* values after deploy.
#
# 4. Deploy (from inside the VM):
sudo ./scripts/deploy.sh \
  --domain company.com \
  --ip 192.168.1.10 \
  --admin-email support@yourmsp.com \
  --client-name "Acme Corp" \
  --timezone America/New_York
```

Caddy will automatically request Let's Encrypt certs for every subdomain on
first request. No additional TLS configuration needed.

---

## Configuration

All per-client configuration lives in **`/srv/stack/.env`** (chmod 600,
owned by `stackuser:stackuser`). Never edit any other file for client-specific
values.

The deploy script auto-generates every secret. You only need to manually set
optional values **after** deploy:

```bash
sudo -u stackuser nano /srv/stack/.env
```

Fields most commonly edited post-deploy:

| Variable | When to set |
|---|---|
| `SMTP_HOST`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` | To enable outbound email (password resets, invoice delivery) |
| `RESTIC_REPOSITORY` | Switch from local (`/srv/backups`) to S3/B2/SFTP |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | For S3/B2 backup repos |
| `TRUSTED_CIDRS` | If your LAN isn't in `192.168.0.0/16` |

After editing `.env`, restart affected services:

```bash
cd /srv/stack && sudo docker compose up -d
```

See [`.env.template`](.env.template) for every variable with inline comments.

---

## First-run manual tasks

`deploy.sh` brings the stack UP. **`configure-apps.sh` wires it together** —
run it once, immediately after deploy. Everything below that the script can
automate, it does; the rest are browser-only and documented as manual steps.

### 0. Run the app-wiring script (do this first)

```bash
sudo /srv/stack/scripts/configure-apps.sh
```

What it does:

- Waits for Nextcloud's first-run install to finish (`occ status` polling).
- Installs + enables the ONLYOFFICE connector, sets the document server URL,
  JWT secret, and JWT header — no more clicking around in Nextcloud's app
  store.
- Configures Nextcloud SMTP from the `SMTP_*` values in `.env` (skipped if
  `SMTP_HOST` is blank).
- Applies Nextcloud polish: trusted domains, overwrite URLs, default phone
  region (best-effort from `TIMEZONE`), cron mode, preview providers,
  missing DB indices.
- Seeds Paperless starter tags: **Invoice**, **Receipt**, **Contract**,
  **Tax** (POST to the internal REST API; skipped if they already exist).
- Prints the short checklist of browser-only steps that follow below.

Useful flags:

| Flag | Purpose |
| --- | --- |
| `--dry-run` | Print every `occ` / `curl` command without executing |
| `--print-only` | Just print the browser-step checklist and exit |
| `--skip-smtp` | Skip the SMTP section even if `SMTP_HOST` is set |
| `--skip-onlyoffice` | Skip just the ONLYOFFICE wiring |
| `--skip-paperless` | Skip tag seeding |
| `--skip-nextcloud` | Skip every Nextcloud stage |
| `--nc-wait-seconds <n>` | Override the Nextcloud install-wait timeout (default 300) |

It is **idempotent** — re-running is safe. It checks app install state
before installing, and fetches existing Paperless tags before POSTing new
ones.

### 1. Verify ONLYOFFICE in Nextcloud

After `configure-apps.sh` runs, visit `https://cloud.DOMAIN` as admin →
**Settings → Administration → ONLYOFFICE**. The server-reachability check
should be green. Open a `.docx` from Files to confirm the editor loads.

If the check fails, the most common cause is that Nextcloud cannot reach
`https://docs.DOMAIN/` — confirm DNS, TLS, and that `ONLYOFFICE_JWT` is
identical in both the Nextcloud app settings and the ONLYOFFICE container's
env (it is, if `configure-apps.sh` set it and the stack's `.env` was correct).

### 2. Create your first WireGuard peer

1. From a browser on the LAN, visit `https://vpn.DOMAIN`.
2. Log in with `WG_PASSWORD` from `.env`.
3. Create a new client, download the config (or scan the QR on mobile).
4. Install the WireGuard client on the user's machine and import the config.
5. Verify VPN-only services (`crm`, `vpn`, `status`) now load instead of 403.

### 3. Record admin credentials in Vaultwarden

1. Visit `https://vault.DOMAIN`. Sign up creates the first account (then
   `SIGNUPS_ALLOWED` should stay `false` — deploy.sh sets this).
2. Copy every password from `/srv/stack/.env` into a "Turnkey Stack Admin"
   vault entry. Include `RESTIC_PASSWORD` — **losing it means losing every
   backup forever**. Keep an offline printed copy too.

### 4. Populate Uptime Kuma

1. Visit `https://status.DOMAIN` (VPN required).
2. Create the admin account (first visit sets this).
3. Add HTTP(s) monitors for each public subdomain. A seed script is on the
   v1.0 roadmap — for now, add them by hand.

### 5. Create DocuSeal owner account

1. Visit `https://sign.DOMAIN`. First visit creates the owner account.
2. Set company name + logo. If SMTP is configured, send a test envelope to
   yourself to confirm delivery.

---

## Day-2 operations

### Re-run the app-wiring script

```bash
# Idempotent — re-running reconciles config to what .env says:
sudo /srv/stack/scripts/configure-apps.sh

# Just reprint the browser-only checklist (no mutations):
sudo /srv/stack/scripts/configure-apps.sh --print-only

# Preview what it would do after an .env change:
sudo /srv/stack/scripts/configure-apps.sh --dry-run
```

Useful after rotating `ONLYOFFICE_JWT`, changing SMTP, or adding Paperless
tags to the starter set.

### Health check

```bash
sudo /srv/stack/scripts/health-check.sh
```

Exits `0` (healthy) / `1` (degraded) / `2` (prereqs missing). Run manually,
from cron, or from an external monitor.

### Acceptance test (lab VMs only)

```bash
sudo /srv/stack/scripts/test-deploy.sh
```

Full backup + restore round-trip. **Refuses to run on non-lab domains**
(anything outside `.localhost`, `.test`, `.internal`, `.lab`, `.home.arpa`,
`.intranet`) unless `--force` is passed.

### Viewing logs

```bash
# All containers
cd /srv/stack && sudo docker compose logs -f

# Single service
sudo docker compose logs -f nextcloud

# Backup log
sudo tail -f /srv/stack/restic/logs/backup.log
```

### Restarting a service

```bash
cd /srv/stack
sudo docker compose restart nextcloud
```

### Updating images

```bash
cd /srv/stack
sudo docker compose pull         # new images from registries
sudo docker compose build        # rebuild stack-restic from local Dockerfile
sudo docker compose up -d        # apply new images
```

Always run a manual backup and verify `health-check.sh` passes before
major-version updates.

---

## Backup and restore

Backups run every night at 02:00 server-local time (configurable via
`BACKUP_SCHEDULE` in `.env`). Retention: 30 daily × 12 monthly × 3 yearly
snapshots.

### Run a backup manually

```bash
sudo docker exec stack-restic /scripts/backup.sh
```

### List snapshots

```bash
sudo docker exec stack-restic restic snapshots
```

### Restore a single file

```bash
# Pick a snapshot ID from the list above, then:
sudo docker exec stack-restic restic restore <SNAPSHOT_ID> \
  --target /tmp/restore \
  --include /srv/stack/nextcloud/data/<user>/files/<path>

# Copy out of the container:
sudo docker cp stack-restic:/tmp/restore/srv/stack/nextcloud/... /path/on/host
```

### Full disaster recovery

1. Provision a new VM with the same IP and install prerequisites.
2. Restore `/srv/stack/.env` from your offline copy (or Vaultwarden).
3. `git clone` the repo and run `./scripts/init-folders.sh`.
4. `docker exec` into a temporary `stack-restic` container (or run restic
   locally) with the same `RESTIC_REPOSITORY` and `RESTIC_PASSWORD` and
   `restic restore latest --target /`.
5. Run `./scripts/deploy.sh`. Existing `.env` is preserved; existing
   `/srv/stack/` data is preserved.
6. Run `./scripts/health-check.sh` to confirm.

A dedicated `RESTORE.md` runbook is on the v1.0 roadmap.

---

## Troubleshooting

**A subdomain returns 403 unexpectedly**
Check `TRUSTED_CIDRS` in `.env`. `crm`, `vpn`, and `status` require the
client's source IP to be inside that CIDR set. Non-VPN source IPs are
intentionally blocked.

**Let's Encrypt certificates aren't issuing**
Confirm your DNS wildcard resolves to the server IP (`dig +short '*.DOMAIN'`)
and that TCP/80 is reachable from the internet. Caddy needs port 80 open for
the HTTP-01 challenge. Check Caddy's log:
`sudo docker compose logs caddy | grep -i acme`.

**ONLYOFFICE fails to load in Nextcloud**
Verify `ONLYOFFICE_JWT` is identical on both sides (ONLYOFFICE container
env + Nextcloud admin UI). Check for mixed-content errors in the browser
console — the ONLYOFFICE URL must be `https://docs.DOMAIN/` with the
trailing slash.

**Backup not running**
Check the scheduler: `sudo docker compose logs ofelia`. Check the backup log:
`sudo tail -n 50 /srv/stack/restic/logs/backup.log`. Ofelia reads the cron
schedule from the `stack-restic` container's labels on startup — restart
Ofelia after changing `BACKUP_SCHEDULE`: `sudo docker compose restart ofelia`.

**A container won't start**
`sudo docker compose ps` to see state. `sudo docker compose logs <service>`
for output. `sudo docker inspect stack-<service>` for full config.

---

## Scope (what's NOT in v1)

Intentionally excluded — do **not** add these without a scope discussion:

- Self-hosted email (MTA/IMAP). Use an SMTP relay for outbound only.
- Active Directory / LDAP / SMB shares.
- Keycloak single sign-on. Reserved at `id.DOMAIN`; subdomain and
  email-based usernames are already consistent so rollout is clean.
- Kubernetes / Swarm / Nomad. Docker Compose only.
- Alternative reverse proxies (Traefik, Nginx). Caddy only.

---

## File reference

| Path | Purpose |
|---|---|
| [`scripts/deploy.sh`](scripts/deploy.sh) | One-shot deployment driver |
| [`scripts/configure-apps.sh`](scripts/configure-apps.sh) | Post-deploy app wiring (ONLYOFFICE↔Nextcloud JWT, SMTP, Paperless tags) |
| [`scripts/init-folders.sh`](scripts/init-folders.sh) | Provisions `/srv/stack/` + `stackuser` |
| [`scripts/health-check.sh`](scripts/health-check.sh) | Container/HTTP/backup probe |
| [`scripts/test-deploy.sh`](scripts/test-deploy.sh) | Lab acceptance test (safety-gated) |
| [`docker-compose.yml`](docker-compose.yml) | All 19 services |
| [`caddy/Caddyfile`](caddy/Caddyfile) | Reverse proxy routes + TLS + VPN gates |
| [`restic/Dockerfile`](restic/Dockerfile) | Local image: restic + DB clients |
| [`restic/scripts/backup.sh`](restic/scripts/backup.sh) | Nightly backup logic |
| [`.env.template`](.env.template) | Every config variable, documented |

---

## Roadmap — v1.0 pending items

- Weekly deep backup check (`restic check --read-data`)
- Uptime Kuma seed script (pre-populate monitors via API)
- Operational runbooks: `CLIENT_ONBOARDING.md`, `RESTORE.md`, `ROTATE_SECRETS.md`
- Client handover template

After v1.0 ships, the first candidate for v1.x is Keycloak SSO at `id.DOMAIN`.
