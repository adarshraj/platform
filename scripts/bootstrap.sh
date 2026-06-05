#!/bin/bash
# Bootstrap a fresh VPS with the full platform stack.
# Run once after cloning this repo.

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Platform Bootstrap ==="
echo "Platform dir: $PLATFORM_DIR"
echo ""

# 1. Verify prerequisites
MISSING=()
for cmd in docker git python3 infisical curl; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: Missing required tools: ${MISSING[*]}"
  echo "Run first: sudo bash $PLATFORM_DIR/scripts/install-prerequisites.sh"
  exit 1
fi
echo "  ✓ Prerequisites verified"

# 2. Authenticate with GHCR (required to pull private images)
echo "Logging in to GitHub Container Registry..."
bash "$PLATFORM_DIR/scripts/ghcr-login.sh"

# 3. Create shared networks
echo "Creating shared Docker networks..."
bash "$PLATFORM_DIR/infra/networks/create-networks.sh"

# 4. Start infrastructure in order
echo ""
echo "Starting Docker socket proxy..."
cd "$PLATFORM_DIR/infra/docker-proxy" && docker compose up -d
echo "  ✓ Docker socket proxy"

echo "Starting Redis..."
REDIS_ENV="$PLATFORM_DIR/infra/redis/.env"
if [ ! -f "$REDIS_ENV" ]; then
  echo "REDIS_PASSWORD=$(openssl rand -hex 32)" > "$REDIS_ENV"
  echo "  ✓ Redis password generated"
fi
cd "$PLATFORM_DIR/infra/redis" && docker compose --env-file "$REDIS_ENV" up -d
echo "  ✓ Redis"

echo "Starting Garage (S3 object store)..."
GARAGE_ENV="$PLATFORM_DIR/infra/garage/.env"
if [ ! -f "$GARAGE_ENV" ]; then
  echo "  ERROR: infra/garage/.env not found."
  echo "  Run: bash $PLATFORM_DIR/scripts/setup-garage.sh"
  exit 1
fi
cd "$PLATFORM_DIR/infra/garage" && docker compose up -d
echo "  ✓ Garage"

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
docker network create monitoring_internal 2>/dev/null || true
cd "$PLATFORM_DIR/infra/logging" && docker compose up -d
echo "  ✓ Loki + Promtail"

echo "Starting Grafana..."
if [ ! -f "$PLATFORM_DIR/infra/monitoring/.env" ]; then
  echo "  ERROR: infra/monitoring/.env not found."
  echo "  Create it with: GRAFANA_HOST, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD"
  exit 1
fi
cd "$PLATFORM_DIR/infra/monitoring" && docker compose -f grafana-compose.yml --env-file .env up -d
echo "  ✓ Grafana"

echo "Starting Verdaccio (npm registry)..."
cd "$PLATFORM_DIR/infra/registry" && docker compose up -d
echo "  ✓ Verdaccio"

echo "Starting Uptime Kuma (status page)..."
if [ ! -f "$PLATFORM_DIR/infra/uptime-kuma/.env" ]; then
  echo "UPTIME_KUMA_HOST=status.$(curl -s ifconfig.me).nip.io" > "$PLATFORM_DIR/infra/uptime-kuma/.env"
fi
cd "$PLATFORM_DIR/infra/uptime-kuma" && docker compose --env-file .env up -d
echo "  ✓ Uptime Kuma"

echo "Starting Umami (web analytics)..."
if [ ! -f "$PLATFORM_DIR/infra/umami/.env" ]; then
  echo "  ERROR: infra/umami/.env not found."
  echo "  Copy infra/umami/.env.example to infra/umami/.env and fill in the values."
  exit 1
fi
cd "$PLATFORM_DIR/infra/umami" && docker compose --env-file .env up -d
echo "  ✓ Umami"

# 5. Set up daily backup cron
CRON_JOB="0 2 * * * $PLATFORM_DIR/scripts/backup.sh >> /var/log/platform-backup.log 2>&1"
(crontab -l 2>/dev/null | grep -qF "platform/scripts/backup.sh") || \
  (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
echo "  ✓ Daily backup cron scheduled at 2am"

VERIFY_JOB="30 2 * * * $PLATFORM_DIR/scripts/verify-backup.sh >> /var/log/platform-backup-verify.log 2>&1"
(crontab -l 2>/dev/null | grep -qF "platform/scripts/verify-backup.sh") || \
  (crontab -l 2>/dev/null; echo "$VERIFY_JOB") | crontab -
echo "  ✓ Daily backup verification scheduled at 2:30am"

RENOVATE_JOB="50 5 * * 1 $PLATFORM_DIR/scripts/renovate.sh >> /var/log/platform-renovate.log 2>&1"
(crontab -l 2>/dev/null | grep -qF "platform/scripts/renovate.sh") || \
  (crontab -l 2>/dev/null; echo "$RENOVATE_JOB") | crontab -
echo "  ✓ Weekly Renovate run scheduled at 5:50am Monday"
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
echo "  https://analytics.homelab.local   → Umami"
echo ""
echo "Next steps:"
echo "  1. Configure DNS: point *.yourdomain.com to this server's IP"
echo "  2. Initialize Garage S3 store:"
echo "       bash $PLATFORM_DIR/scripts/setup-garage.sh"
echo "  3. Deploy services in order:"
echo "       bash $PLATFORM_DIR/scripts/deploy-app.sh auth-service production"
echo "       bash $PLATFORM_DIR/scripts/setup-apps.sh register-finance-tracker"
echo "       bash $PLATFORM_DIR/scripts/deploy-app.sh ai-shim production"
echo "       bash $PLATFORM_DIR/scripts/deploy-app.sh doc-bucket production"
echo "       bash $PLATFORM_DIR/scripts/setup-apps.sh setup-doc-bucket"
echo "       bash $PLATFORM_DIR/scripts/deploy-app.sh email-service production"
echo "       bash $PLATFORM_DIR/scripts/deploy-app.sh paddle-ocr-wrap production"
echo "       bash $PLATFORM_DIR/scripts/deploy-app.sh finance-tracker production"
echo "       bash $PLATFORM_DIR/scripts/setup-apps.sh verify-finance-tracker"
echo "  4. Add API keys (via Infisical or .env):"
echo "       GEMINI_API_KEY  → ai-shim"
echo "       RESEND_API_KEY  → finance-tracker, email-service"
