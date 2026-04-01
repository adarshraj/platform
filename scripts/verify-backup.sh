#!/bin/bash
# Verify the most recent backup is intact.
# Checks: pg_dump readability, tar archive integrity, file sizes.
# Run after backup or on a schedule to catch silent failures.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/platform}"

# Find the most recent backup directory
LATEST=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)

if [ -z "$LATEST" ]; then
  echo "ERROR: No backups found in $BACKUP_DIR"
  exit 1
fi

echo "=== Verifying backup: $LATEST ==="

ERRORS=0

# --- Check PostgreSQL dumps ---
echo ""
echo "Checking PostgreSQL dumps..."
for dump in "$LATEST"/*.sql.gz; do
  [ -e "$dump" ] || { echo "  No SQL dumps found."; break; }
  filename=$(basename "$dump")
  size=$(stat -c%s "$dump" 2>/dev/null || stat -f%z "$dump" 2>/dev/null)

  # Check file is not empty
  if [ "$size" -lt 100 ]; then
    echo "  ✗ $filename — suspiciously small (${size} bytes)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Verify gzip integrity
  if gzip -t "$dump" 2>/dev/null; then
    # Verify it contains valid SQL (check for common pg_dump markers)
    if gunzip -c "$dump" 2>/dev/null | head -5 | grep -qE '(PostgreSQL database dump|pg_dump|SET|CREATE)'; then
      echo "  ✓ $filename ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"))"
    else
      echo "  ✗ $filename — does not look like a valid pg_dump"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "  ✗ $filename — corrupt gzip"
    ERRORS=$((ERRORS + 1))
  fi
done

# --- Check tar archives ---
echo ""
echo "Checking tar archives..."
for archive in "$LATEST"/*.tar.gz; do
  [ -e "$archive" ] || { echo "  No tar archives found."; break; }
  filename=$(basename "$archive")
  size=$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null)

  if [ "$size" -lt 100 ]; then
    echo "  ✗ $filename — suspiciously small (${size} bytes)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Verify tar+gzip integrity (list contents without extracting)
  if tar -tzf "$archive" >/dev/null 2>&1; then
    file_count=$(tar -tzf "$archive" 2>/dev/null | wc -l)
    echo "  ✓ $filename ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"), $file_count files)"
  else
    echo "  ✗ $filename — corrupt archive"
    ERRORS=$((ERRORS + 1))
  fi
done

# --- Generate checksum manifest ---
echo ""
echo "Generating checksum manifest..."
MANIFEST="$LATEST/checksums.sha256"
(cd "$LATEST" && find . -maxdepth 1 -type f ! -name 'checksums.sha256' -exec sha256sum {} + > checksums.sha256)
echo "  ✓ Written to $MANIFEST ($(wc -l < "$MANIFEST") entries)"

# --- Summary ---
echo ""
TOTAL_FILES=$(find "$LATEST" -maxdepth 1 -type f ! -name 'checksums.sha256' | wc -l)
TOTAL_SIZE=$(du -sh "$LATEST" 2>/dev/null | cut -f1)
echo "Backup: $TOTAL_FILES files, $TOTAL_SIZE total"

if [ "$ERRORS" -gt 0 ]; then
  echo "RESULT: $ERRORS error(s) found — backup may be incomplete or corrupt."
  exit 1
else
  echo "RESULT: All checks passed."
fi
