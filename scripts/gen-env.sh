#!/bin/bash
# Generate .env files for test deployments.
# Usage: bash ~/platform/scripts/gen-env.sh <app-name> <vps-ip>
#
# Examples:
#   bash ~/platform/scripts/gen-env.sh auth-service 65.20.74.236
#   bash ~/platform/scripts/gen-env.sh ai-shim 65.20.74.236
#   bash ~/platform/scripts/gen-env.sh finance-tracker 65.20.74.236

set -euo pipefail

APP="${1:-}"
IP="${2:-}"

if [ -z "$APP" ]; then
  echo "Usage: $0 <app-name> [vps-ip]"
  echo ""
  echo "Available apps: auth-service, ai-shim, doc-bucket, email-service, finance-tracker"
  exit 1
fi

if [ -z "$IP" ]; then
  read -rp "Enter your VPS IP: " IP
fi

APPS_DIR="${APPS_DIR:-$HOME/apps}"
ENV_FILE="$APPS_DIR/$APP/.env"
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read Redis password from platform redis .env if it exists
REDIS_ENV="$PLATFORM_DIR/infra/redis/.env"
if [ -f "$REDIS_ENV" ]; then
  REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" "$REDIS_ENV" | cut -d= -f2)
else
  REDIS_PASSWORD=""
fi
REDIS_URL="redis://${REDIS_PASSWORD:+:$REDIS_PASSWORD@}redis:6379"

if [ ! -d "$APPS_DIR/$APP" ]; then
  echo "ERROR: $APPS_DIR/$APP not found. Clone it first:"
  echo "  git clone https://github.com/adarshraj/$APP ~/apps/$APP"
  exit 1
fi

s() { openssl rand -hex 32; }

case "$APP" in

  auth-service)
    cat > "$ENV_FILE" << EOF
AUTH_KEY_HMAC_SECRET=$(s)
AUTH_STATE_HMAC_SECRET=$(s)
AUTH_TOKEN_PEPPER=$(s)
AUTH_MFA_HMAC_SECRET=$(s)
AUTH_DB_PASSPHRASE=$(s)
AUTH_ADMIN_KEY=$(s)
AUTH_BASE_URL=http://auth.$IP.nip.io
AUTH_SERVICE_HOST=auth.$IP.nip.io
AUTH_SESSION_COOKIE_DOMAIN=
AUTH_JWT_EXPIRY_SECONDS=900
AUTH_REFRESH_TOKEN_EXPIRY_SECONDS=604800
AUTH_RATE_LIMIT_ENABLED=true
AUTH_RATE_LIMIT_RPM=60
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
EOF
    ;;

  ai-shim)
    cat > "$ENV_FILE" << EOF
AUTH_SERVICE_URL=http://auth-service:8703
AI_SHIM_HOST=aishim.$IP.nip.io
AI_SHIM_ALLOWED_ORIGIN=http://finance.$IP.nip.io
AI_SHIM_RATE_LIMIT_RPM=30
AI_SHIM_RATE_LIMIT_RPD=1000
AI_SHIM_MAX_UPLOAD_BYTES=20971520
REDIS_URL=$REDIS_URL
OPENAI_API_KEY=DISABLED
GEMINI_API_KEY=DISABLED
ANTHROPIC_API_KEY=DISABLED
DEEPSEEK_API_KEY=DISABLED
EOF
    ;;

  doc-bucket)
    cat > "$ENV_FILE" << EOF
DOC_BUCKET_HOST=docbucket.$IP.nip.io
DOC_BUCKET_AUTH_JWKS_URL=http://auth-service:8703/.well-known/jwks.json
DOC_STORAGE_ENDPOINT=http://garage:3900
DOC_STORAGE_ACCESS_KEY_ID=test
DOC_STORAGE_SECRET_ACCESS_KEY=test
DOC_BUCKET_BUCKET=documents
DOC_BUCKET_ADMIN_KEY=$(s)
DOC_BUCKET_KEY_HMAC_SECRET=$(s)
EOF
    ;;

  email-service)
    cat > "$ENV_FILE" << EOF
EMAIL_SERVICE_HOST=mail.$IP.nip.io
AUTH_SERVICE_URL=http://auth-service:8703
EMAIL_ALLOWED_ORIGIN=http://finance.$IP.nip.io
EMAIL_PROVIDER=resend
RESEND_API_KEY=re_test_placeholder
EMAIL_DEFAULT_FROM=noreply@example.com
REDIS_URL=$REDIS_URL
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
EOF
    ;;

  finance-tracker)
    POSTGRES_PASSWORD=$(s)
    # Read AUTH_ADMIN_KEY from auth-service .env so finance-tracker can call auth-service admin endpoints
    AUTH_ADMIN_KEY_VAL=""
    AUTH_SERVICE_ENV="$APPS_DIR/auth-service/.env"
    if [ -f "$AUTH_SERVICE_ENV" ]; then
      AUTH_ADMIN_KEY_VAL=$(grep "^AUTH_ADMIN_KEY=" "$AUTH_SERVICE_ENV" | cut -d= -f2)
    fi
    cat > "$ENV_FILE" << EOF
FINANCE_HOST=finance.$IP.nip.io
PUBLIC_BASE_URL=https://finance.$IP.nip.io
AUTH_SERVICE_URL=http://auth-service:8703
AUTH_JWT_ISSUER=http://auth.$IP.nip.io
AI_SHIM_URL=http://ai-shim:8090
AUTH_APP_ID=finance-tracker
AUTH_ADMIN_KEY=$AUTH_ADMIN_KEY_VAL
POSTGRES_USER=finuser
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=finance_tracker
DATABASE_URL=postgresql://finuser:$POSTGRES_PASSWORD@db:5432/finance_tracker
CRON_SECRET=$(s)

# Email verification — Resend test mode only sends to the account owner email
RESEND_API_KEY=
EMAIL_FROM=onboarding@resend.dev

# Doc-bucket (set after registering finance-tracker client via doc-bucket admin API)
DOC_BUCKET_URL=http://doc-bucket:8702
DOC_BUCKET_API_KEY=
DOC_BUCKET_TENANT_ID=finance-tracker
DOC_BUCKET_APP_ID=prod
EOF
    ;;

  *)
    echo "ERROR: Unknown app '$APP'"
    echo "Available: auth-service, ai-shim, doc-bucket, email-service, finance-tracker"
    exit 1
    ;;
esac

echo "✓ Generated $ENV_FILE"
cat "$ENV_FILE"
