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

## Restore

### Restore a PostgreSQL database

```bash
# List available backups
ls /var/backups/platform/

# Restore a specific DB dump (example: infisical-db container, infisical database)
gunzip -c /var/backups/platform/<DATE>/infisical-db-infisical.sql.gz \
  | docker exec -i infisical-db psql -U infisical -d infisical
```

### Restore the Infisical volume

```bash
# Stop Infisical stack first
cd ~/platform/infra/secrets && docker compose down

# Restore the volume from the backup tar
docker run --rm \
  -v infisical_db_data:/data \
  -v /var/backups/platform/<DATE>:/backup:ro \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/infisical-db-data.tar.gz -C / "

# Bring Infisical back up
docker compose up -d
```

### Restore the Loki volume

```bash
# Stop Loki
cd ~/platform/infra/logging && docker compose stop loki

# Restore the volume
docker run --rm \
  -v loki_data:/data \
  -v /var/backups/platform/<DATE>:/backup:ro \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/loki-data.tar.gz -C /"

# Start Loki
docker compose start loki
```

### Quarterly restore drill

Run this checklist once a quarter to verify backups are actually usable:

- [ ] Provision a scratch VM with Docker installed
- [ ] Copy the latest backup directory to the scratch VM
- [ ] Restore `infisical-db` using the PostgreSQL restore steps above
- [ ] Bring up `infra/secrets` and verify Infisical UI loads and secrets are present
- [ ] Restore one app DB and verify the app starts and can read its data
- [ ] Confirm `loki-data.tar.gz` is non-empty and extractable (`tar tzf loki-data.tar.gz | head`)
- [ ] Destroy the scratch VM

---

## CrowdSec — Setup & Management

CrowdSec automatically detects and blocks malicious IPs (brute force, scanners, CVE exploits) at the Traefik level using community threat intelligence.

### First-time setup

```bash
# 1. Copy the env template
cp ~/platform/infra/traefik/.env.example ~/platform/infra/traefik/.env

# 2. Start the stack (CrowdSec will install collections on first boot)
cd ~/platform/infra/traefik && docker compose --env-file .env up -d

# 3. Generate a bouncer API key
docker exec crowdsec cscli bouncers add traefik-bouncer

# 4. Copy the key output and paste it into .env:
#    CROWDSEC_BOUNCER_API_KEY=<the-key-from-step-3>

# 5. Restart to pick up the key
cd ~/platform/infra/traefik && docker compose --env-file .env up -d
```

### Common CrowdSec commands

```bash
# View active decisions (blocked IPs)
docker exec crowdsec cscli decisions list

# View recent alerts (detected threats)
docker exec crowdsec cscli alerts list

# Manually ban an IP for 24h
docker exec crowdsec cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual ban"

# Unban an IP
docker exec crowdsec cscli decisions delete --ip 1.2.3.4

# List installed collections (detection scenarios)
docker exec crowdsec cscli collections list

# Update threat intelligence hub
docker exec crowdsec cscli hub update && docker exec crowdsec cscli hub upgrade

# Check CrowdSec metrics (parsed logs, scenarios triggered)
docker exec crowdsec cscli metrics

# View bouncer status (should show traefik-bouncer as "validated")
docker exec crowdsec cscli bouncers list
```

### Whitelist an IP (prevent false positives)

```bash
# Add to CrowdSec's whitelist (persists across restarts)
docker exec crowdsec cscli parsers install crowdsecurity/whitelists
# Then edit the whitelist inside the container or mount a custom whitelist file
docker exec crowdsec cat /etc/crowdsec/parsers/s02-enrich/whitelists.yaml
```

Or add trusted IPs directly to Traefik's `internal-only` middleware sourcerange in `infra/traefik/docker-compose.yml`.

---

## Backup Verification

Backup verification runs automatically at 2:30am daily (30 min after the backup). It checks:
- PostgreSQL dump integrity (gzip + SQL content validation)
- Tar archive integrity (listing contents without extracting)
- Generates SHA256 checksum manifest

```bash
# Run manually
./scripts/verify-backup.sh

# Check verification log
tail -50 /var/log/platform-backup-verify.log

# View checksums for the latest backup
cat /var/backups/platform/$(ls -1t /var/backups/platform/ | head -1)/checksums.sha256
```

---

## Lint Platform Config

Run before committing changes to infra, scripts, or services.yaml:

```bash
# Local lint (yamllint + shellcheck + docker compose validation)
./scripts/lint-platform.sh

# This also runs automatically on PRs via .github/workflows/validate-platform.yml
```

