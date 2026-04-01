#!/bin/bash
# Run once on a fresh VPS to create shared Docker networks.
# All subsequent docker-compose stacks reference these as external networks.

set -e

echo "Creating shared Docker networks..."

docker network create platform_proxy 2>/dev/null && echo "  ✓ platform_proxy" || echo "  - platform_proxy already exists"
docker network create monitoring_internal 2>/dev/null && echo "  ✓ monitoring_internal" || echo "  - monitoring_internal already exists"
docker network create socket_proxy 2>/dev/null && echo "  ✓ socket_proxy" || echo "  - socket_proxy already exists"

echo "Done."
