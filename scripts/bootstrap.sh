#!/bin/bash
# Bootstrap a fresh VPS with the full platform stack.
# Run once after cloning this repo.

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Platform Bootstrap ==="
echo "Platform dir: $PLATFORM_DIR"
echo ""

# 1. Check Docker is installed
if ! command -v docker &>/dev/null; then
  echo "Docker not found. Installing..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Docker installed. You may need to log out and back in for group changes to take effect."
fi

# 2. Create shared networks
echo "Creating shared Docker networks..."
bash "$PLATFORM_DIR/infra/networks/create-networks.sh"

# 3. Start infrastructure in order
echo ""
echo "Starting Docker socket proxy..."
cd "$PLATFORM_DIR/infra/docker-proxy" && docker compose up -d
echo "  ✓ Docker socket proxy"

echo "Starting Traefik + CrowdSec..."
if [ ! -f "$PLATFORM_DIR/infra/traefik/.env" ]; then
  echo "  WARNING: infra/traefik/.env not found — CrowdSec bouncer won't authenticate."
  echo "  Copy infra/traefik/.env.example to infra/traefik/.env"
  echo "  After first start, run: docker exec crowdsec cscli bouncers add traefik-bouncer"
  echo "  Then paste the key into .env and restart: cd infra/traefik && docker compose up -d"
fi
cd "$PLATFORM_DIR/infra/traefik" && docker compose --env-file .env up -d 2>/dev/null || \
  cd "$PLATFORM_DIR/infra/traefik" && docker compose up -d
echo "  ✓ Traefik + CrowdSec"

echo "Starting Portainer..."
cd "$PLATFORM_DIR/infra/portainer" && docker compose up -d
echo "  ✓ Portainer"

echo "Starting Infisical..."
if [ ! -f "$PLATFORM_DIR/infra/secrets/.env" ]; then
  echo "  ERROR: infra/secrets/.env not found."
  echo "  Copy infra/secrets/.env.example to infra/secrets/.env and fill in the values."
  exit 1
fi
cd "$PLATFORM_DIR/infra/secrets" && docker compose --env-file .env up -d
echo "  ✓ Infisical"

echo "Starting logging (Loki + Promtail)..."
cd "$PLATFORM_DIR/infra/logging" && docker compose up -d
echo "  ✓ Loki + Promtail"

echo "Starting monitoring (Prometheus + Grafana + cAdvisor + node-exporter)..."
if [ ! -f "$PLATFORM_DIR/infra/monitoring/.env" ]; then
  echo "  ERROR: infra/monitoring/.env not found."
  echo "  Copy infra/monitoring/.env.example to infra/monitoring/.env and fill in the values."
  exit 1
fi
cd "$PLATFORM_DIR/infra/monitoring" && docker compose --env-file .env up -d
echo "  ✓ Prometheus + Grafana + cAdvisor + node-exporter"

echo "Starting Verdaccio (npm registry)..."
cd "$PLATFORM_DIR/infra/registry" && docker compose up -d
echo "  ✓ Verdaccio"

echo "Starting Uptime Kuma (status page)..."
cd "$PLATFORM_DIR/infra/uptime-kuma" && docker compose up -d
echo "  ✓ Uptime Kuma"

# 4. Set up daily backup cron
CRON_JOB="0 2 * * * $PLATFORM_DIR/scripts/backup.sh >> /var/log/platform-backup.log 2>&1"
(crontab -l 2>/dev/null | grep -qF "platform/scripts/backup.sh") || \
  (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
echo "  ✓ Daily backup cron scheduled at 2am"

VERIFY_JOB="30 2 * * * $PLATFORM_DIR/scripts/verify-backup.sh >> /var/log/platform-backup-verify.log 2>&1"
(crontab -l 2>/dev/null | grep -qF "platform/scripts/verify-backup.sh") || \
  (crontab -l 2>/dev/null; echo "$VERIFY_JOB") | crontab -
echo "  ✓ Daily backup verification scheduled at 2:30am"
echo ""

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Access URLs (add these to /etc/hosts or your DNS resolver):"
echo "  https://traefik.homelab.local     → Traefik dashboard"
echo "  https://portainer.homelab.local   → Portainer"
echo "  https://monitoring.homelab.local  → Grafana"
echo "  https://secrets.homelab.local     → Infisical"
echo "  https://npm.homelab.local         → Verdaccio"
echo "  https://status.homelab.local      → Uptime Kuma"
echo ""
echo "Next steps:"
echo "  1. Configure DNS: point *.homelab.local to this server's IP"
echo "  2. Set up TLS cert: see docs/local-dev.md"
echo "  3. Migrate app secrets to Infisical"
echo "  4. Deploy your first app: ./scripts/deploy-app.sh <app-name> production"
