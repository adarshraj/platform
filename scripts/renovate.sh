#!/bin/bash
# Run self-hosted Renovate to scan all repos and open dependency update PRs.
# Scheduled weekly by bootstrap.sh (Monday 5:50am).
# Can also be triggered manually: bash ~/platform/scripts/renovate.sh
#
# Renovate reads renovate.json from each repo for per-repo config.
# The global config (autodiscover, token) is set via environment variables here.
#
# Required — create a GitHub PAT with these permissions:
#   Contents: Read & Write   (to push Renovate branches)
#   Pull requests: Read & Write  (to open PRs)
#   Workflows: Read & Write  (to update GitHub Actions files)
#   Metadata: Read-only (always required)
#
# Store it on the VPS:
#   echo "github_pat_xxx" > ~/.config/platform/renovate-token
#   chmod 600 ~/.config/platform/renovate-token

set -euo pipefail

TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/platform/renovate-token}"
LOG_DIR="${LOG_DIR:-$HOME/platform/logs/renovate}"
GITHUB_USER="${GITHUB_USER:-adarshraj}"

# Resolve token
if [ -n "${RENOVATE_TOKEN:-}" ]; then
  TOKEN="$RENOVATE_TOKEN"
elif [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
else
  echo "ERROR: No Renovate token found."
  echo ""
  echo "Create a GitHub PAT with Contents + Pull requests + Workflows (Read & Write), then:"
  echo "  echo 'github_pat_xxx' > ~/.config/platform/renovate-token"
  echo "  chmod 600 ~/.config/platform/renovate-token"
  exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

echo "[$(date)] Starting Renovate run..." | tee -a "$LOG_FILE"

docker run --rm \
  --name renovate \
  -e RENOVATE_TOKEN="$TOKEN" \
  -e RENOVATE_AUTODISCOVER=true \
  -e RENOVATE_AUTODISCOVER_FILTER="$GITHUB_USER/*" \
  -e LOG_LEVEL=info \
  -e RENOVATE_GIT_AUTHOR="Renovate Bot <bot@renovateapp.com>" \
  renovate/renovate:latest \
  2>&1 | tee -a "$LOG_FILE"

echo "[$(date)] Renovate run complete." | tee -a "$LOG_FILE"
