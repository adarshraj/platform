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
#   4. Starts test Traefik (HTTP + self-signed HTTPS, no CrowdSec)
#   5. Prints your nip.io URLs

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# ── 2. GHCR token ─────────────────────────────────────────────────────────────
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
  success "Token saved to $TOKEN_FILE"
fi

info "Authenticating with GHCR..."
bash "$PLATFORM_DIR/scripts/ghcr-login.sh"

# ── 3. Docker networks ─────────────────────────────────────────────────────────
info "Creating Docker networks..."
bash "$PLATFORM_DIR/infra/networks/create-networks.sh" 2>/dev/null || true
success "Networks ready"

# ── 4. Start test Traefik ──────────────────────────────────────────────────────
info "Starting test Traefik..."
cd "$PLATFORM_DIR/test/traefik"
docker compose up -d
success "Traefik running"

# ── 5. Get public IP and print URLs ───────────────────────────────────────────
echo ""
info "Detecting public IP..."
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "unknown")

echo ""
echo "========================================"
echo "   Test Deployment Ready!"
echo "========================================"
echo ""
if [ "$PUBLIC_IP" != "unknown" ]; then
  echo "  Your nip.io hostnames (IP: $PUBLIC_IP):"
  echo ""
  echo "  Traefik dashboard : http://$PUBLIC_IP:8080"
  echo "  Auth service      : http://auth.$PUBLIC_IP.nip.io"
  echo "  AI Shim           : http://aishim.$PUBLIC_IP.nip.io"
  echo "  Finance Tracker   : http://finance.$PUBLIC_IP.nip.io"
  echo ""
  echo "  Set these env vars before deploying each app:"
  echo ""
  echo "    AUTH_SERVICE_HOST=auth.$PUBLIC_IP.nip.io"
  echo "    AI_SHIM_HOST=aishim.$PUBLIC_IP.nip.io"
  echo "    FINANCE_HOST=finance.$PUBLIC_IP.nip.io"
else
  warn "Could not detect public IP. Run: curl ifconfig.me"
  echo "  Then use: <service>.<your-ip>.nip.io as hostnames"
fi
echo ""
echo "  Next: clone your app repos and deploy them."
echo "  See: ~/platform/docs/vps-deployment.md"
echo ""