Requires: `sudo apt install yamllint shellcheck`

---

## SSO / ForwardAuth — Platform Login

All admin UIs (Portainer, Grafana, Infisical, Verdaccio) are protected by SSO via your auth-service. Users must log in at `auth.homelab.local` before accessing any admin UI.

### How it works

1. User visits `portainer.homelab.local` (or any admin UI)
2. Traefik's `admin-auth` middleware chain runs:
   - `internal-only` — checks IP is on LAN/Tailscale
   - `platform-auth` — calls `GET http://auth-service:8703/auth/verify`
3. Auth-service checks the `platform_session` cookie (or `Authorization: Bearer` header)
4. If valid → 200, request proceeds. User identity forwarded via `X-Auth-User-Id` / `X-Auth-User-Email` headers.
5. If invalid → 401, access denied.

### Setup

The auth-service needs one extra env var in production:

```bash
# Set the cookie domain so the session cookie works across all *.homelab.local subdomains
AUTH_SESSION_COOKIE_DOMAIN=.homelab.local
```

The `platform_session` cookie is set automatically when a user logs in via any of:
- `POST /auth/login`
- `POST /auth/register`
- `POST /auth/refresh`
- `POST /auth/token` (OAuth code exchange)

### Troubleshooting SSO

**Admin UI returns 401 / blank page:**
- Check auth-service is running: `docker ps | grep auth-service`
- Check the cookie domain matches: `AUTH_SESSION_COOKIE_DOMAIN` must be `.homelab.local` (with leading dot)
- Check the user has logged in recently at `https://auth.homelab.local`
- Verify the ForwardAuth middleware is loaded: Traefik dashboard → Middlewares → `platform-auth@file`

**Want to temporarily disable SSO on an admin UI:**
Change the middleware back to `internal-only@docker` in the service's `docker-compose.yml` labels and restart the stack.

### Config files

- `infra/traefik/dynamic/forwardauth.yml` — ForwardAuth middleware + `admin-auth` chain
- Auth-service: `VerifyResource.kt` (`/auth/verify` endpoint)
- Auth-service: `SessionCookieFilter.kt` (sets `platform_session` cookie on login)

---

## Uptime Kuma — Status Page

Public status page at `https://status.homelab.local`. Shows service health for non-engineers.

### First-time setup

