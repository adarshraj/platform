# VPS Deployment Guide

Complete guide for deploying the platform and apps on a fresh VPS.
This covers everything from initial setup to adding apps incrementally.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture Overview](#2-architecture-overview)
3. [One-Time VPS Setup](#3-one-time-vps-setup)
4. [Bootstrap Platform Infrastructure](#4-bootstrap-platform-infrastructure)
5. [Clone App Repos](#5-clone-app-repos)
6. [Deploy Shared Services](#6-deploy-shared-services)
7. [Deploy Your First Apps](#7-deploy-your-first-apps)
8. [Adding More Apps Later](#8-adding-more-apps-later)
9. [Private GHCR Images](#9-private-ghcr-images)
10. [GitHub Secrets Setup](#10-github-secrets-setup)
11. [Migrating to a New VPS](#11-migrating-to-a-new-vps)
12. [Deployment Order Reference](#12-deployment-order-reference)

---

## 1. Prerequisites

On your VPS (Ubuntu/Debian recommended):

```bash
sudo apt update && sudo apt install -y git curl python3
```

Docker is installed automatically by `bootstrap.sh` if missing.

---

## 2. Architecture Overview

```
Internet
    │
    │ *.yourdomain.com → VPS IP (wildcard DNS)
    │
┌───▼─────────────────────────────────────┐
│  Traefik  (ports 80 + 443, Let's Encrypt)│
└───┬─────────────────────────────────────┘
    │  platform_proxy  (internal Docker network)
    │
    ├── auth-service     auth.yourdomain.com
    ├── ai-shim          aishim.yourdomain.com
    ├── email-service    mail.yourdomain.com
    ├── doc-bucket       docbucket.yourdomain.com
    ├── finance-tracker  finance.yourdomain.com
    └── ...more apps

~/platform/          ← infra config, scripts (this repo)
~/apps/
  auth-service/      ← git clone from GitHub
  finance-tracker/   ← git clone from GitHub
  ...
```

All apps live on `platform_proxy`. They reach each other by container name:
- `http://auth-service:8703`
- `http://redis:6379`
- `http://garage:3900`

No app exposes ports to the host. Traefik is the only container that does.

---

## 3. One-Time VPS Setup

### 3.1 Clone the platform repo

```bash
git clone https://github.com/adarshraj/platform ~/platform
```

This is the **only manual clone** you ever do. `clone-apps.sh` handles the rest.

### 3.2 Set up GHCR authentication

App images are private on GitHub Container Registry. Docker needs credentials to pull them.

Create a GitHub fine-grained PAT:
1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. **Permissions**: Packages → Read-only (nothing else needed)
3. Copy the token

Store it on the VPS:
```bash
mkdir -p ~/.config/platform
echo "github_pat_xxxxxxxxxxxx" > ~/.config/platform/ghcr-token
chmod 600 ~/.config/platform/ghcr-token
```

`bootstrap.sh` calls `scripts/ghcr-login.sh` automatically. When the token expires or is rotated, just overwrite this file — the next deploy picks it up.

### 3.3 Fill in required .env files

```bash
cp ~/platform/infra/traefik/.env.example    ~/platform/infra/traefik/.env
cp ~/platform/infra/secrets/.env.example    ~/platform/infra/secrets/.env
cp ~/platform/infra/monitoring/.env.example ~/platform/infra/monitoring/.env
```

Edit each file. Key values:
- `infra/traefik/.env` — `CROWDSEC_BOUNCER_API_KEY` (generated after first start, see below)
- `infra/secrets/.env` — Infisical database credentials and encryption key
- `infra/monitoring/.env` — Grafana admin password

### 3.4 Configure DNS

Point a wildcard A record at your VPS IP:
```
*.yourdomain.com  →  <VPS IP>
```

### 3.5 Configure Let's Encrypt

In `infra/traefik/traefik.yml`, uncomment the certificate resolver:
```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: your@email.com
      storage: /letsencrypt/acme.json
      tlsChallenge: {}
```

In each app's `docker-compose.yml` labels, add:
```yaml
- "traefik.http.routers.<name>.tls.certresolver=letsencrypt"
```

Remove `infra/traefik/dynamic/tls.yml` — that's for homelab self-signed certs only.

---

## 4. Bootstrap Platform Infrastructure

```bash
~/platform/scripts/bootstrap.sh
```

This runs once and starts (in order):
1. Authenticates Docker with GHCR
2. Creates shared Docker networks
3. Docker socket proxy
4. Traefik + CrowdSec
5. Portainer
6. Infisical
7. Loki + Promtail (logging)
8. Prometheus + Grafana (monitoring)
9. Verdaccio (npm registry)
10. Uptime Kuma (status page)
11. Schedules daily backup cron

### Post-bootstrap: finish CrowdSec setup

Traefik's CrowdSec bouncer needs a key generated after first start:
```bash
docker exec crowdsec cscli bouncers add traefik-bouncer
# Copy the key it prints
```

Paste it into `infra/traefik/.env` as `CROWDSEC_BOUNCER_API_KEY`, then restart:
```bash
cd ~/platform/infra/traefik && docker compose up -d
```

---

## 5. Clone App Repos

`clone-apps.sh` reads `services.yaml` and clones all repos to `~/apps/`:

```bash
# Clone everything registered in services.yaml
~/platform/scripts/clone-apps.sh

# Or selectively
~/platform/scripts/clone-apps.sh shared      # shared services only
~/platform/scripts/clone-apps.sh apps        # apps only
~/platform/scripts/clone-apps.sh auth-service  # single app
```

Re-running `clone-apps.sh` is safe — it does `git pull` on repos that already exist.

The expected layout after cloning:
```
~/apps/
  auth-service/
  ai-shim/
  doc-bucket/
  email-service/
  finance-tracker/
  ...
```

> **Note:** `doc-bucket` maps to the `DocBucket` GitHub repo. The `clone-apps.sh`
> script uses the `name` field from `services.yaml` as the local directory name.

---

## 6. Deploy Shared Services

Shared services must be up before any app that depends on them. Deploy in this order:

```bash
# 1. Auth service — everything depends on this
~/platform/scripts/deploy-app.sh auth-service production \
  ~/apps/auth-service/docker-compose.prod.yml

# 2. These can run in any order after auth-service
~/platform/scripts/deploy-app.sh ai-shim production
~/platform/scripts/deploy-app.sh email-service production
~/platform/scripts/deploy-app.sh doc-bucket production \
  ~/apps/doc-bucket/docker-compose.yml
```

> **Note:** auth-service uses `docker-compose.prod.yml` (not `docker-compose.yml`
> which is a dev-only PostgreSQL helper). All other services use `docker-compose.yml`.

### Verify shared services are healthy

```bash
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "auth|ai-shim|email|doc-bucket"
```

All should show `(healthy)`.

---

## 7. Deploy Your First Apps

Start with one or two apps you actually use. `finance-tracker` is a good first choice
as it exercises the full dependency chain (auth, ai-shim, docbucket, email).

```bash
~/platform/scripts/deploy-app.sh finance-tracker production
```

Check it's accessible at `https://finance.yourdomain.com`.

Add more apps whenever you're ready — each is independent:
```bash
~/platform/scripts/deploy-app.sh bookshelf-haven production
~/platform/scripts/deploy-app.sh vahan-track production
```

---

## 8. Adding More Apps Later

The platform is designed for incremental adoption. Apps registered in `services.yaml`
consume no resources until you deploy them.

```bash
# Pull latest code for an app
git -C ~/apps/finance-tracker pull

# Or use update-all.sh to pull and redeploy everything running
~/platform/scripts/update-all.sh
```

To register a new app that isn't in `services.yaml` yet:
1. Add an entry to `services.yaml` (subdomain, port, repo, type)
2. Add Traefik labels + `platform_proxy` network to its `docker-compose.yml`
3. See `docs/adding-new-app.md` for the full checklist

---

## 9. Private GHCR Images

All shared service images are private on GHCR. They are built and pushed automatically
by GitHub Actions on every push to `master`.

### How images are built

Each service has `.github/workflows/deploy.yml` that calls the platform's reusable
`quarkus-build.yml` workflow:

```
push to master
  → run tests
  → build JAR
  → build Docker image
  → push to ghcr.io/adarshraj/<service>:latest
  → Trivy vulnerability scan (fails on CRITICAL)
  → trigger Portainer webhook → stack redeploys
```

### Image names

| Service | GHCR image |
|---|---|
| auth-service | `ghcr.io/adarshraj/auth-service:latest` |
| ai-shim | `ghcr.io/adarshraj/ai-shim:latest` |
| doc-bucket | `ghcr.io/adarshraj/doc-bucket:latest` |
| email-service | `ghcr.io/adarshraj/email-service:latest` |

### Pulling private images on the VPS

`scripts/ghcr-login.sh` handles authentication. It reads the token from
`~/.config/platform/ghcr-token` and is called automatically by both `bootstrap.sh`
and `deploy-app.sh` before every pull.

When your PAT expires, update the file:
```bash
echo "new_github_pat_xxx" > ~/.config/platform/ghcr-token
```

The next `deploy-app.sh` run will re-authenticate automatically.

---

## 10. GitHub Secrets Setup

### Per-repo secrets

Each app repo needs these in its GitHub Actions environment (`production`):

| Secret | How to get it |
|---|---|
| `INFISICAL_CLIENT_ID` | Infisical → Organization → Access Control → Machine Identities |
| `INFISICAL_CLIENT_SECRET` | Same screen |
| `PORTAINER_WEBHOOK_URL_<APPNAME>` | Portainer → Stacks → your stack → Webhooks → Enable → copy URL |

### Portainer webhook secret naming

App name in UPPERCASE with underscores:

| Service | Secret name |
|---|---|
| auth-service | `PORTAINER_WEBHOOK_URL_AUTH_SERVICE` |
| ai-shim | `PORTAINER_WEBHOOK_URL_AI_SHIM` |
| doc-bucket | `PORTAINER_WEBHOOK_URL_DOCBUCKET` |
| email-service | `PORTAINER_WEBHOOK_URL_EMAIL_SERVICE` |
| finance-tracker | `PORTAINER_WEBHOOK_URL_FINANCE_TRACKER` |

### Setting secrets at org level (saves time)

If you have a GitHub org, set `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET`
once at org level — all repos inherit them automatically:

GitHub → your org → Settings → Secrets and variables → Actions → New organization secret

Portainer webhook URLs must be per-repo (each stack has a unique URL).

### Portainer stack setup

1. Portainer → Stacks → Add stack
2. Name: use the exact `name` from `services.yaml` (e.g. `auth-service`)
3. Repository: paste the GitHub URL + branch `master` + compose file path
4. Deploy the stack
5. Stacks → click the stack → Webhooks → Enable → copy URL → add to GitHub secrets

---

## 11. Migrating to a New VPS

The entire platform is reproducible from GitHub. Code and config live in git.
Only persistent data (SQLite DBs, Garage objects, Grafana dashboards) needs a backup restore.

### Steps

```bash
# 1. On the new VPS: clone platform
git clone https://github.com/adarshraj/platform ~/platform

# 2. Set up GHCR token
mkdir -p ~/.config/platform
echo "github_pat_xxx" > ~/.config/platform/ghcr-token
chmod 600 ~/.config/platform/ghcr-token

# 3. Fill in .env files (same values as old VPS — get from Infisical or your backup)
cp ~/platform/infra/traefik/.env.example ~/platform/infra/traefik/.env
# ... edit each

# 4. Restore data backup (if needed)
# See README section 13 (Backup & Recovery)

# 5. Bootstrap
~/platform/scripts/bootstrap.sh

# 6. Clone all app repos
~/platform/scripts/clone-apps.sh

# 7. Deploy shared services
~/platform/scripts/deploy-app.sh auth-service production \
  ~/apps/auth-service/docker-compose.prod.yml
~/platform/scripts/deploy-app.sh ai-shim production
~/platform/scripts/deploy-app.sh email-service production
~/platform/scripts/deploy-app.sh doc-bucket production ~/apps/doc-bucket/docker-compose.yml

# 8. Deploy apps
~/platform/scripts/deploy-app.sh finance-tracker production
# ... add more as needed
```

That's it. The new VPS is running identically to the old one.

---

## 12. Deployment Order Reference

Always deploy in this order — services must be available before apps that depend on them.

```
1. Platform infra (bootstrap.sh handles this)
   traefik → portainer → infisical → loki → prometheus → verdaccio → uptime-kuma
   redis and garage are started as part of bootstrap too

2. Shared services (deploy manually in order)
   auth-service           (no dependencies)
   ai-shim                (no dependencies)
   email-service          (depends on: auth-service, redis)
   doc-bucket             (depends on: auth-service, garage)

3. Apps (any order after shared services are healthy)
   finance-tracker        (depends on: auth-service, ai-shim, docbucket, email-service)
   bookshelf-haven        (depends on: auth-service, docbucket, ai-shim)
   vahan-track            (depends on: auth-service)
   family-roots           (depends on: auth-service)
   family-vitals          (depends on: auth-service)
   family-vitals-vault    (depends on: auth-service)
   family-health-tracker  (no shared service dependencies)
   vuln-monitor           (no shared service dependencies)
   f1pulse                (no shared service dependencies)
```

> **Tip:** `services.yaml` has a `depends_on` field for every app that lists
> which shared services must be running first. Check it before deploying any app.
