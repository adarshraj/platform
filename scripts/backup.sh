#!/bin/bash
# Backup all PostgreSQL databases and critical volumes.
# Runs daily via cron (set up by bootstrap.sh).
# Optionally syncs to remote storage via rclone.

set -euo pipefail
umask 077

# Pin the utility image used for volume backups to avoid pulling an unknown :latest on each run.
ALPINE_IMAGE="alpine:3.21"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/platform}"
DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$DATE"
RETENTION_DAYS=7

mkdir -p "$BACKUP_PATH"

echo "[$DATE] Starting backup..."

# --- PostgreSQL backups ---
# Discover postgres containers by label (preferred) then fall back to image/name filters.
# To opt a container in via label, add to its compose service:
#   labels:
#     com.platform.backup: postgres
mapfile -t LABELED_CONTAINERS < <(docker ps --filter "label=com.platform.backup=postgres" --format "{{.Names}}" 2>/dev/null || true)
mapfile -t FILTER_CONTAINERS < <({ \
  docker ps --filter "ancestor=postgres:16-alpine" --format "{{.Names}}" 2>/dev/null; \
  docker ps --filter "ancestor=postgres" --format "{{.Names}}" 2>/dev/null; \
} | sort -u || true)

# Merge and deduplicate
mapfile -t POSTGRES_CONTAINERS < <(printf '%s\n' "${LABELED_CONTAINERS[@]}" "${FILTER_CONTAINERS[@]}" | sort -u | grep -v '^$' || true)

BACKUP_FAILURES=0
for container in "${POSTGRES_CONTAINERS[@]}"; do
  [ -z "$container" ] && continue
  db_name=$(docker inspect "$container" --format '{{range .Config.Env}}{{if (eq (slice . 0 13) "POSTGRES_DB=")}}{{slice . 13}}{{end}}{{end}}' 2>/dev/null || echo "postgres")
  db_user=$(docker inspect "$container" --format '{{range .Config.Env}}{{if (eq (slice . 0 14) "POSTGRES_USER=")}}{{slice . 14}}{{end}}{{end}}' 2>/dev/null || echo "postgres")
  # Default to "postgres" if env vars were empty
  db_name="${db_name:-postgres}"
  db_user="${db_user:-postgres}"
  echo "  Backing up PostgreSQL container: $container (db: $db_name)"
  # Run pg_dump in a subshell so a single failure doesn't abort the loop
  if docker exec "$container" pg_dump -U "$db_user" "$db_name" \
      | gzip > "$BACKUP_PATH/${container}-${db_name}.sql.gz"; then
    echo "    ✓ $container"
  else
    echo "    ✗ Failed: $container"
    rm -f "$BACKUP_PATH/${container}-${db_name}.sql.gz"
    BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
  fi
done

# --- Infisical volume backup ---
echo "  Backing up Infisical volume..."
if docker run --rm \
  -v infisical_db_data:/data:ro \
  -v "$BACKUP_PATH":/backup \
  "$ALPINE_IMAGE" tar czf "/backup/infisical-db-data.tar.gz" /data 2>/dev/null; then
  echo "    ✓ Infisical"
else
  echo "    ✗ Failed: Infisical"
  BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
fi

# --- Loki volume backup ---
# Loki must be stopped during backup to avoid an inconsistent data snapshot.
echo "  Backing up Loki volume (stopping Loki briefly)..."
LOKI_WAS_RUNNING=false
if docker ps --format "{{.Names}}" | grep -q "^loki$"; then
  LOKI_WAS_RUNNING=true
  docker stop loki >/dev/null
fi

# Ensure Loki is restarted even if the script is interrupted or fails
restart_loki() {
  if [ "$LOKI_WAS_RUNNING" = "true" ]; then
    docker start loki >/dev/null 2>&1 || true
  fi
}
trap restart_loki EXIT INT TERM

if docker run --rm \
  -v loki_data:/data:ro \
  -v "$BACKUP_PATH":/backup \
  "$ALPINE_IMAGE" tar czf "/backup/loki-data.tar.gz" /data 2>/dev/null; then
  echo "    ✓ Loki"
else
  echo "    ✗ Failed: Loki"
  BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
fi

restart_loki
trap - EXIT INT TERM

# --- Remove old backups ---
echo "  Pruning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

# --- Sync to remote (optional, requires rclone configured) ---
if command -v rclone &>/dev/null && rclone listremotes | grep -q "backup:"; then
  echo "  Syncing to remote storage..."
  rclone copy "$BACKUP_DIR" "backup:platform-backups" --transfers=4 && echo "    ✓ Remote sync" || echo "    ✗ Remote sync failed"
fi

if [ "${BACKUP_FAILURES:-0}" -gt 0 ]; then
  echo "[$DATE] Backup complete with $BACKUP_FAILURES failure(s). Stored at: $BACKUP_PATH"
  exit 1
else
  echo "[$DATE] Backup complete. Stored at: $BACKUP_PATH"
fi