1. Visit `https://status.homelab.local`
2. Create an admin account (this is Uptime Kuma's own login, separate from platform SSO)
3. Add monitors for your services:
   - Type: HTTP(s)
   - URL: `https://<subdomain>.homelab.local`
   - Interval: 60 seconds
4. Create a status page: Settings → Status Pages → New → add your monitors

### Notifications

Uptime Kuma supports 90+ notification types. Configure under Settings → Notifications:
- Slack: paste a webhook URL
- Email: configure SMTP
- Telegram: bot token + chat ID
- Discord: webhook URL

### Management

```bash
# Start/stop
cd ~/platform/infra/uptime-kuma && docker compose up -d
cd ~/platform/infra/uptime-kuma && docker compose down

# Data is in the uptime_kuma_data volume (SQLite)
```

---

## Start / Stop Individual Infrastructure

```bash
# Docker Socket Proxy (must start before Traefik, monitoring, logging)
cd ~/platform/infra/docker-proxy && docker compose up -d

# Traefik + CrowdSec
cd ~/platform/infra/traefik && docker compose --env-file .env up -d
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

# Uptime Kuma (status page)
cd ~/platform/infra/uptime-kuma && docker compose up -d
```

> **Important**: The docker-socket-proxy must be running before starting Traefik, monitoring, or logging stacks. If those stacks can't discover containers, check that `docker-proxy` is healthy: `docker ps | grep docker-proxy`

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

Then register the service in `services.yaml`.

---

## Update Infrastructure Images (Renovate)

All Docker images are pinned to specific versions. [Renovate](https://github.com/renovatebot/renovate) opens PRs weekly when newer versions are available.

```bash
# If Renovate is active, just review and merge its PRs.
# To check manually what's outdated:
cd ~/platform/infra/monitoring && docker compose pull --dry-run
cd ~/platform/infra/logging   && docker compose pull --dry-run
cd ~/platform/infra/secrets   && docker compose pull --dry-run
cd ~/platform/infra/traefik   && docker compose pull --dry-run

# After merging a Renovate PR (or updating tags manually), redeploy the stack:
cd ~/platform/infra/<stack> && docker compose pull && docker compose up -d

# Clean up old images
docker image prune -f
```

**Important**: Postgres major version bumps (e.g. 16 → 17) require a manual `pg_dump`/`pg_restore` migration. Renovate is configured to block these automatically.

---

## Infisical — Add/Update Secrets

```bash
# CLI (local dev)
infisical login
infisical secrets set MY_VAR=value --env=production --projectId=<id>

# Or use the UI at https://secrets.homelab.local
```

**Required environment variables** (`infra/secrets/.env`):
```bash
INFISICAL_ENCRYPTION_KEY=...   # openssl rand -hex 16
INFISICAL_AUTH_SECRET=...      # openssl rand -base64 32
INFISICAL_DB_PASSWORD=...      # choose a strong password
INFISICAL_REDIS_PASSWORD=...   # openssl rand -base64 32
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
| Uptime Kuma | https://status.homelab.local |

---

## Portainer — First-Time Setup

On first visit to `https://portainer.homelab.local`:
1. Create an admin username and password — save these, there is no recovery without CLI access
2. Click **Get Started** → **local** → **Connect**
3. You are in the dashboard — the **local** environment shows all Docker containers on this host

---

## Alertmanager — Configure Slack Notifications

1. Create a Slack incoming webhook:
   - Go to `https://api.slack.com/apps` → **Create New App** → **From scratch**
   - Name it (e.g. `homelab-alerts`), pick your workspace
   - Left sidebar → **Incoming Webhooks** → toggle on → **Add New Webhook to Workspace**
   - Pick a channel (e.g. `#alerts`) → **Allow**
   - Copy the webhook URL (looks like `https://hooks.slack.com/services/T.../B.../...`)

2. Edit `infra/monitoring/alertmanager.yml` — uncomment and fill the Slack block:
   ```yaml
   receivers:
     - name: 'default'
       slack_configs:
         - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
           channel: '#alerts'
           title: '{{ .GroupLabels.alertname }}'
           text: '{{ range .Alerts }}{{ .Annotations.description }}{{ "\n" }}{{ end }}'
   ```

3. Restart Alertmanager:
   ```bash
   cd ~/platform/infra/monitoring && docker compose restart alertmanager
   ```

4. Test it:
   ```bash
   # Send a test alert
   curl -X POST http://localhost:9093/api/v1/alerts \
     -H 'Content-Type: application/json' \
     -d '[{"labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"description":"This is a test alert"}}]'
   ```

---

## Alertmanager — Configure Email Notifications

Edit `infra/monitoring/alertmanager.yml` — uncomment and fill the email block:
```yaml
receivers:
  - name: 'default'
    email_configs:
      - to: 'you@example.com'
        from: 'alertmanager@homelab.local'
        smarthost: 'smtp.gmail.com:587'
        auth_username: 'you@gmail.com'
        auth_password: 'your-app-password'   # use Gmail App Password, not your real password
        require_tls: true
```

For Gmail: create an App Password at `myaccount.google.com/apppasswords` (requires 2FA enabled).

Restart: `cd ~/platform/infra/monitoring && docker compose restart alertmanager`

---

## Alertmanager — Add a Custom Alert Rule

Custom alert rules go in `infra/monitoring/alerts.yml`. Add a new rule under an existing group or create a new group:

```yaml
groups:
  - name: my_app_alerts
    rules:
      - alert: MyAppHighErrorRate
        # PromQL expression — fires when condition is true for `for` duration
        expr: |
          rate(http_server_requests_seconds_count{job="my-app", status=~"5.."}[5m])
          /
          rate(http_server_requests_seconds_count{job="my-app"}[5m])
          > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High error rate in my-app"
          description: "my-app is returning >5% errors for the last 2 minutes."
```

After editing, reload Prometheus (no restart needed):
```bash
curl -X POST http://localhost:9090/-/reload
```

Verify the rule loaded: Prometheus UI at `http://localhost:9090` → **Alerts** tab.

---

## Grafana — Import a Dashboard

1. Go to `https://monitoring.homelab.local` → log in
2. Left sidebar → **Dashboards** → **Import**
3. Paste a dashboard ID from `grafana.com/grafana/dashboards` and click **Load**
4. Select the Prometheus datasource → **Import**

Recommended dashboards to import:
- `14282` — Docker container metrics (CPU, memory, network per container)
- `13639` — Loki Docker logs overview
- `17346` — Traefik v3 request metrics
