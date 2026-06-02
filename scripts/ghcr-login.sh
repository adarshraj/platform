#!/bin/bash
# Authenticate Docker with GitHub Container Registry (GHCR).
# Required to pull private images built by GitHub Actions.
#
# Credentials are read from (in priority order):
#   1. GHCR_TOKEN env var (set in shell or calling script)
#   2. ~/.config/platform/ghcr-token file (one line: the token)
#
# To create the token:
#   GitHub → Settings → Developer settings → Personal access tokens → Fine-grained
#   Permissions: Packages → Read-only
#   Copy the token and either:
#     export GHCR_TOKEN=<token>                         # session only
#     echo <token> > ~/.config/platform/ghcr-token     # persistent (recommended)
#     chmod 600 ~/.config/platform/ghcr-token

set -euo pipefail

GHCR_USER="${GHCR_USER:-adarshraj}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/platform/ghcr-token}"

# Resolve the token
if [ -n "${GHCR_TOKEN:-}" ]; then
  TOKEN="$GHCR_TOKEN"
elif [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
else
  echo "ERROR: No GHCR token found."
  echo ""
  echo "Create a GitHub fine-grained PAT with Packages: Read-only permission, then:"
  echo "  mkdir -p ~/.config/platform"
  echo "  echo <your-token> > ~/.config/platform/ghcr-token"
  echo "  chmod 600 ~/.config/platform/ghcr-token"
  echo ""
  echo "Or set the GHCR_TOKEN environment variable."
  exit 1
fi

echo "$TOKEN" | docker login ghcr.io --username "$GHCR_USER" --password-stdin
echo "  ✓ Authenticated with ghcr.io as $GHCR_USER"
