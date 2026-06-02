#!/bin/bash
# Deploy or update a single application stack.
# Usage: ./scripts/deploy-app.sh <app-name> <env> [compose-file-path]
#
# Examples:
#   ./scripts/deploy-app.sh bookshelf-haven production
#   ./scripts/deploy-app.sh auth-service production ~/apps/auth-service/docker-compose.yml
#
# Flags:
#   --allow-empty-secrets   Continue deployment even if Infisical secrets cannot be fetched.
#                           Use only when you have confirmed the app does not need injected secrets.

set -euo pipefail
umask 077

ALLOW_EMPTY_SECRETS=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --allow-empty-secrets) ALLOW_EMPTY_SECRETS=true ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

APP="${1:-}"
ENV="${2:-production}"
COMPOSE_FILE="${3:-}"

if [ -z "$APP" ]; then
  echo "Usage: $0 [--allow-empty-secrets] <app-name> <env> [compose-file-path]"
  exit 1
fi

# Default compose file location (assumes apps are cloned to ~/apps/<app-name>)
if [ -z "$COMPOSE_FILE" ]; then
  COMPOSE_FILE="$HOME/apps/$APP/docker-compose.yml"
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: docker-compose.yml not found at $COMPOSE_FILE"
  echo "Clone the app repo to ~/apps/$APP or pass the path as a third argument."
  exit 1
fi

echo "Deploying $APP ($ENV)..."

# Fetch secrets from Infisical if CLI is available.
# By default, failure is fatal to prevent deploying with missing secrets.
# Pass --allow-empty-secrets to override.
ENV_FILE="$(mktemp /tmp/platform-deploy-${APP}.XXXXXX.env)"
INFISICAL_ERR_FILE="$(mktemp /tmp/infisical-err-${APP}.XXXXXX.log)"
cleanup() {
  rm -f "$ENV_FILE" "$INFISICAL_ERR_FILE"
}
trap cleanup EXIT INT TERM
if command -v infisical &>/dev/null; then
  echo "  Fetching secrets from Infisical..."
  if ! infisical export --env="$ENV" --projectName="$APP" --format=dotenv > "$ENV_FILE" 2>"$INFISICAL_ERR_FILE"; then
    if [ -s "$INFISICAL_ERR_FILE" ]; then
      while IFS= read -r line; do
        echo "$line" >&2
      done < "$INFISICAL_ERR_FILE"
    fi
    if [ "$ALLOW_EMPTY_SECRETS" = "true" ]; then
      echo "  Warning: Could not fetch secrets from Infisical. Continuing with empty env (--allow-empty-secrets set)."
      : > "$ENV_FILE"
    else
      echo "  ERROR: Could not fetch secrets from Infisical. Aborting deploy."
      echo "  To deploy without secrets, pass --allow-empty-secrets."
      exit 1
    fi
  fi
else
  if [ "$ALLOW_EMPTY_SECRETS" = "true" ]; then
    echo "  Warning: Infisical CLI not installed. Continuing with empty env (--allow-empty-secrets set)."
    : > "$ENV_FILE"
  else
    echo "  ERROR: Infisical CLI not installed. Aborting deploy."
    echo "  Install infisical or pass --allow-empty-secrets to override."
    exit 1
  fi
fi

# Ensure GHCR credentials are fresh before pulling private images
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/ghcr-login.sh" 2>/dev/null; then
  : # authenticated
else
  echo "  WARNING: GHCR login failed — pull may fail for private images."
fi

# Pull latest images
echo "  Pulling latest images..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

# Start / restart the stack
echo "  Starting stack..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --remove-orphans

echo "  ✓ $APP deployed."
