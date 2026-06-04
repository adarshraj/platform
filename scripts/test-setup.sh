#!/bin/bash
# Test deployment setup for a fresh VPS with no domain.
# Uses nip.io for hostnames and self-signed HTTPS via test Traefik config.
#
# Usage:
#   bash ~/platform/scripts/test-setup.sh
#
# What this does:
#   1. Installs prerequisites (Docker, etc.)
#   2. Sets up GHCR authentication
#   3. Creates Docker networks
#   4. Starts Redis, Traefik, Garage (S3)
#   5. Clones all service repos
#   6. Generates .env files
#   7. Deploys in dependency order:
#      auth-service → ai-shim → doc-bucket → email-service → paddle-ocr-wrap → finance-tracker
#   8. Registers apps and clients
#   9. Prints URLs and next steps

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

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
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
  if [[ "$USE_EXISTING" =~ ^[Nn]$ ]]; then rm -f "$TOKEN_FILE"; fi
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
  if [[ "$USE_EXISTING_CLONE" =~ ^[Nn]$ ]]; then rm -f "$CLONE_TOKEN_FILE"; fi
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

# ── 3. Docker networks ────────────────────────────────────────────────────────
info "Creating Docker networks..."
bash "$PLATFORM_DIR/infra/networks/create-networks.sh" 2>/dev/null || true
success "Networks ready"

# ── 4. Detect public IP ───────────────────────────────────────────────────────
info "Detecting public IP..."
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "")
if [ -z "$PUBLIC_IP" ]; then
  read -rp "Could not detect IP automatically. Enter your VPS IP: " PUBLIC_IP
fi
success "VPS IP detected"

# ── 5. Start Redis ────────────────────────────────────────────────────────────
REDIS_ENV="$PLATFORM_DIR/infra/redis/.env"
if [ ! -f "$REDIS_ENV" ]; then
  info "Generating Redis password..."
  echo "REDIS_PASSWORD=$(openssl rand -hex 32)" > "$REDIS_ENV"
  success "Redis password generated"
fi
info "Starting Redis..."
docker compose -f "$PLATFORM_DIR/infra/redis/docker-compose.yml" --env-file "$REDIS_ENV" up -d
success "Redis running"

# ── 6. Start test Traefik ─────────────────────────────────────────────────────
info "Starting test Traefik..."
cd "$PLATFORM_DIR/test/traefik"
docker compose up -d
success "Traefik running"

# ── 7. Start Garage (S3-compatible object store) ──────────────────────────────
GARAGE_ENV="$PLATFORM_DIR/infra/garage/.env"
if [ ! -f "$GARAGE_ENV" ]; then
  info "Generating Garage secrets..."
  RPC_SECRET=$(openssl rand -hex 32)
  GARAGE_ADMIN_TOKEN=$(openssl rand -hex 32)
  GARAGE_METRICS_TOKEN=$(openssl rand -hex 32)
  cat > "$GARAGE_ENV" << EOF
RPC_SECRET=$RPC_SECRET
GARAGE_ADMIN_TOKEN=$GARAGE_ADMIN_TOKEN
GARAGE_METRICS_TOKEN=$GARAGE_METRICS_TOKEN
GARAGE_HOST=s3.$PUBLIC_IP.nip.io
EOF

  # Write garage.toml with actual secrets (Garage doesn't support env var substitution in config)
  cat > "$PLATFORM_DIR/infra/garage/garage.toml" << TOML
metadata_dir = "/var/lib/garage/meta"
data_dir     = "/var/lib/garage/data"
db_engine    = "sqlite"

replication_factor = 1

rpc_bind_addr   = "[::]:3901"
rpc_public_addr = "garage:3901"
rpc_secret      = "$RPC_SECRET"

[s3_api]
s3_region     = "garage"
api_bind_addr = "[::]:3900"
root_domain   = ".s3.homelab.local"

[s3_web]
bind_addr   = "[::]:3902"
root_domain = ".web.homelab.local"
index       = "index.html"

[admin]
api_bind_addr  = "[::]:3903"
admin_token    = "$GARAGE_ADMIN_TOKEN"
metrics_token  = "$GARAGE_METRICS_TOKEN"
TOML
  success "Garage secrets generated"
fi

info "Starting Garage..."
docker compose -f "$PLATFORM_DIR/infra/garage/docker-compose.yml" up -d
sleep 5

