#!/bin/bash
# Test deployment setup for a fresh VPS with no domain.
# Uses nip.io for hostnames and HTTP/self-signed HTTPS via test Traefik config.
#
# Usage:
#   bash ~/platform/scripts/test-setup.sh
#
# What this does:
#   1. Installs prerequisites (Docker, Infisical CLI, etc.)
#   2. Sets up GHCR authentication
#   3. Creates Docker networks
#   4. Starts test Traefik (HTTP, no CrowdSec)
#   5. Clones app repos (auth-service, ai-shim, finance-tracker)
#   6. Generates .env files for each app
#   7. Deploys each app in dependency order
#   8. Prints nip.io URLs

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="$HOME/apps"
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }

echo ""
echo "========================================"
echo "   Platform — Test Deployment Setup"
echo "========================================"
echo ""

# ── 1. Prerequisites ───────────────────────────────────────────────────────────
info "Checking prerequisites..."
MISSING=()
for cmd in docker git python3 curl; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  warn "Missing: ${MISSING[*]}. Installing prerequisites..."
  if [ "$EUID" -ne 0 ]; then
    sudo bash "$PLATFORM_DIR/scripts/install-prerequisites.sh"
  else
    bash "$PLATFORM_DIR/scripts/install-prerequisites.sh"
  fi
else
  success "Prerequisites already installed"
fi

# ── 2. GHCR token (read:packages — for pulling Docker images) ─────────────────
TOKEN_FILE="$HOME/.config/platform/ghcr-token"
mkdir -p "$HOME/.config/platform"

if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  info "GHCR token already exists. Use existing? [Y/n]: "
  read -r USE_EXISTING
  if [[ "$USE_EXISTING" =~ ^[Nn]$ ]]; then
    rm -f "$TOKEN_FILE"
  fi
fi

if [ ! -f "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ]; then
  echo ""
  echo "  Enter your GitHub Classic PAT (read:packages scope)."
  echo "  Get one at: GitHub → Settings → Developer settings → Tokens (classic)"
  echo ""
  read -rsp "  Paste token (input hidden): " GHCR_TOKEN
  echo ""
  echo "$GHCR_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  success "GHCR token saved"
fi

info "Authenticating with GHCR..."
bash "$PLATFORM_DIR/scripts/ghcr-login.sh"

# ── 2b. Clone token (repo scope — for cloning private repos) ──────────────────
CLONE_TOKEN_FILE="$HOME/.config/platform/clone-token"

if [ -f "$CLONE_TOKEN_FILE" ] && [ -s "$CLONE_TOKEN_FILE" ]; then
  info "Clone token already exists. Use existing? [Y/n]: "
  read -r USE_EXISTING_CLONE
  if [[ "$USE_EXISTING_CLONE" =~ ^[Nn]$ ]]; then
    rm -f "$CLONE_TOKEN_FILE"
  fi
fi

if [ ! -f "$CLONE_TOKEN_FILE" ] || [ ! -s "$CLONE_TOKEN_FILE" ]; then
  echo ""
  echo "  Enter your GitHub Classic PAT (repo scope — for cloning private repos)."
  echo "  Can be the same token if it has both read:packages and repo scopes."
  echo ""
  read -rsp "  Paste token (input hidden): " CLONE_TOKEN
  echo ""
  echo "$CLONE_TOKEN" > "$CLONE_TOKEN_FILE"
  chmod 600 "$CLONE_TOKEN_FILE"
  success "Clone token saved"
fi

CLONE_TOKEN="$(cat "$CLONE_TOKEN_FILE")"

# ── 3. Docker networks ─────────────────────────────────────────────────────────
info "Creating Docker networks..."
bash "$PLATFORM_DIR/infra/networks/create-networks.sh" 2>/dev/null || true
success "Networks ready"

# ── 4. Start Redis ────────────────────────────────────────────────────────────
REDIS_ENV="$PLATFORM_DIR/infra/redis/.env"
if [ ! -f "$REDIS_ENV" ]; then
  info "Generating Redis password..."
  echo "REDIS_PASSWORD=$(openssl rand -hex 32)" > "$REDIS_ENV"
  success "Redis password generated and saved"
fi
info "Starting Redis..."
docker compose -f "$PLATFORM_DIR/infra/redis/docker-compose.yml" --env-file "$REDIS_ENV" up -d
success "Redis running"

# ── 5. Start test Traefik ──────────────────────────────────────────────────────
info "Starting test Traefik..."
cd "$PLATFORM_DIR/test/traefik"
docker compose up -d
success "Traefik running"

# ── 5. Detect public IP ────────────────────────────────────────────────────────
info "Detecting public IP..."
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "")

if [ -z "$PUBLIC_IP" ]; then
  read -rp "Could not detect IP automatically. Enter your VPS IP: " PUBLIC_IP
fi
success "VPS IP: (hidden)"

# ── 6. Clone app repos ─────────────────────────────────────────────────────────
mkdir -p "$APPS_DIR"

clone_or_pull() {
  local name=$1
  local repo=$2
  if [ -d "$APPS_DIR/$name/.git" ]; then
    info "$name already cloned — pulling latest..."
    git -C "$APPS_DIR/$name" pull --ff-only
  else
    info "Cloning $name..."
    git clone "https://${CLONE_TOKEN}@github.com/$repo" "$APPS_DIR/$name"
  fi
  success "$name ready"
}

clone_or_pull auth-service     adarshraj/auth-service
clone_or_pull ai-shim          adarshraj/ai-shim
clone_or_pull doc-bucket       adarshraj/DocBucket
clone_or_pull email-service    adarshraj/email-service
clone_or_pull finance-tracker  adarshraj/finance-tracker

# ── 7. Generate .env files ────────────────────────────────────────────────────
info "Generating .env files..."
bash "$PLATFORM_DIR/scripts/gen-env.sh" auth-service     "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" ai-shim          "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" doc-bucket       "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" email-service    "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" finance-tracker  "$PUBLIC_IP"
success ".env files generated"

# ── 8. Deploy apps in order ────────────────────────────────────────────────────
# Images are pulled from GHCR (built by GitHub Actions CI).

deploy() {
  local name=$1
  local compose=$2
  local app_dir=$3
  info "Deploying $name..."
  docker compose -f "$compose" --env-file "$app_dir/.env" pull
  docker compose -f "$compose" --env-file "$app_dir/.env" up -d
  success "$name deployed"
}

deploy auth-service     "$APPS_DIR/auth-service/docker-compose.prod.yml"  "$APPS_DIR/auth-service"
deploy ai-shim          "$APPS_DIR/ai-shim/docker-compose.yml"          "$APPS_DIR/ai-shim"
deploy doc-bucket       "$APPS_DIR/doc-bucket/docker-compose.yml"       "$APPS_DIR/doc-bucket"
deploy email-service    "$APPS_DIR/email-service/docker-compose.yml"    "$APPS_DIR/email-service"
deploy finance-tracker  "$APPS_DIR/finance-tracker/docker-compose.yml"  "$APPS_DIR/finance-tracker"

# ── 9. Print URLs ──────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "   Test Deployment Complete!"
echo "========================================"
echo ""
echo "  Traefik dashboard : http://$PUBLIC_IP:8080"
echo "  Auth service      : http://auth.$PUBLIC_IP.nip.io"
echo "  AI Shim           : http://aishim.$PUBLIC_IP.nip.io"
echo "  Finance Tracker   : http://finance.$PUBLIC_IP.nip.io"
echo ""
echo "  Verify containers: docker ps"
echo ""
