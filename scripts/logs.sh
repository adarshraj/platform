#!/bin/bash
# Tail logs for an application stack.
# Usage: ./scripts/logs.sh <app-name> [service]
#
# Examples:
#   ./scripts/logs.sh bookshelf-haven
#   ./scripts/logs.sh bookshelf-haven backend

set -euo pipefail

APP="${1:-}"
SERVICE="${2:-}"
APPS_DIR="${APPS_DIR:-$HOME/apps}"

if [ -z "$APP" ]; then
  echo "Usage: $0 <app-name> [service]"
  echo ""
  echo "Available apps:"
  ls "$APPS_DIR" 2>/dev/null || echo "  No apps found in $APPS_DIR"
  exit 1
fi

COMPOSE_FILE="$APPS_DIR/$APP/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: $COMPOSE_FILE not found"
  exit 1
fi

echo "Tailing logs for $APP${SERVICE:+ ($SERVICE)}... (Ctrl+C to stop)"
echo ""

docker compose -f "$COMPOSE_FILE" logs -f --tail=100 $SERVICE
