#!/bin/bash
# Lint platform config files locally before committing.
# Install dependencies: sudo apt install yamllint shellcheck

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PLATFORM_DIR"

ERRORS=0

echo "=== Platform Lint ==="

# --- YAML lint ---
echo ""
echo "Checking YAML files..."
YAML_FILES=(
  services.yaml
  infra/monitoring/prometheus.yml
  infra/monitoring/alerts.yml
  infra/monitoring/blackbox.yml
  infra/logging/promtail-config.yml
  infra/traefik/traefik.yml
)
for f in "${YAML_FILES[@]}"; do
  if [ -f "$f" ]; then
    if yamllint -d "{extends: relaxed, rules: {line-length: {max: 200}, truthy: disable}}" "$f" 2>&1; then
      echo "  ✓ $f"
    else
      echo "  ✗ $f"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

# --- Shellcheck ---
echo ""
echo "Checking shell scripts..."
for f in scripts/*.sh; do
  if shellcheck "$f" 2>&1; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f"
    ERRORS=$((ERRORS + 1))
  fi
done

# --- Docker Compose validation ---
echo ""
echo "Validating Docker Compose files..."
for dir in infra/*/; do
  if [ -f "$dir/docker-compose.yml" ]; then
    if docker compose -f "$dir/docker-compose.yml" config --quiet 2>/dev/null; then
      echo "  ✓ $dir"
    else
      echo "  ✗ $dir"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "Lint failed with $ERRORS error(s)."
  exit 1
else
  echo "All checks passed."
fi
