# Service Catalog

Authoritative registry of all services. Every service must be registered here before deployment.
Update this file when adding, renaming, or retiring a service.

## Subdomain Convention
All services are accessible via `<name>.homelab.local` (internal) or `<name>.yourdomain.com` (public SaaS).

---

## Platform Infrastructure

| Service | Subdomain | Internal Port | Stack Dir | Status |
|---|---|---|---|---|
| Traefik | traefik.homelab.local | 80, 443 | infra/traefik | active |
| Portainer | portainer.homelab.local | 9000 | infra/portainer | active |
| Grafana | monitoring.homelab.local | 3000 | infra/monitoring | active |
| Prometheus | — (internal) | 9090 | infra/monitoring | active |
| Loki | — (internal) | 3100 | infra/logging | active |
| Infisical | secrets.homelab.local | 8080 | infra/secrets | active |
| Verdaccio | npm.homelab.local | 4873 | infra/registry | active |

---

## Shared Services (CursorProjects)

| Service | Subdomain | Internal Port | Repo | Depends On | Status |
|---|---|---|---|---|---|
| auth-service | auth.homelab.local | 8703 | CursorProjects/auth-service | postgres | pending |
| ai-wrap | aiwrap.homelab.local | 8704 | CursorProjects/ai-wrap | postgres | pending |
| DocBucket | docbucket.homelab.local | 8705 | CursorProjects/DocBucket | postgres | pending |

---

## ConvertedNut Applications

| Service | Subdomain | Frontend Port | Backend Port | Repo | Depends On | Status |
|---|---|---|---|---|---|---|
| bookshelf-haven | bookshelf.homelab.local | 3000 | 8080 | ConvertedNutProjects/bookshelf-haven | auth-service, docbucket, ai-wrap | pending |
| vahan-track | vahan.homelab.local | 3000 | 8080 | ConvertedNutProjects/vahan-track | auth-service | pending |
| family-roots | family-roots.homelab.local | 3000 | 8080 | ConvertedNutProjects/family-roots | auth-service | pending |
| family-vitals | family-vitals.homelab.local | 3000 | 8080 | ConvertedNutProjects/family-vitals | auth-service | pending |
| family-vitals-vault | vitals-vault.homelab.local | 3000 | 8080 | ConvertedNutProjects/family-vitals-vault | auth-service | pending |
| F1Pulse | f1pulse.homelab.local | 3000 | — | ConvertedNutProjects/F1Pulse | — | pending |
| finance-tracker | finance.homelab.local | 3000 | — | ConvertedNutProjects/finance-tracker | auth-service | pending |
| family-health-tracker | family-health.homelab.local | 3000 | — | ConvertedNutProjects/family-health-tracker | — | pending |
| vuln-monitor | vuln.homelab.local | 3000 | — | ConvertedNutProjects/vuln-monitor | — | pending |

---

## Cursor Utilities

| Service | Subdomain | Internal Port | Repo | Status |
|---|---|---|---|---|
| ShortCutCommands | shortcuts.homelab.local | 3000 | CursorProjects/ShortCutCommands | pending |
| Upstarter | upstarter.homelab.local | 3000 | CursorProjects/Upstarter | pending |
| LaunchTracker | launchtracker.homelab.local | 3000 | CursorProjects/LaunchTracker | pending |
| Launchpad | launchpad.homelab.local | 3000 | CursorProjects/Launchpad | pending |
| Wishlister | wishlister.homelab.local | 3000 | CursorProjects/Wishlister | pending |
| HeicConvert | heicconvert.homelab.local | 3000 | CursorProjects/HeicConvert | pending |
| Difference | difference.homelab.local | 3000 | CursorProjects/Difference | pending |

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
