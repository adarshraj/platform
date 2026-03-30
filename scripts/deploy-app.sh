#!/bin/bash
# Deploy or update a single application stack.
# Usage: ./scripts/deploy-app.sh <app-name> <env> [compose-file-path]
#
# Examples:
#   ./scripts/deploy-app.sh bookshelf-haven production
#   ./scripts/deploy-app.sh auth-service production ~/apps/auth-service/docker-compose.yml

set -euo pipefail

APP="${1:-}"
ENV="${2:-production}"
COMPOSE_FILE="${3:-}"

if [ -z "$APP" ]; then
  echo "Usage: $0 <app-name> <env> [compose-file-path]"
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

# Fetch secrets from Infisical if CLI is available
ENV_FILE="/tmp/platform-deploy-$APP-$$.env"
if command -v infisical &>/dev/null; then
  echo "  Fetching secrets from Infisical..."
  infisical export --env="$ENV" --projectName="$APP" --format=dotenv > "$ENV_FILE" 2>/dev/null || {
    echo "  Warning: Could not fetch secrets from Infisical. Deploying without injected secrets."
    touch "$ENV_FILE"
  }
else
  echo "  Warning: Infisical CLI not installed. Deploying without injected secrets."
  touch "$ENV_FILE"
fi

# Pull latest images
echo "  Pulling latest images..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

# Start / restart the stack
echo "  Starting stack..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --remove-orphans

# Clean up temp env file
rm -f "$ENV_FILE"

echo "  ✓ $APP deployed."