# Initialize Garage cluster (idempotent — safe to re-run)
info "Initializing Garage cluster..."
NODE_ID=$(docker exec garage /garage node id 2>/dev/null | grep -oE "^[0-9a-f]+" | head -1)
docker exec garage /garage layout assign -z dc1 -c 1G "$NODE_ID" 2>/dev/null || true
docker exec garage /garage layout apply --version 1 2>/dev/null || true
docker exec garage /garage bucket create documents 2>/dev/null || true

# Create access key for doc-bucket (skip if already exists)
KEY_OUTPUT=$(docker exec garage /garage key list 2>/dev/null)
if ! echo "$KEY_OUTPUT" | grep -q "doc-bucket-key"; then
  KEY_OUTPUT=$(docker exec garage /garage key create doc-bucket-key)
  GARAGE_ACCESS_KEY=$(echo "$KEY_OUTPUT" | grep "Key ID" | awk '{print $3}')
  GARAGE_SECRET_KEY=$(echo "$KEY_OUTPUT" | grep "Secret key" | awk '{print $3}')
  docker exec garage /garage bucket allow --read --write --owner documents --key doc-bucket-key 2>/dev/null || true
  echo "GARAGE_ACCESS_KEY=$GARAGE_ACCESS_KEY" >> "$GARAGE_ENV"
  echo "GARAGE_SECRET_KEY=$GARAGE_SECRET_KEY" >> "$GARAGE_ENV"
else
  GARAGE_ACCESS_KEY=$(grep "^GARAGE_ACCESS_KEY=" "$GARAGE_ENV" | cut -d= -f2)
  GARAGE_SECRET_KEY=$(grep "^GARAGE_SECRET_KEY=" "$GARAGE_ENV" | cut -d= -f2)
fi
success "Garage ready"

# ── 8. Clone repos ────────────────────────────────────────────────────────────
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
clone_or_pull paddle-ocr-wrap  adarshraj/paddle-ocr-wrap
clone_or_pull finance-tracker  adarshraj/finance-tracker

# ── 9. Generate .env files ────────────────────────────────────────────────────
info "Generating .env files..."
bash "$PLATFORM_DIR/scripts/gen-env.sh" auth-service    "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" ai-shim         "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" email-service   "$PUBLIC_IP"
bash "$PLATFORM_DIR/scripts/gen-env.sh" finance-tracker "$PUBLIC_IP"

# Doc-bucket .env (uses Garage keys from above)
cat > "$APPS_DIR/doc-bucket/.env" << EOF
DOC_BUCKET_HOST=docbucket.$PUBLIC_IP.nip.io
DOC_BUCKET_AUTH_JWKS_URL=http://auth-service:8703/.well-known/jwks.json
DOC_STORAGE_ENDPOINT=http://garage:3900
DOC_STORAGE_ACCESS_KEY_ID=$GARAGE_ACCESS_KEY
DOC_STORAGE_SECRET_ACCESS_KEY=$GARAGE_SECRET_KEY
DOC_BUCKET_BUCKET=documents
DOC_BUCKET_ADMIN_KEY=$(openssl rand -hex 32)
DOC_BUCKET_KEY_HMAC_SECRET=$(openssl rand -hex 32)
EOF

# Inject AUTH_ADMIN_KEY into finance-tracker (must match auth-service)
AUTH_ADMIN_KEY=$(grep "^AUTH_ADMIN_KEY=" "$APPS_DIR/auth-service/.env" | cut -d= -f2)
echo "AUTH_ADMIN_KEY=$AUTH_ADMIN_KEY" >> "$APPS_DIR/finance-tracker/.env"

success ".env files generated"

# ── 10. Deploy in dependency order ────────────────────────────────────────────
deploy() {
  local name=$1
  local compose=$2
  local app_dir=$3
  info "Deploying $name..."
  docker compose -f "$compose" pull
  docker compose -f "$compose" up -d
  success "$name deployed"
}

deploy auth-service    "$APPS_DIR/auth-service/docker-compose.prod.yml"    "$APPS_DIR/auth-service"

# ── 10b. Register finance-tracker app in auth-service ─────────────────────────
info "Waiting for auth-service to be ready..."
for i in {1..20}; do
  if docker exec auth-service curl -sf http://localhost:8703/q/health/live >/dev/null 2>&1; then break; fi
  sleep 3
done

