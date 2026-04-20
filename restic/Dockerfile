# =============================================================================
# Turnkey Self-Hosted Business Server v1 — stack-restic image
# -----------------------------------------------------------------------------
# Replaces the `alpine + apk add at entrypoint` pattern from the initial build.
# Benefits:
#   - Tool versions pinned via Alpine tag (no surprise upgrades).
#   - No network dependency on container restart.
#   - Faster cold start (no apk run before backup.sh is usable).
#
# Build:  (invoked by docker-compose automatically)
#   docker build -t stack-restic:local ./restic
#
# Contents:
#   bash               — backup.sh shebang / `set -euo pipefail`
#   restic             — backup engine
#   postgresql16-client — pg_dump for Nextcloud + Paperless (Postgres 15 server,
#                         v16 client is wire-compatible and ships a newer pg_dump)
#   mariadb-client     — mariadb-dump for Dolibarr + Kimai
#   ca-certificates    — TLS roots for S3/B2/SFTP restic repositories
#   tzdata             — resolves ${TIMEZONE} from .env inside container
#   coreutils          — GNU du/date used by backup.sh log timestamps
# =============================================================================

FROM alpine:3.19

# Install everything in one layer for a smaller image.
RUN apk add --no-cache \
      bash \
      restic \
      postgresql16-client \
      mariadb-client \
      ca-certificates \
      tzdata \
      coreutils \
    && rm -rf /var/cache/apk/*

# The scripts and logs directories are bind-mounted at runtime (see compose).
# Create mount-point shells so permissions are predictable if mounts are missing.
RUN mkdir -p /scripts /var/log/restic /tmp/dumps \
    && chmod 700 /tmp/dumps

# Sanity check — fail the image build if any required tool is missing.
RUN for t in bash restic pg_dump mariadb-dump gzip; do \
      command -v "$t" >/dev/null || { echo "MISSING: $t" >&2; exit 1; }; \
    done

# No CMD / ENTRYPOINT here — docker-compose.yml sets them. Keeping the image
# command-agnostic means the same image can be used for ad-hoc `docker run`
# invocations (restore, manual snapshot inspection, etc.).
