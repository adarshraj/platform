#!/bin/bash
# One-time Garage (S3) initialization. Run after bootstrap.sh starts Garage.
# Idempotent — safe to re-run, skips already-created resources.
#
# Usage: bash ~/platform/scripts/setup-garage.sh

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GARAGE_ENV="$PLATFORM_DIR/infra/garage/.env"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
info()    { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }

# ── Generate secrets if not already done ──────────────────────────────────────
if [ ! -f "$GARAGE_ENV" ]; then
  info "Generating Garage secrets..."
  RPC_SECRET=$(openssl rand -hex 32)
  GARAGE_ADMIN_TOKEN=$(openssl rand -hex 32)
  GARAGE_METRICS_TOKEN=$(openssl rand -hex 32)

  cat > "$GARAGE_ENV" << EOF
RPC_SECRET=$RPC_SECRET
GARAGE_ADMIN_TOKEN=$GARAGE_ADMIN_TOKEN
GARAGE_METRICS_TOKEN=$GARAGE_METRICS_TOKEN
EOF

  # Write garage.toml with actual values (Garage doesn't expand env vars in config)
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
  success "Garage secrets written to $GARAGE_ENV"
fi

# ── Wait for Garage to be ready ───────────────────────────────────────────────
info "Waiting for Garage to be ready..."
for i in {1..20}; do
  if docker exec garage curl -sf http://localhost:3903/health >/dev/null 2>&1; then break; fi
  sleep 3
done

# ── Initialize cluster layout ─────────────────────────────────────────────────
info "Initializing Garage cluster layout..."
NODE_ID=$(docker exec garage /garage node id 2>/dev/null | grep -oE "^[0-9a-f]+" | head -1)
docker exec garage /garage layout assign -z dc1 -c 10G "$NODE_ID" 2>/dev/null || true
docker exec garage /garage layout apply --version 1 2>/dev/null || true
success "Cluster layout applied"

# ── Create documents bucket ───────────────────────────────────────────────────
info "Creating documents bucket..."
docker exec garage /garage bucket create documents 2>/dev/null || true
success "Bucket ready"

# ── Create doc-bucket access key ─────────────────────────────────────────────
if ! grep -q "^GARAGE_ACCESS_KEY=" "$GARAGE_ENV" 2>/dev/null; then
  info "Creating doc-bucket access key..."
  KEY_OUTPUT=$(docker exec garage /garage key create doc-bucket-key)
  GARAGE_ACCESS_KEY=$(echo "$KEY_OUTPUT" | grep "Key ID"    | awk '{print $3}')
  GARAGE_SECRET_KEY=$(echo "$KEY_OUTPUT" | grep "Secret key" | awk '{print $3}')
  docker exec garage /garage bucket allow --read --write --owner documents --key doc-bucket-key 2>/dev/null || true
  echo "GARAGE_ACCESS_KEY=$GARAGE_ACCESS_KEY" >> "$GARAGE_ENV"
  echo "GARAGE_SECRET_KEY=$GARAGE_SECRET_KEY" >> "$GARAGE_ENV"
  success "Access key created and saved to $GARAGE_ENV"
else
  success "Access key already exists in $GARAGE_ENV"
fi

echo ""
echo "Garage is ready. Access key saved to: $GARAGE_ENV"
echo "Use these values in doc-bucket .env:"
echo "  DOC_STORAGE_ENDPOINT=http://garage:3900"
echo "  DOC_STORAGE_ACCESS_KEY_ID=$(grep '^GARAGE_ACCESS_KEY=' "$GARAGE_ENV" | cut -d= -f2)"
echo "  DOC_STORAGE_SECRET_ACCESS_KEY=$(grep '^GARAGE_SECRET_KEY=' "$GARAGE_ENV" | cut -d= -f2)"
