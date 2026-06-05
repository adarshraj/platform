#!/bin/bash
# Configure Uptime Kuma: create admin account and add monitors for all platform services.
# Uses only curl and sqlite3 (available inside the uptime-kuma container).
#
# Usage: bash ~/platform/scripts/setup-uptime-kuma.sh <vps-ip> <admin-password>
#
# Example:
#   bash ~/platform/scripts/setup-uptime-kuma.sh 65.20.74.236 MySecurePassword123

set -euo pipefail

IP="${1:-}"
ADMIN_PASSWORD="${2:-}"

if [ -z "$IP" ] || [ -z "$ADMIN_PASSWORD" ]; then
  echo "Usage: $0 <vps-ip> <admin-password>"
  exit 1
fi

BASE_URL="https://status.$IP.nip.io"
ADMIN_USER="admin"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()    { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }

# ── 1. Create admin account (only works if no user exists yet) ────────────────
info "Creating admin account..."
SETUP_RESULT=$(curl -sk -X POST "$BASE_URL/api/setup" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASSWORD\"}" 2>&1)

if echo "$SETUP_RESULT" | grep -q '"ok":true'; then
  success "Admin account created: $ADMIN_USER"
elif echo "$SETUP_RESULT" | grep -q "already setup"; then
  warn "Admin account already exists — skipping setup"
else
  warn "Setup response: $SETUP_RESULT"
fi

# ── 2. Insert monitors directly into SQLite ───────────────────────────────────
info "Adding monitors to database..."

# Get user_id (should be 1 for first user)
USER_ID=$(docker exec uptime-kuma sqlite3 /app/data/kuma.db "SELECT id FROM user LIMIT 1;" 2>/dev/null || echo "1")

add_monitor() {
  local name="$1"
  local url="$2"
  local interval="${3:-60}"

  # Check if monitor already exists
  EXISTS=$(docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    "SELECT COUNT(*) FROM monitor WHERE name='$name';" 2>/dev/null || echo "0")

  if [ "$EXISTS" -gt 0 ]; then
    warn "Monitor '$name' already exists — skipping"
    return
  fi

  docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    "INSERT INTO monitor (name, type, url, interval, user_id, active, maxretries, ignore_tls, accepted_statuscodes_json)
     VALUES ('$name', 'http', '$url', $interval, $USER_ID, 1, 3, 1, '[\"200-299\"]');" 2>/dev/null

  success "Added monitor: $name → $url"
}

# Core services
add_monitor "Finance Tracker"  "https://finance.$IP.nip.io"                        60
add_monitor "Auth Service"     "https://auth.$IP.nip.io/q/health/live"              60
add_monitor "AI Shim"          "https://aishim.$IP.nip.io/q/health/live"            60
add_monitor "Doc Bucket"       "https://docbucket.$IP.nip.io/q/health/live"         60
add_monitor "Email Service"    "https://mail.$IP.nip.io/q/health/live"              60
add_monitor "Garage (S3)"      "https://s3.$IP.nip.io"                              60

# Platform infra
add_monitor "Grafana"          "https://grafana.$IP.nip.io/api/health"              60
add_monitor "Portainer"        "https://portainer.$IP.nip.io/api/system/status"     60
add_monitor "Loki"             "http://loki:3100/ready"                             60

# Apps
add_monitor "KidLearn"         "https://kidlearn.$IP.nip.io"                        60
add_monitor "HomeUtils"        "https://homeutils.$IP.nip.io"                       60

# ── 3. Restart Uptime Kuma to pick up the new monitors ───────────────────────
info "Restarting Uptime Kuma to load monitors..."
docker restart uptime-kuma >/dev/null 2>&1
sleep 5
success "Done"

echo ""
echo "  Uptime Kuma: $BASE_URL"
echo "  Login: $ADMIN_USER / <your password>"
echo ""
echo "  Monitors added — check the dashboard to confirm all are active."
