#!/bin/bash
# Pull latest images and restart all running application stacks.
# Apps are expected to be cloned under ~/apps/<app-name>/

set -euo pipefail

APPS_DIR="${APPS_DIR:-$HOME/apps}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$APPS_DIR" ]; then
  echo "No apps directory found at $APPS_DIR"
  exit 0
fi

echo "=== Updating all stacks in $APPS_DIR ==="

shopt -s nullglob
for compose_file in "$APPS_DIR"/*/docker-compose.yml; do
  app=$(basename "$(dirname "$compose_file")")
  echo ""
  echo "Updating $app..."
  "$SCRIPT_DIR/deploy-app.sh" "$app" production "$compose_file" || echo "  WARNING: Failed to update $app"
done

echo ""
echo "=== Update complete ==="
