#!/bin/bash
# App-specific post-deploy setup. Run after deploy-app.sh for each service.
# Handles registrations, env injections, and cross-service wiring that
# deploy-app.sh (which is generic) cannot do on its own.
#
# Usage: bash ~/platform/scripts/setup-apps.sh <step>
#
# Steps (run in this order after deploying each service):
#   register-finance-tracker   — register finance-tracker app in auth-service
#   setup-doc-bucket           — register finance-tracker client in doc-bucket,
#                                inject DOC_BUCKET_API_KEY into finance-tracker env
#   verify-finance-tracker     — check all services visible in finance-tracker health
#
# Example full flow:
#   deploy-app.sh auth-service production
#   setup-apps.sh register-finance-tracker
#   deploy-app.sh ai-shim production
#   deploy-app.sh doc-bucket production
#   setup-apps.sh setup-doc-bucket
#   deploy-app.sh email-service production
#   deploy-app.sh paddle-ocr-wrap production
#   deploy-app.sh finance-tracker production
#   setup-apps.sh verify-finance-tracker

set -euo pipefail

APPS_DIR="$HOME/apps"
STEP="${1:-}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()    { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }

wait_for() {
  local container=$1 url=$2
  info "Waiting for $container..."
  for i in {1..20}; do
    if docker exec auth-service curl -sf "$url" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  warn "$container did not become ready in time"
}

case "$STEP" in

  register-finance-tracker)
    # Register finance-tracker as an app in auth-service.
    # Must run after auth-service is deployed and healthy.
    # Also injects AUTH_ADMIN_KEY and AUTH_JWT_ISSUER into finance-tracker .env.

    wait_for auth-service "http://localhost:8703/q/health/live"

    ADMIN_KEY=$(grep "^AUTH_ADMIN_KEY=" "$APPS_DIR/auth-service/.env" | cut -d= -f2)
    AUTH_BASE_URL=$(grep "^AUTH_BASE_URL=" "$APPS_DIR/auth-service/.env" | cut -d= -f2)
    FINANCE_HOST=$(grep "^FINANCE_HOST=" "$APPS_DIR/finance-tracker/.env" | cut -d= -f2)

    info "Registering finance-tracker app in auth-service..."
    RESULT=$(docker exec auth-service curl -s -X POST http://localhost:8703/auth/apps \
      -H "Content-Type: application/json" \
      -H "X-Admin-Key: $ADMIN_KEY" \
      -d "{\"id\":\"finance-tracker\",\"name\":\"Finance Tracker\",\"requiresExplicitAccess\":false,\"redirectUris\":[\"https://$FINANCE_HOST\"]}")
    echo "$RESULT" | grep -q '"id"' && success "finance-tracker registered in auth-service" || warn "Registration response: $RESULT"

    # Inject AUTH_ADMIN_KEY into finance-tracker .env if missing
    if ! grep -q "^AUTH_ADMIN_KEY=" "$APPS_DIR/finance-tracker/.env" 2>/dev/null; then
      echo "AUTH_ADMIN_KEY=$ADMIN_KEY" >> "$APPS_DIR/finance-tracker/.env"
      success "AUTH_ADMIN_KEY injected into finance-tracker .env"
    fi

    # Inject AUTH_JWT_ISSUER (= AUTH_BASE_URL from auth-service) — critical for JWT verification
    if ! grep -q "^AUTH_JWT_ISSUER=" "$APPS_DIR/finance-tracker/.env" 2>/dev/null; then
      echo "AUTH_JWT_ISSUER=$AUTH_BASE_URL" >> "$APPS_DIR/finance-tracker/.env"
      success "AUTH_JWT_ISSUER injected into finance-tracker .env"
    fi
    ;;

  setup-doc-bucket)
    # Register finance-tracker as a client in doc-bucket.
    # Must run after doc-bucket is deployed and healthy.
    # Injects DOC_BUCKET_API_KEY into finance-tracker .env.

    wait_for doc-bucket "http://doc-bucket:8702/q/health/live"

    DOC_ADMIN_KEY=$(grep "^DOC_BUCKET_ADMIN_KEY=" "$APPS_DIR/doc-bucket/.env" | cut -d= -f2)

    info "Registering finance-tracker client in doc-bucket..."
    RESULT=$(docker exec auth-service curl -s -X POST http://doc-bucket:8702/api/clients \
      -H "Content-Type: application/json" \
      -H "X-Admin-Key: $DOC_ADMIN_KEY" \
      -d '{"tenantId":"finance-tracker","appId":"prod","label":"Finance Tracker prod"}')

    DOC_API_KEY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('apiKey',''))" 2>/dev/null || echo "")

    if [ -n "$DOC_API_KEY" ]; then
      if grep -q "^DOC_BUCKET_API_KEY=" "$APPS_DIR/finance-tracker/.env" 2>/dev/null; then
        sed -i "s|^DOC_BUCKET_API_KEY=.*|DOC_BUCKET_API_KEY=$DOC_API_KEY|" "$APPS_DIR/finance-tracker/.env"
      else
        echo "DOC_BUCKET_API_KEY=$DOC_API_KEY" >> "$APPS_DIR/finance-tracker/.env"
      fi
      success "DOC_BUCKET_API_KEY injected into finance-tracker .env"
    else
      warn "Could not register doc-bucket client: $RESULT"
    fi
    ;;

  verify-finance-tracker)
    # Check finance-tracker health endpoint to confirm all services are wired up.
    info "Checking finance-tracker service health..."
    HEALTH=$(docker exec finance-tracker-app-1 wget -qO- http://localhost:3000/api/health 2>/dev/null || echo "{}")
    echo "$HEALTH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Overall: {d.get(\"status\", \"unknown\")}')
for k, v in d.get('services', {}).items():
    icon = '✓' if v['status'] == 'up' else '✗' if v['status'] == 'down' else '-'
    print(f'  {icon} {v.get(\"label\", k)}: {v[\"status\"]}')
" 2>/dev/null || echo "$HEALTH"
    ;;

  *)
    echo "Usage: $0 <step>"
    echo ""
    echo "Steps:"
    echo "  register-finance-tracker   — after deploying auth-service"
    echo "  setup-doc-bucket           — after deploying doc-bucket"
    echo "  verify-finance-tracker     — after deploying finance-tracker"
    exit 1
    ;;
esac
