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
