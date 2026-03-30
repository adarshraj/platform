# Runbook

Quick reference for common operational tasks.

## First-Time VPS Setup

```bash
# 1. Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# 2. Clone this repo
git clone https://github.com/yourorg/platform ~/platform
cd ~/platform

# 3. Bootstrap everything
./scripts/bootstrap.sh
```

---

## Deploy / Update an App

```bash
# Deploy a specific app (pulls latest image, restarts stack)
./scripts/deploy-app.sh <app-name> <env>

# Examples:
./scripts/deploy-app.sh bookshelf-haven production
./scripts/deploy-app.sh auth-service production
```

Or via Portainer UI: Stacks → select stack → Pull and redeploy.

---

## View Logs

```bash
# Tail logs for a stack
./scripts/logs.sh <app-name>

# Examples:
./scripts/logs.sh bookshelf-haven
./scripts/logs.sh auth-service

# Or via Grafana (full history + search):
# https://monitoring.homelab.local → Explore → Loki
# Query: {stack="bookshelf-haven"} |= "ERROR"
```

---

## Update All Apps

```bash
# Pull latest images and restart all running stacks
./scripts/update-all.sh
```

---

## Backup

```bash
# Run manual backup (all PostgreSQL DBs + volumes)
./scripts/backup.sh

# Backups are stored in /var/backups/platform/ and synced offsite via rclone.
# Cron runs this automatically at 2am daily (set up by bootstrap.sh).
```

---

## Start / Stop Individual Infrastructure

```bash
# Traefik
cd ~/platform/infra/traefik && docker compose up -d
cd ~/platform/infra/traefik && docker compose down

# Portainer
cd ~/platform/infra/portainer && docker compose up -d

# Monitoring (Prometheus + Grafana + cAdvisor)
cd ~/platform/infra/monitoring && docker compose up -d

# Logging (Loki + Promtail)
cd ~/platform/infra/logging && docker compose up -d

# Secrets (Infisical)
cd ~/platform/infra/secrets && docker compose up -d

# npm Registry (Verdaccio)
cd ~/platform/infra/registry && docker compose up -d
```

---

## Traefik — Add a New Route

See `docs/adding-new-app.md` for the full checklist.
Quick version: add these labels to the app's `docker-compose.yml` service:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<name>.rule=Host(`<name>.homelab.local`)"
  - "traefik.http.routers.<name>.entrypoints=websecure"
  - "traefik.http.routers.<name>.tls=true"
  - "traefik.http.services.<name>.loadbalancer.server.port=<container-port>"
networks:
  - platform_proxy
```

Then register the service in `SERVICE_CATALOG.md`.

---

## Infisical — Add/Update Secrets

```bash
# CLI (local dev)
infisical login
infisical secrets set MY_VAR=value --env=production --projectId=<id>

# Or use the UI at https://secrets.homelab.local
```

---

## Access URLs

| Service | URL |
|---|---|
| Traefik Dashboard | https://traefik.homelab.local |
| Portainer | https://portainer.homelab.local |
| Grafana | https://monitoring.homelab.local |
| Infisical | https://secrets.homelab.local |
| Verdaccio (npm) | https://npm.homelab.local |