register_app() {
  local app_id=$1 app_name=$2 redirect_uri=$3
  local admin_key
  admin_key=$(grep "^AUTH_ADMIN_KEY=" "$APPS_DIR/auth-service/.env" | cut -d= -f2)
  local result
  result=$(docker exec auth-service curl -s -X POST http://localhost:8703/auth/apps \
    -H "Content-Type: application/json" \
    -H "X-Admin-Key: $admin_key" \
    -d "{\"id\":\"$app_id\",\"name\":\"$app_name\",\"requiresExplicitAccess\":false,\"redirectUris\":[\"$redirect_uri\"]}")
  echo "$result" | grep -q '"id"' && success "App $app_id registered" || warn "Could not register app $app_id: $result"
}

register_app "finance-tracker" "Finance Tracker" "https://finance.$PUBLIC_IP.nip.io"

deploy ai-shim         "$APPS_DIR/ai-shim/docker-compose.yml"             "$APPS_DIR/ai-shim"
deploy doc-bucket      "$APPS_DIR/doc-bucket/docker-compose.yml"          "$APPS_DIR/doc-bucket"
deploy email-service   "$APPS_DIR/email-service/docker-compose.yml"       "$APPS_DIR/email-service"

# Deploy paddle-ocr-wrap (uses prod compose, no .env needed)
info "Deploying paddle-ocr-wrap..."
docker compose -f "$APPS_DIR/paddle-ocr-wrap/docker-compose.prod.yml" pull
docker compose -f "$APPS_DIR/paddle-ocr-wrap/docker-compose.prod.yml" up -d
success "paddle-ocr-wrap deployed"

# ── 10c. Register finance-tracker as doc-bucket client ────────────────────────
info "Registering finance-tracker client in doc-bucket..."
for i in {1..20}; do
  if docker exec auth-service curl -sf http://doc-bucket:8702/q/health/live >/dev/null 2>&1; then break; fi
  sleep 3
done

DOC_ADMIN_KEY=$(grep "^DOC_BUCKET_ADMIN_KEY=" "$APPS_DIR/doc-bucket/.env" | cut -d= -f2)
DOC_KEY_RESULT=$(docker exec auth-service curl -s -X POST http://doc-bucket:8702/api/clients \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: $DOC_ADMIN_KEY" \
  -d '{"tenantId":"finance-tracker","appId":"prod","label":"Finance Tracker prod"}')

DOC_BUCKET_API_KEY=$(echo "$DOC_KEY_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('apiKey',''))" 2>/dev/null || echo "")
if [ -n "$DOC_BUCKET_API_KEY" ]; then
  sed -i "s/^DOC_BUCKET_API_KEY=.*/DOC_BUCKET_API_KEY=$DOC_BUCKET_API_KEY/" "$APPS_DIR/finance-tracker/.env"
  success "Doc-bucket client registered"
else
  warn "Could not register doc-bucket client: $DOC_KEY_RESULT"
fi

deploy finance-tracker "$APPS_DIR/finance-tracker/docker-compose.yml"    "$APPS_DIR/finance-tracker"

# ── 11. Wait for all services healthy ─────────────────────────────────────────
info "Waiting for services to be healthy..."
for i in {1..40}; do
  healthy=$(docker ps --format "{{.Names}}\t{{.Status}}" | grep -c "healthy" || true)
  if [ "$healthy" -ge 6 ]; then
    success "All services healthy"
    break
  fi
  if [ "$i" -eq 40 ]; then
    warn "Not all services healthy after timeout. Check: docker ps"
  fi
  sleep 3
done

# ── 12. Print summary ─────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "   Test Deployment Complete!"
echo "========================================"
echo ""
echo "  Services running at:"
echo "    Auth service    : https://auth.$PUBLIC_IP.nip.io"
echo "    AI Shim         : https://aishim.$PUBLIC_IP.nip.io"
echo "    Doc Bucket      : https://docbucket.$PUBLIC_IP.nip.io"
echo "    Finance Tracker : https://finance.$PUBLIC_IP.nip.io"
echo ""
echo "  Next steps:"
echo "    1. Add API keys to enable AI and email:"
echo "       GEMINI_API_KEY  → $APPS_DIR/ai-shim/.env"
echo "       RESEND_API_KEY  → $APPS_DIR/finance-tracker/.env"
echo "                        $APPS_DIR/email-service/.env"
echo "       Then restart: docker compose -f <path>/docker-compose.yml up -d"
echo ""
echo "    2. Register at https://finance.$PUBLIC_IP.nip.io/register"
echo "       Verify your email, then sign in"
echo ""
echo "  Useful commands:"
echo "    docker ps                        — check container status"
echo "    docker logs <container-name>     — view logs"
echo "    docker image prune -a --force    — free disk space"
echo ""
