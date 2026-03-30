# ADR 001: Traefik over Nginx as Reverse Proxy

**Status**: Accepted

## Context
We needed a reverse proxy to route traffic to ~19+ services without managing a port-per-service.

## Decision
Use Traefik v3 with Docker label-based routing.

## Reasons
- No config file to maintain per service — routing is declared in the service's own `docker-compose.yml` via labels
- Auto-discovers new services when containers start (Docker provider)
- Native Let's Encrypt/ACME support for public domains
- Built-in metrics endpoint for Prometheus
- Middleware system (rate limiting, IP allowlist, auth forwarding) is composable via labels

## Rejected Alternatives
- **Nginx Proxy Manager**: GUI-based, config not easily version-controlled
- **Caddy**: Good option, but less Docker-native label routing support vs Traefik
- **Raw Nginx**: Requires manual config file per service, no auto-discovery
