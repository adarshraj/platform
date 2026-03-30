# Platform

Central infrastructure repo for managing all internal applications and services.
This repo does **not** contain application code — it contains the platform layer that runs on top of your homelab or VPS.

---

## What This Does

| Problem | Solution |
|---|---|
| Starting/stopping 19+ apps is tedious | Portainer UI — manage all Docker stacks from one place |
| Port juggling (`localhost:3001`, `:8081`, ...) | Traefik — every service gets a clean URL (`app.homelab.local`) |
| `.env` files scattered across all repos | Infisical — centralized secrets, per-app, per-environment |
| No idea what's broken until someone complains | Prometheus + Grafana — metrics, alerts, container health |
| Can't search logs across services | Loki + Promtail — unified log search across all containers |
| Copy-pasting utility code across projects | Verdaccio — private npm registry for shared TypeScript libraries |

---

## Architecture

```
Browser / Local Network
        │
    Traefik  (:80 → :443)
        │  routes by subdomain
   ┌────┴────────────────────────────────────────┐
   │         Docker stacks (your apps)           │
   │  bookshelf  auth-service  finance  vuln ...  │
   └─────────────────────────────────────────────┘
        │
   Platform infrastructure (this repo)
   ├── Portainer      → manage stacks via UI
   ├── Infisical      → secrets management
   ├── Loki/Promtail  → log aggregation
   ├── Prometheus     → metrics collection
   ├── Grafana        → unified dashboards (logs + metrics)
   └── Verdaccio      → private npm registry
```

---

## Quick Start (Homelab)

### Prerequisites
- Docker installed (`curl -fsSL https://get.docker.com | sh`)
- `mkcert` installed for TLS (`sudo apt install mkcert`)

### 1. Fill in secrets
```bash
cp infra/secrets/.env.example infra/secrets/.env
# Edit and fill: INFISICAL_ENCRYPTION_KEY, INFISICAL_AUTH_SECRET, INFISICAL_DB_PASSWORD
# Generate values with: openssl rand -hex 16

cp infra/monitoring/.env.example infra/monitoring/.env
# Edit and fill: GRAFANA_ADMIN_PASSWORD
```

### 2. Generate TLS certificate
```bash
mkcert -install
mkcert "*.homelab.local" homelab.local
mkdir -p infra/traefik/dynamic/certs
mv "_wildcard.homelab.local+1.pem"     infra/traefik/dynamic/certs/wildcard.crt
mv "_wildcard.homelab.local+1-key.pem" infra/traefik/dynamic/certs/wildcard.key
```

### 3. Add DNS entries
Add to `/etc/hosts` on your machine (use `127.0.0.1` if running locally, or the machine's LAN IP otherwise):
```
127.0.0.1  traefik.homelab.local portainer.homelab.local monitoring.homelab.local
127.0.0.1  secrets.homelab.local npm.homelab.local
```

### 4. Bootstrap
```bash
./scripts/bootstrap.sh
```

---

## Service URLs

| Service | URL | Purpose |
|---|---|---|
| Traefik | https://traefik.homelab.local | Routing dashboard |
| Portainer | https://portainer.homelab.local | Docker stack management |
| Grafana | https://monitoring.homelab.local | Logs + metrics dashboards |
| Infisical | https://secrets.homelab.local | Secrets management |
| Verdaccio | https://npm.homelab.local | Private npm registry |

---

## Repo Structure

```
platform/
├── README.md                  ← you are here
├── SERVICE_CATALOG.md         ← all services: subdomains, ports, status
├── RUNBOOK.md                 ← common operational tasks (deploy, logs, backup)
│
├── .github/workflows/         ← reusable CI/CD workflows (used by all app repos)
│   ├── docker-build-push.yml  ← build + push any Docker image to ghcr.io
│   ├── quarkus-build.yml      ← Maven test + build + push for Kotlin backends
│   └── deploy-portainer.yml   ← trigger Portainer webhook to redeploy a stack
│
├── infra/
│   ├── traefik/               ← reverse proxy + TLS
│   ├── portainer/             ← Docker stack management UI
│   ├── secrets/               ← Infisical secrets manager
│   ├── logging/               ← Loki + Promtail log aggregation
│   ├── monitoring/            ← Prometheus + Grafana + cAdvisor + Alertmanager
│   ├── registry/              ← Verdaccio npm registry
│   └── networks/              ← shared Docker network setup script
│
├── scripts/
│   ├── bootstrap.sh           ← fresh machine setup (run once)
│   ├── deploy-app.sh          ← deploy/update a single app
│   ├── update-all.sh          ← update all running apps
│   ├── backup.sh              ← backup all databases + volumes
│   └── logs.sh                ← tail logs for an app
│
└── docs/
    ├── adding-new-app.md      ← step-by-step checklist for onboarding a new app
    ├── local-dev.md           ← developer machine setup (DNS, TLS, Infisical CLI)
    └── decisions/             ← why each tool was chosen (ADRs)
        ├── 001-traefik-over-nginx.md
        ├── 002-infisical-over-vault.md
        └── 003-loki-over-elk.md
```

---

## Adding a New App

See **[docs/adding-new-app.md](docs/adding-new-app.md)** for the full checklist.

Short version:
1. Add a row to `SERVICE_CATALOG.md`
2. Add Traefik labels + `platform_proxy` network to the app's `docker-compose.yml`
3. Migrate secrets to Infisical
4. Update the app's GitHub Actions to use the reusable workflows in `.github/workflows/`
5. Register the stack in Portainer

## CI/CD — Reusable Workflows

All app repos call the workflows in `.github/workflows/` instead of duplicating CI logic.

**Frontend app (SvelteKit / React / Node.js):**
```yaml
jobs:
  build:
    uses: adarshraj/platform/.github/workflows/docker-build-push.yml@main
    with:
      image-name: my-app-frontend
      context: frontend
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

**Kotlin/Quarkus backend:**
```yaml
jobs:
  build:
    uses: adarshraj/platform/.github/workflows/quarkus-build.yml@main
    with:
      image-name: my-app-backend
      working-directory: backend
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

**Deploy after build:**
```yaml
jobs:
  deploy:
    needs: build
    uses: adarshraj/platform/.github/workflows/deploy-portainer.yml@main
    with:
      stack-name: my-app
    secrets:
      PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL_MY_APP }}
```

**Full example** (frontend + backend + deploy in one file): see [docs/adding-new-app.md](docs/adding-new-app.md#4-update-github-actions).

---

## Moving to VPS Later

The setup is identical on a VPS. The only changes:
1. Replace `homelab.local` domains with your real domain (e.g. `app.yourdomain.com`)
2. Uncomment the Let's Encrypt section in `infra/traefik/traefik.yml`
3. Remove the `tls.yml` dynamic config (not needed with ACME)
4. Run `./scripts/bootstrap.sh` on the VPS

---

## Related

- **SERVICE_CATALOG.md** — full list of all apps and their subdomains/ports
