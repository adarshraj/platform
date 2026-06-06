#!/bin/bash
# Tear down everything created by test-setup.sh.
# Run this before switching to a real production bootstrap.
#
# What it removes:
#   - All app containers + their volumes (postgres, doc-bucket data, etc.)
#   - Test Traefik stack
#   - Infra stacks started by test-setup (redis, garage, loki, portainer, etc.)
#   - Generated .env files and garage.toml (secrets tied to the test run)
#   - Docker images (optional, saves disk space)
#
# What it keeps:
#   - Docker itself
#   - The platform repo (~platform/)
#   - The app repos (~apps/) — source code only, .env files are removed
#   - GHCR token (~/.config/platform/ghcr-token) — reusable in production

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="$HOME/apps"
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }

echo ""
echo "========================================"
echo "   Platform — Test Cleanup"
echo "========================================"
echo ""
warn "This will stop and remove all test containers and volumes."
warn "App source code in ~/apps/ is kept. Only .env files are removed."
echo ""
read -rp "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ── 1. Stop and remove app stacks (with volumes) ─────────────────────────────
info "Stopping app stacks..."

down_if_exists() {
  local compose=$1
  if [ -f "$compose" ]; then
    docker compose -f "$compose" down -v --remove-orphans 2>/dev/null || true
  fi
}

down_if_exists "$APPS_DIR/finance-tracker/docker-compose.yml"
down_if_exists "$APPS_DIR/doc-bucket/docker-compose.yml"
down_if_exists "$APPS_DIR/email-service/docker-compose.yml"
down_if_exists "$APPS_DIR/paddle-ocr-wrap/docker-compose.prod.yml"
down_if_exists "$APPS_DIR/ai-shim/docker-compose.yml"
down_if_exists "$APPS_DIR/auth-service/docker-compose.prod.yml"
success "App stacks stopped"

# ── 2. Stop test Traefik ──────────────────────────────────────────────────────
info "Stopping test Traefik..."
docker compose -f "$PLATFORM_DIR/test/traefik/docker-compose.yml" down --remove-orphans 2>/dev/null || true
success "Test Traefik stopped"

# ── 3. Stop infra stacks started by test-setup ───────────────────────────────
info "Stopping infra stacks..."
down_if_exists "$PLATFORM_DIR/infra/garage/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/redis/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/logging/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/monitoring/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/portainer/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/secrets/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/uptime-kuma/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/umami/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/registry/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/tracing/docker-compose.yml"
down_if_exists "$PLATFORM_DIR/infra/docker-proxy/docker-compose.yml"
success "Infra stacks stopped"

# ── 4. Remove any leftover named volumes not caught by compose down ───────────
info "Pruning leftover volumes..."
docker volume prune -f 2>/dev/null || true
success "Volumes pruned"

# ── 5. Remove generated secrets and .env files ───────────────────────────────
info "Removing generated .env files and secrets..."

# Infra-level generated files
rm -f "$PLATFORM_DIR/infra/garage/garage.toml"
rm -f "$PLATFORM_DIR/infra/garage/.env"
rm -f "$PLATFORM_DIR/infra/redis/.env"
rm -f "$PLATFORM_DIR/infra/secrets/.env"
rm -f "$PLATFORM_DIR/infra/monitoring/.env"
rm -f "$PLATFORM_DIR/infra/traefik/.env"
rm -f "$PLATFORM_DIR/infra/umami/.env"

# App .env files (source code in ~/apps/ is kept)
for app in auth-service ai-shim doc-bucket email-service paddle-ocr-wrap finance-tracker; do
  rm -f "$APPS_DIR/$app/.env"
done

# No separate clone token — the GHCR token (ghcr-token) covers both and is kept for production reuse

success "Generated files removed"

# ── 6. Optional: remove pulled Docker images and build cache ─────────────────
echo ""
read -rp "Remove pulled Docker images and build cache to free disk space? [y/N]: " PRUNE_IMAGES
if [[ "$PRUNE_IMAGES" =~ ^[Yy]$ ]]; then
  info "Pruning images..."
  docker image prune -a -f
  info "Pruning build cache (npm/maven layers from CI builds)..."
  docker builder prune -a -f
  success "Images and build cache removed"
fi

# ── 7. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "   Cleanup Complete"
echo "========================================"
echo ""
echo "  Removed: all test containers, volumes, and generated secrets"
echo "  Kept:    ~/apps/ source code, GHCR token, platform repo"
echo ""
echo "  Ready for production bootstrap:"
echo "    1. Fill in production .env files:"
echo "       cp ~/platform/infra/traefik/.env.example ~/platform/infra/traefik/.env"
echo "       cp ~/platform/infra/secrets/.env.example ~/platform/infra/secrets/.env"
echo "       cp ~/platform/infra/monitoring/.env.example ~/platform/infra/monitoring/.env"
echo "    2. Configure DNS: *.yourdomain.com → $(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo '<vps-ip>')"
echo "    3. Run: ~/platform/scripts/bootstrap.sh"
echo ""
