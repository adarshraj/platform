#!/bin/bash
# Install all software required by the platform before bootstrap runs.
# Run this once on a fresh VPS after cloning this repo.
#
# What this installs:
#   - git, curl, wget, python3          system utilities
#   - docker + docker compose plugin    container runtime
#   - infisical CLI                     secrets injection at deploy time
#
# Usage:
#   sudo bash ~/platform/scripts/install-prerequisites.sh
#
# Must be run as root or with sudo.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run with sudo."
  echo "  sudo bash $0"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"

echo "=== Installing platform prerequisites ==="
echo "Running as: $REAL_USER"
echo ""

# ── Detect OS ──────────────────────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  echo "ERROR: This script supports Debian/Ubuntu only (apt-get not found)."
  exit 1
fi

# ── 1. System packages ─────────────────────────────────────────────────────────
echo "Installing system packages..."
apt-get update -q
apt-get install -y -q \
  git \
  curl \
  wget \
  python3 \
  ca-certificates \
  gnupg \
  lsb-release
echo "  ✓ git, curl, wget, python3"

# ── 2. Docker ──────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  echo "  ✓ Docker already installed ($(docker --version))"
else
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  echo "  ✓ Docker installed"
fi

# Ensure Docker Compose v2 plugin is available
if ! docker compose version &>/dev/null; then
  echo "Installing Docker Compose plugin..."
  apt-get install -y -q docker-compose-plugin
fi
echo "  ✓ Docker Compose $(docker compose version --short)"

# Add the real user to the docker group so sudo isn't needed for docker commands
if ! groups "$REAL_USER" | grep -q docker; then
  usermod -aG docker "$REAL_USER"
  echo "  ✓ Added $REAL_USER to docker group"
  echo "  ⚠  Log out and back in (or run 'newgrp docker') for group change to take effect"
else
  echo "  ✓ $REAL_USER already in docker group"
fi

# ── 3. Infisical CLI ───────────────────────────────────────────────────────────
if command -v infisical &>/dev/null; then
  echo "  ✓ Infisical CLI already installed ($(infisical --version 2>&1 | head -1))"
else
  echo "Installing Infisical CLI..."
  curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' \
    | bash
  apt-get install -y -q infisical
  echo "  ✓ Infisical CLI installed ($(infisical --version 2>&1 | head -1))"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "=== Prerequisites installed ==="
echo ""
echo "Next steps:"
echo "  1. Log out and back in if Docker group was just added"
echo "  2. Set up GHCR token:"
echo "       mkdir -p ~/.config/platform"
echo "       echo 'github_pat_xxx' > ~/.config/platform/ghcr-token"
echo "       chmod 600 ~/.config/platform/ghcr-token"
echo "  3. Fill in .env files:"
echo "       cp ~/platform/infra/traefik/.env.example    ~/platform/infra/traefik/.env"
echo "       cp ~/platform/infra/secrets/.env.example    ~/platform/infra/secrets/.env"
echo "       cp ~/platform/infra/monitoring/.env.example ~/platform/infra/monitoring/.env"
echo "  4. Run bootstrap:"
echo "       ~/platform/scripts/bootstrap.sh"
