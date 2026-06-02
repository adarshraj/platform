#!/bin/bash
# Clone or pull all app repos listed in services.yaml.
# Run this on a fresh VPS after bootstrap, or after migrating to a new server.
#
# Usage:
#   ./scripts/clone-apps.sh                  # clone/pull all (shared_services + apps + utilities)
#   ./scripts/clone-apps.sh shared           # only shared_services
#   ./scripts/clone-apps.sh apps             # only apps
#   ./scripts/clone-apps.sh utilities        # only utilities
#   ./scripts/clone-apps.sh auth-service     # single app by name
#
# Env vars:
#   APPS_DIR   — where to clone repos (default: ~/apps)
#   GITHUB_URL — base URL (default: https://github.com)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICES_YAML="$PLATFORM_DIR/services.yaml"
APPS_DIR="${APPS_DIR:-$HOME/apps}"
GITHUB_URL="${GITHUB_URL:-https://github.com}"
FILTER="${1:-all}"

if [ ! -f "$SERVICES_YAML" ]; then
  echo "ERROR: services.yaml not found at $SERVICES_YAML"
  exit 1
fi

# Use python3 to parse YAML (universally available on Ubuntu/Debian VPS)
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to parse services.yaml"
  exit 1
fi

mkdir -p "$APPS_DIR"

# Extract name + repo pairs from the requested sections
PAIRS=$(python3 - "$SERVICES_YAML" "$FILTER" <<'PYEOF'
import sys, json

# Minimal YAML parser for our specific structure (avoids PyYAML dependency)
# Falls back to PyYAML if available for correctness
yaml_file = sys.argv[1]
section_filter = sys.argv[2]

try:
    import yaml
    with open(yaml_file) as f:
        data = yaml.safe_load(f)
except ImportError:
    # Fallback: parse manually — handles the flat key:value lines we use
    data = {}
    current_section = None
    current_item = {}
    with open(yaml_file) as f:
        for line in f:
            stripped = line.rstrip()
            if not stripped or stripped.lstrip().startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            if indent == 0 and stripped.endswith(':'):
                if current_section and current_item:
                    data.setdefault(current_section, []).append(current_item)
                current_section = stripped[:-1]
                current_item = {}
                data[current_section] = []
            elif indent == 2 and stripped.startswith('- name:'):
                if current_item:
                    data.setdefault(current_section, []).append(current_item)
                current_item = {'name': stripped.split(':', 1)[1].strip()}
            elif indent == 4 and ':' in stripped and current_item is not None:
                key, val = stripped.split(':', 1)
                current_item[key.strip()] = val.strip()
        if current_section and current_item:
            data.setdefault(current_section, []).append(current_item)

# Sections that contain deployable apps (skip 'platform' — lives in this repo)
deployable = ['shared_services', 'apps', 'utilities']

sections_to_process = []
if section_filter in ('all', 'shared', 'shared_services'):
    sections_to_process.append('shared_services')
if section_filter in ('all', 'apps'):
    sections_to_process.append('apps')
if section_filter in ('all', 'utilities'):
    sections_to_process.append('utilities')

# If filter matches none of the above, treat it as a single app name
single_app = section_filter not in ('all', 'shared', 'shared_services', 'apps', 'utilities')

for section in (deployable if single_app else sections_to_process):
    for item in data.get(section, []):
        name = item.get('name', '')
        repo = item.get('repo', '')
        if not name or not repo:
            continue
        if single_app and name != section_filter:
            continue
        print(f"{name} {repo}")
PYEOF
)

if [ -z "$PAIRS" ]; then
  echo "No matching apps found for filter: $FILTER"
  exit 0
fi

CLONED=0
PULLED=0
FAILED=0

echo "=== Clone/pull apps to $APPS_DIR ==="
echo ""

while IFS=' ' read -r name repo; do
  target="$APPS_DIR/$name"
  url="$GITHUB_URL/$repo.git"

  if [ -d "$target/.git" ]; then
    echo "↑  $name — already cloned, pulling latest..."
    if git -C "$target" pull --ff-only 2>&1 | sed 's/^/   /'; then
      PULLED=$((PULLED + 1))
    else
      echo "   WARNING: pull failed, skipping"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "↓  $name — cloning from $url..."
    if git clone "$url" "$target" 2>&1 | sed 's/^/   /'; then
      CLONED=$((CLONED + 1))
    else
      echo "   WARNING: clone failed, skipping"
      FAILED=$((FAILED + 1))
    fi
  fi
  echo ""
done <<< "$PAIRS"

echo "=== Done ==="
echo "  Cloned: $CLONED  |  Pulled: $PULLED  |  Failed: $FAILED"
echo ""
echo "Next: deploy an app with  ./scripts/deploy-app.sh <app-name> production"
