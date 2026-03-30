# Service Catalog

Authoritative registry of all services. Every service must be registered here before deployment.
Update this file when adding, renaming, or retiring a service.

## Subdomain Convention
All services are accessible via `<name>.homelab.local` (internal) or `<name>.yourdomain.com` (public SaaS).

---

## Platform Infrastructure

| Service | Subdomain | Internal Port | Stack Dir |
|---|---|---|---|
| Traefik | traefik.homelab.local | 80, 443 | infra/traefik |
| Portainer | portainer.homelab.local | 9000 | infra/portainer |
| Grafana | monitoring.homelab.local | 3000 | infra/monitoring |
| Prometheus | — (internal) | 9090 | infra/monitoring |
| Loki | — (internal) | 3100 | infra/logging |
| Infisical | secrets.homelab.local | 8080 | infra/secrets |
| Verdaccio | npm.homelab.local | 4873 | infra/registry |

---

## Shared Services (CursorProjects)

| Service | Subdomain | Internal Port | Repo | Depends On |
|---|---|---|---|---|
| auth-service | auth.homelab.local | 8703 | CursorProjects/auth-service | postgres |
| ai-wrap | aiwrap.homelab.local | 8704 | CursorProjects/ai-wrap | postgres |
| DocBucket | docbucket.homelab.local | 8705 | CursorProjects/DocBucket | postgres |

---

## ConvertedNut Applications

| Service | Subdomain | Frontend Port | Backend Port | Repo | Depends On |
|---|---|---|---|---|
| bookshelf-haven | bookshelf.homelab.local | 3000 | 8080 | ConvertedNutProjects/bookshelf-haven | auth-service, docbucket, ai-wrap |
| vahan-track | vahan.homelab.local | 3000 | 8080 | ConvertedNutProjects/vahan-track | auth-service |
| family-roots | family-roots.homelab.local | 3000 | 8080 | ConvertedNutProjects/family-roots | auth-service |
| family-vitals | family-vitals.homelab.local | 3000 | 8080 | ConvertedNutProjects/family-vitals | auth-service |
| family-vitals-vault | vitals-vault.homelab.local | 3000 | 8080 | ConvertedNutProjects/family-vitals-vault | auth-service |
| F1Pulse | f1pulse.homelab.local | 3000 | — | ConvertedNutProjects/F1Pulse | — |
| finance-tracker | finance.homelab.local | 3000 | — | ConvertedNutProjects/finance-tracker | auth-service |
| family-health-tracker | family-health.homelab.local | 3000 | — | ConvertedNutProjects/family-health-tracker | — |
| vuln-monitor | vuln.homelab.local | 3000 | — | ConvertedNutProjects/vuln-monitor | — |

---

## Cursor Utilities

| Service | Subdomain | Internal Port | Repo |
|---|---|---|---|
| ShortCutCommands | shortcuts.homelab.local | 3000 | CursorProjects/ShortCutCommands |
| Upstarter | upstarter.homelab.local | 3000 | CursorProjects/Upstarter |
| LaunchTracker | launchtracker.homelab.local | 3000 | CursorProjects/LaunchTracker |
| Launchpad | launchpad.homelab.local | 3000 | CursorProjects/Launchpad |
| Wishlister | wishlister.homelab.local | 3000 | CursorProjects/Wishlister |
| HeicConvert | heicconvert.homelab.local | 3000 | CursorProjects/HeicConvert |
| Difference | difference.homelab.local | 3000 | CursorProjects/Difference |

---

## Port Conventions

| Range | Purpose |
|---|---|
| 80 / 443 | Traefik ingress only (never used by apps) |
| 3000 | SvelteKit / React / Node.js frontends |
| 4000 | Alternative frontend port (Vite dev) |
| 8080 | Quarkus backends (default) |
| 8703 | auth-service (fixed, existing) |
| 8704 | ai-wrap (fixed, existing) |
| 8705 | DocBucket (fixed, existing) |
| 5432 | PostgreSQL (internal Docker network only) |
| 6379 | Redis (internal Docker network only) |

**Rule**: App containers must use `expose:` not `ports:`. Only Traefik uses `ports:`.
