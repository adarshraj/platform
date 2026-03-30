# Platform

Central infrastructure repo for managing all internal applications and services.
This repo does **not** contain application code — it contains the platform layer that sits on top of your homelab or VPS and solves the operational problems that come with running many apps.

---

## Table of Contents

1. [Why This Exists](#1-why-this-exists)
2. [How Everything Fits Together](#2-how-everything-fits-together)
3. [Port Management — How It Works](#3-port-management--how-it-works)
4. [Dependency Management — How It Works](#4-dependency-management--how-it-works)
5. [Tool Breakdown](#5-tool-breakdown)
   - [Traefik — Reverse Proxy](#traefik--reverse-proxy)
   - [Portainer — Deployment UI](#portainer--deployment-ui)
   - [Infisical — Secrets Management](#infisical--secrets-management)
   - [Loki + Promtail — Centralized Logging](#loki--promtail--centralized-logging)
   - [Prometheus + Grafana — Metrics & Alerting](#prometheus--grafana--metrics--alerting)
   - [Verdaccio — Private npm Registry](#verdaccio--private-npm-registry)
6. [Repo Structure](#6-repo-structure)
7. [Quick Start — Homelab](#7-quick-start--homelab)
8. [Quick Start — VPS (Production)](#8-quick-start--vps-production)
9. [CI/CD — Reusable Workflows](#9-cicd--reusable-workflows)
10. [Adding a New App](#10-adding-a-new-app)
11. [Security Model](#11-security-model)
12. [Backup & Recovery](#12-backup--recovery)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Why This Exists

When you have one app, managing it is simple. When you have 19+ apps across different stacks, the following problems emerge:

**Port chaos**: Each app runs on a different port. You end up with `localhost:3001`, `localhost:3002`, `localhost:8081`, `localhost:8082`... There is no central record of what runs where, ports conflict, and accessing apps from another device on your network requires remembering exact port numbers.

**Scattered secrets**: Every app has a `.env` file. These files live on your dev machine, on the server (hopefully), and sometimes accidentally get committed to git. When you rotate an API key or change a database password, you have to update it in multiple places and hope you didn't miss any.

**No visibility**: When something breaks at 2am, you have no idea which service failed, what error it threw, or when it started. You SSH into the server, run `docker logs <container>` for each service individually, and piece together what happened.

**Deployment friction**: Deploying an update means SSHing into the server, navigating to the right directory, running `docker compose pull && docker compose up -d`, and hoping nothing breaks. Doing this for 19 apps is tedious and error-prone.

**Copy-pasted code**: Utility functions, TypeScript types, UI components get duplicated across repos because there is no shared package registry. A bug fix in one copy doesn't propagate to others.

This platform repo solves all of these with a set of well-established, self-hosted, open-source tools — each doing one job well.

---

## 2. How Everything Fits Together

```
Your Browser or Device
        │
        │  https://bookshelf.homelab.local  (no port!)
        │
   ┌────▼────────────────────────────────────────────┐
   │               Traefik (ports 80 + 443)          │
   │   The only container that faces the network.    │
   │   Reads Docker labels, routes to the right app. │
   └────┬────────────────────────────────────────────┘
        │
        │  Internal Docker network (platform_proxy)
        │  Apps never expose ports directly to the host
        │
   ┌────┴──────────────────────────────────────────────────┐
   │                  Your Application Stacks              │
   │                                                       │
   │  bookshelf-haven    vahan-track    finance-tracker    │
   │  auth-service       DocBucket      ai-wrap   ...      │
   └────┬──────────────────────────────────────────────────┘
        │
        │  Platform infrastructure (this repo)
        │
   ┌────┴───────────────────────────────────────────────────────────┐
   │  Portainer   — see and manage all stacks from a web UI         │
   │  Infisical   — all secrets in one place, injected at runtime   │
   │  Promtail    — collects logs from every container automatically │
   │  Loki        — stores and indexes those logs                   │
   │  Grafana     — search logs and view metrics in one UI          │
   │  Prometheus  — collects CPU/memory/health metrics              │
   │  cAdvisor    — exposes per-container metrics to Prometheus     │
   │  Verdaccio   — private npm registry for shared TS libraries    │
   └────────────────────────────────────────────────────────────────┘
```

**Key principle**: Only Traefik has ports `80` and `443` open to the outside. Every other container uses Docker's internal networking. They are invisible to the network unless Traefik explicitly routes to them.

---

## 3. Port Management — How It Works

### The Problem

Without a reverse proxy, each app needs its own port exposed on the host:

```yaml
# bookshelf-haven/docker-compose.yml  (OLD way)
services:
  frontend:
    ports:
      - "3001:3000"   # host:container
  backend:
    ports:
      - "8081:8080"
```

This means:
- `localhost:3001` → bookshelf frontend
- `localhost:8081` → bookshelf backend
- `localhost:3002` → vahan-track frontend
- `localhost:8082` → vahan-track backend
- ... and so on for 19 apps

You now have 38+ open ports, potential conflicts, no central record, and no clean URLs.

### The Solution — Traefik Labels

With Traefik, apps don't expose ports at all. Instead, they join a shared Docker network and add labels that tell Traefik how to route to them:

```yaml
# bookshelf-haven/docker-compose.yml  (NEW way)
services:
  frontend:
    expose:
      - "3000"          # internal only, NOT published to host
    networks:
      - platform_proxy  # joins the shared Traefik network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.bookshelf.rule=Host(`bookshelf.homelab.local`)"
      - "traefik.http.routers.bookshelf.entrypoints=websecure"
      - "traefik.http.routers.bookshelf.tls=true"
      - "traefik.http.services.bookshelf.loadbalancer.server.port=3000"

networks:
  platform_proxy:
    external: true   # this network is created once by the platform
```

When this container starts, Traefik automatically detects the labels via Docker socket and creates a routing rule: `bookshelf.homelab.local → this container's port 3000`. No config files, no reloads.

### How Traefik Knows About Your Containers

Traefik runs with access to the Docker socket (`/var/run/docker.sock`). This lets it watch Docker events in real time. When a container starts with `traefik.enable=true`, Traefik registers it. When the container stops, Traefik deregisters it. Everything is automatic.

```yaml
# infra/traefik/traefik.yml
providers:
  docker:
    exposedByDefault: false   # containers must opt-in with traefik.enable=true
    network: platform_proxy
```

`exposedByDefault: false` is important — it means a container with no labels is completely invisible to Traefik. Only containers that explicitly opt in are routed.

### Result

| Before | After |
|---|---|
| `localhost:3001` | `https://bookshelf.homelab.local` |
| `localhost:3002` | `https://vahan.homelab.local` |
| `localhost:8081` | handled by same subdomain under `/api` |
| 38+ open ports on host | 2 ports total (80 + 443, both Traefik) |
| No central record | `SERVICE_CATALOG.md` is the single source of truth |

---

## 4. Dependency Management — How It Works

"Dependency management" means two different things here, and this platform handles both differently.

### A. Service Dependencies (Runtime)

Some apps depend on other services to be running. For example, `bookshelf-haven` needs `auth-service`, `DocBucket`, and `ai-wrap` to be running before it works properly.

**How the platform helps**:

1. **Shared Docker network**: All services on `platform_proxy` can reach each other by container name. Instead of hardcoding `http://localhost:8703`, you use `http://auth-service:8703`. This works regardless of which host port the service is on, and survives container restarts.

   ```bash
   # In bookshelf-haven's .env / Infisical secret:
   AUTH_SERVICE_URL=http://auth-service:8703   # container name, not localhost
   DOCBUCKET_URL=http://docbucket:8705
   AI_WRAP_URL=http://ai-wrap:8704
   ```

2. **Portainer visibility**: The Portainer UI shows all stacks and their status. Before deploying `bookshelf-haven`, you can confirm `auth-service` is healthy. If `auth-service` crashes, you see it immediately in Portainer without SSHing in.

3. **Grafana logs**: If `bookshelf-haven` is failing because `auth-service` is returning errors, Loki lets you search logs across both services simultaneously with a single query:
   ```
   {stack=~"bookshelf-haven|auth-service"} |= "error"
   ```

**What it does NOT do**: It does not automatically wait for `auth-service` to be healthy before starting `bookshelf-haven` across separate stacks. If you need that, add a healthcheck inside `bookshelf-haven`'s own `docker-compose.yml`:

```yaml
services:
  backend:
    depends_on:
      auth-service:
        condition: service_healthy
```

This works when both services are in the same compose file. For separate stacks, the practical solution is: start shared services first (they're stable), then start apps.

### B. Code Dependencies (Shared Libraries)

If you have utility functions or TypeScript types copy-pasted across multiple repos, that's a code dependency problem. The platform provides **Verdaccio** — a private npm registry — to solve this.

Instead of copying code, you publish it as a package once and install it everywhere:

```bash
# Publish once (from your shared library repo)
npm publish --registry https://npm.homelab.local

# Install in any app
npm install @adarshraj/auth-client --registry https://npm.homelab.local
```

This means bug fixes and updates propagate to all consumers via `npm update`. See [Verdaccio — Private npm Registry](#verdaccio--private-npm-registry) for setup.

### C. What This Platform Does NOT Solve

- **npm/Maven package version conflicts** between apps — each app manages its own `package.json` / `pom.xml`
- **Database schema migrations** across apps — each app manages its own Flyway/Prisma migrations
- **API contract compatibility** between services — you are responsible for versioning your internal APIs

---

## 5. Tool Breakdown

### Traefik — Reverse Proxy

**What it is**: A reverse proxy and load balancer designed for containerized environments.

**What it does here**:
- Accepts all incoming HTTP/HTTPS traffic on ports 80 and 443
- Routes requests to the correct container based on the hostname (e.g. `bookshelf.homelab.local` → bookshelf frontend container)
- Terminates TLS — your apps receive plain HTTP internally, Traefik handles encryption
- Redirects all HTTP traffic to HTTPS automatically
- Provides security middlewares: rate limiting, IP allowlisting, auth forwarding

**Config files**:
- `infra/traefik/traefik.yml` — static config (entrypoints, providers, TLS resolvers). Requires a restart to change.
- `infra/traefik/dynamic/tls.yml` — dynamic config (TLS cert paths). Hot-reloads without restart.
- `infra/traefik/dynamic/certs/` — where your `wildcard.crt` and `wildcard.key` live

**How TLS works**:
- Homelab: You generate a wildcard self-signed certificate with `mkcert` and install it in this folder. `mkcert -install` adds the CA to your OS/browser trust store so there are no certificate warnings.
- VPS/Production: Traefik fetches certificates from Let's Encrypt automatically via ACME. You just provide an email address and uncomment 4 lines in `traefik.yml`. Renewal is automatic.

**Security middlewares** (defined once in `infra/traefik/docker-compose.yml`, reusable by all apps):
- `internal-only@docker` — blocks access from outside your LAN. Used on Portainer, Grafana, Infisical.
- `ratelimit@docker` — limits to 100 requests/second per IP. Attach to any public app.
- `secure-headers@docker` — adds security HTTP headers (HSTS, X-Frame-Options, etc.)

**Traefik dashboard**: Available at `https://traefik.homelab.local`. Shows all registered routes, services, and middlewares in real time.

---

### Portainer — Deployment UI

**What it is**: A web UI for managing Docker containers, images, volumes, networks, and stacks.

**What it does here**:
- Shows all running containers across all stacks in one place
- Lets you start, stop, restart, or redeploy any stack without SSH
- Shows container logs, resource usage, and health status
- Manages "Stacks" — each Stack is a `docker-compose.yml` file. You paste or sync the file and Portainer manages the lifecycle.
- Provides **webhooks**: a unique URL per stack that, when called with a POST request, pulls the latest images and restarts the stack. This is how GitHub Actions triggers deployments.

**How deployments work**:
1. You push code to GitHub → GitHub Actions builds a new Docker image → pushes it to `ghcr.io`
2. GitHub Actions calls the Portainer webhook URL for that app
3. Portainer pulls the new image and restarts the stack
4. Zero SSH required

**Config**: `infra/portainer/docker-compose.yml`

---

### Infisical — Secrets Management

**What it is**: A self-hosted, open-source secrets manager. Think of it as a centralized, encrypted `.env` file manager with a UI, CLI, and API.

**What it replaces**: Scattered `.env` files across 19 repos and the server.

**How it works**:

Your secrets are organized as:
```
Organization: adarshraj
└── Project: bookshelf-haven
    ├── Environment: development
    │   ├── DATABASE_URL=postgresql://localhost:5432/bookshelf_dev
    │   ├── AUTH_SERVICE_URL=http://auth-service:8703
    │   └── OPENAI_API_KEY=sk-...
    ├── Environment: production
    │   ├── DATABASE_URL=postgresql://prod-db:5432/bookshelf
    │   ├── AUTH_SERVICE_URL=http://auth-service:8703
    │   └── OPENAI_API_KEY=sk-...
└── Project: auth-service
    ├── Environment: development
    └── Environment: production
```

**Three ways to use secrets**:

1. **Local development** — CLI wraps your command and injects secrets as environment variables:
   ```bash
   # Instead of: source .env && npm run dev
   infisical run --env=dev --projectName=bookshelf-haven -- npm run dev

   # Instead of: source .env && ./mvnw quarkus:dev
   infisical run --env=dev --projectName=bookshelf-haven -- ./mvnw quarkus:dev
   ```

2. **Docker deployment** — the deploy script fetches secrets and passes them to docker compose:
   ```bash
   infisical export --env=production --projectName=bookshelf-haven --format=dotenv > /tmp/app.env
   docker compose --env-file /tmp/app.env up -d
   rm /tmp/app.env
   ```
   This is what `scripts/deploy-app.sh` does automatically.

3. **GitHub Actions CI/CD** — the `Infisical/secrets-action` injects secrets into the workflow:
   ```yaml
   - uses: Infisical/secrets-action@v1
     with:
       client-id: ${{ secrets.INFISICAL_CLIENT_ID }}
       client-secret: ${{ secrets.INFISICAL_CLIENT_SECRET }}
       env-slug: production
       project-slug: bookshelf-haven
   ```

**Migrating from .env files**:
```bash
infisical login --domain=https://secrets.homelab.local
infisical secrets push --env=dev --projectName=bookshelf-haven < .env.local
infisical secrets push --env=production --projectName=bookshelf-haven < .env.production
```

**Config**: `infra/secrets/docker-compose.yml`, `infra/secrets/.env.example`

---

### Loki + Promtail — Centralized Logging

**What they are**:
- **Promtail**: An agent that runs as a container, reads Docker container logs from the host filesystem, and ships them to Loki.
- **Loki**: A log aggregation system that stores logs compressed, indexed only by labels (not full text — this keeps it lightweight).

**What they do here**: Every container's logs — regardless of which app or stack — are automatically collected and searchable in Grafana. You never need to `docker logs` into individual containers again.

**How Promtail finds your containers**: It mounts the Docker socket and the Docker log directory:
```yaml
volumes:
  - /var/lib/docker/containers:/var/lib/docker/containers:ro
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

It auto-discovers all running containers and tags each log line with:
- `container` — the container name (e.g. `bookshelf-haven-frontend-1`)
- `service` — the Docker Compose service name (e.g. `frontend`)
- `stack` — the Docker Compose project name (e.g. `bookshelf-haven`)

This means zero configuration per app. Every new container is picked up automatically.

**Querying logs in Grafana** (LogQL syntax):
```
# All logs from bookshelf-haven
{stack="bookshelf-haven"}

# Only errors from any app
{stack=~".+"} |= "ERROR"

# Logs from auth-service in the last hour that contain "token"
{stack="auth-service"} |= "token"

# All backend logs across all apps
{service="backend"}
```

**Config files**: `infra/logging/loki-config.yml`, `infra/logging/promtail-config.yml`

**Log retention**: Configured to 30 days in `loki-config.yml`. Adjust `retention_period` to suit your disk space.

### Configuring Your Apps for Logging

#### The Golden Rule — Log to stdout

Promtail collects logs by reading what containers write to **stdout and stderr**. Your app does not need to write to a file, use a special SDK, or know that Loki exists. As long as your app prints to stdout, Promtail picks it up automatically.

```kotlin
// Quarkus — this is picked up automatically
logger.info("User logged in: $userId")
logger.error("Database connection failed", exception)
```

```typescript
// Node.js — this is picked up automatically
console.log("Server started on port 3000")
console.error("Failed to reach auth-service")
```

Never log to a file inside the container (e.g. `logs/app.log`) — Promtail won't find it, and the file grows forever until the container runs out of disk space.

---

#### Structured Logging (Recommended)

Plain text logs are searchable by keyword, but structured JSON logs are far more powerful. With JSON logs, Loki can filter by individual fields like `level`, `userId`, `requestId`, `duration`, etc.

**Without structured logging** (hard to filter):
```
2024-01-15 10:23:45 ERROR Failed to process payment for user 123: timeout after 5000ms
```

**With structured logging** (filterable by any field):
```json
{"timestamp":"2024-01-15T10:23:45Z","level":"error","message":"Failed to process payment","userId":123,"error":"timeout","durationMs":5000}
```

In Grafana you can then query:
```
{stack="finance-tracker"} | json | level="error" | durationMs > 3000
```

---

#### Kotlin / Quarkus Apps

Quarkus uses JBoss Logging under the hood. To switch to JSON output, add this to `src/main/resources/application.properties`:

```properties
# Switch console output to JSON format
quarkus.log.console.json=true
quarkus.log.console.json.pretty-print=false

# Include useful fields in every log line
quarkus.log.console.json.additional-field."app".value=${quarkus.application.name}
quarkus.log.console.json.additional-field."app".type=string

# Set log levels
quarkus.log.level=INFO
quarkus.log.category."com.yourorg".level=DEBUG
```

This produces JSON logs like:
```json
{
  "timestamp": "2024-01-15T10:23:45.123Z",
  "sequence": 42,
  "loggerClassName": "org.jboss.logging.Logger",
  "loggerName": "com.yourorg.BookService",
  "level": "INFO",
  "message": "Book created: id=123",
  "app": "bookshelf-haven"
}
```

To log structured fields from your Kotlin code:
```kotlin
import org.jboss.logging.Logger
import org.jboss.logging.MDC

@ApplicationScoped
class BookService {
    private val logger = Logger.getLogger(BookService::class.java)

    fun createBook(userId: String, title: String): Book {
        // MDC fields are included in every log line until cleared
        MDC.put("userId", userId)
        MDC.put("action", "createBook")

        logger.info("Creating book: $title")

        val book = // ... create book

        logger.info("Book created: ${book.id}")
        MDC.clear()
        return book
    }
}
```

For **production vs development** — you probably want plain text locally and JSON on the server. Use Quarkus profiles:

```properties
# application.properties
%dev.quarkus.log.console.json=false    # plain text in dev
%prod.quarkus.log.console.json=true    # JSON in production (Docker)
```

---

#### Node.js / SvelteKit Apps

`console.log` works and Promtail picks it up, but for structured logging use **Pino** — it's the standard Node.js JSON logger, extremely fast, and zero config.

**Install**:
```bash
npm install pino pino-pretty
```

**Setup** (`src/lib/logger.ts` — shared across the app):
```typescript
import pino from 'pino'

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  // In production (Docker): output JSON
  // In dev: output pretty-printed text
  transport: process.env.NODE_ENV === 'development'
    ? { target: 'pino-pretty', options: { colorize: true } }
    : undefined,
  base: {
    app: process.env.APP_NAME || 'unknown',  // appears in every log line
  }
})

export default logger
```

**Using it**:
```typescript
import logger from '$lib/logger'

// Simple message
logger.info('Server started')

// With structured fields — these are searchable in Grafana
logger.info({ userId: '123', action: 'login' }, 'User logged in')
logger.error({ userId: '123', error: err.message, stack: err.stack }, 'Payment failed')
logger.warn({ requestId, durationMs: 4500 }, 'Slow request detected')
```

This produces:
```json
{"level":30,"time":1705312345123,"app":"finance-tracker","userId":"123","action":"login","msg":"User logged in"}
{"level":50,"time":1705312345200,"app":"finance-tracker","userId":"123","error":"timeout","msg":"Payment failed"}
```

**In SvelteKit hooks** (`src/hooks.server.ts`) — log every request automatically:
```typescript
import logger from '$lib/logger'
import type { Handle } from '@sveltejs/kit'

export const handle: Handle = async ({ event, resolve }) => {
  const start = Date.now()
  const requestId = crypto.randomUUID()

  // Attach requestId to all logs within this request
  const reqLogger = logger.child({ requestId })

  reqLogger.info({
    method: event.request.method,
    path: event.url.pathname,
  }, 'Request received')

  const response = await resolve(event)

  reqLogger.info({
    method: event.request.method,
    path: event.url.pathname,
    status: response.status,
    durationMs: Date.now() - start,
  }, 'Request completed')

  return response
}
```

---

#### React / Vite Frontend Apps

Frontend apps run in the browser — their `console.log` calls are not captured by Promtail (Promtail only sees server-side container logs). For frontend error tracking consider:

- **Server-side API errors**: log them in your backend (Quarkus or SvelteKit server routes) — these are captured
- **Client-side errors**: use an error boundary that sends errors to a backend endpoint, which logs them via Pino/Quarkus logger

---

#### Log Levels — Convention Across All Apps

Use these levels consistently so Grafana filters work the same way across all services:

| Level | When to use |
|---|---|
| `DEBUG` | Detailed info useful during development only. Disabled in production. |
| `INFO` | Normal events: request received, user logged in, job completed |
| `WARN` | Unexpected but recoverable: slow response, retry attempt, deprecated usage |
| `ERROR` | Something failed and needs attention: exception, external service unreachable |

Set `LOG_LEVEL=info` in Infisical for production, `LOG_LEVEL=debug` for development.

---

#### Querying Your Structured Logs in Grafana

Once your apps log JSON, these queries become available in Grafana → Explore → Loki:

```logql
# All errors across all apps
{stack=~".+"} | json | level="error"

# All errors from finance-tracker in the last 1 hour
{stack="finance-tracker"} | json | level="error"

# Slow requests (over 2 seconds) in any app
{service="backend"} | json | durationMs > 2000

# All logs for a specific user across all apps
{stack=~".+"} | json | userId="123"

# All logs for a specific request ID (trace a single request)
{stack="finance-tracker"} | json | requestId="abc-123-def"

# Error rate over time (use as a Grafana panel)
sum(rate({stack=~".+"} | json | level="error" [5m])) by (stack)
```

The last query can be turned into a Grafana dashboard panel showing error rate per app over time — a useful overview dashboard.

---

### Prometheus + Grafana — Metrics & Alerting

**What they are**:
- **cAdvisor**: Runs as a container with access to the host's Docker socket and filesystem. Exposes per-container metrics (CPU, memory, network, disk) at `/metrics`.
- **Prometheus**: Scrapes `/metrics` endpoints on a schedule (every 15 seconds) and stores the time-series data.
- **Alertmanager**: Receives alerts from Prometheus when rules are violated and routes them to Slack/email/webhook.
- **Grafana**: Visualization UI. Connects to both Prometheus (metrics) and Loki (logs) so you have one dashboard for everything.

**What you get out of the box**:
- CPU and memory usage per container, over time
- Container restart counts (catch crash loops)
- Network I/O per container
- Disk usage on the host
- Alerts when: a container is down for 2+ minutes, memory exceeds 85%, a container restarts 3+ times in 10 minutes, disk space falls below 15%

**Pre-built Grafana dashboards to import** (paste the ID in Grafana → Dashboards → Import):
- `14282` — Docker container metrics (cAdvisor)
- `13639` — Loki Docker logs
- `17346` — Traefik v3

**How app-level metrics work** (optional, for Quarkus backends):
Quarkus automatically exposes a `/q/metrics` endpoint. Add these labels to the backend service in the app's `docker-compose.yml` to have Prometheus scrape it:
```yaml
labels:
  - "prometheus.scrape=true"
  - "prometheus.port=8080"
  - "prometheus.path=/q/metrics"
```

**Alert configuration**: Edit `infra/monitoring/alertmanager.yml` to add your Slack webhook or email SMTP settings. Uncomment the relevant block.

**Config files**: `infra/monitoring/prometheus.yml`, `infra/monitoring/alerts.yml`, `infra/monitoring/alertmanager.yml`, `infra/monitoring/grafana/provisioning/`

Grafana's datasources (Prometheus and Loki) are **auto-provisioned** on startup from `grafana/provisioning/datasources/datasources.yml` — you don't need to configure them manually in the UI.

---

### Verdaccio — Private npm Registry

**What it is**: A lightweight private npm registry that also proxies requests to the public npm registry. It acts as a pass-through for public packages and a host for your private ones.

**What it does here**: Lets you publish shared TypeScript/JavaScript libraries (e.g. `@adarshraj/auth-client`, `@adarshraj/ui-components`) and install them in any app, just like a public npm package.

**How it works**:

1. You write a shared library in its own repo (e.g. `shared/auth-client`)
2. In that library's `package.json`: `"name": "@adarshraj/auth-client"`
3. You publish it: `npm publish --registry https://npm.homelab.local`
4. In any app that needs it: `npm install @adarshraj/auth-client`

Verdaccio stores the package. Any npm install for `@adarshraj/*` packages goes to Verdaccio. Any install for public packages (react, typescript, etc.) passes through to the public npm registry and is cached locally.

**Developer setup** (once per machine): Add to `~/.npmrc`:
```
@adarshraj:registry=https://npm.homelab.local
```

**Config**: `infra/registry/verdaccio-config.yml`. The `@adarshraj/*` scope is configured as private (requires authentication to publish). All other packages pass through to public npm.

---

## 6. Repo Structure

```
platform/
├── README.md                  ← you are here
├── SERVICE_CATALOG.md         ← authoritative list of all services, subdomains, ports
├── RUNBOOK.md                 ← common day-to-day operational tasks
│
├── .github/
│   └── workflows/             ← reusable CI/CD workflows, called from all app repos
│       ├── docker-build-push.yml   ← builds + pushes any Docker image to ghcr.io
│       ├── quarkus-build.yml       ← Maven test + build + push for Kotlin/Quarkus backends
│       └── deploy-portainer.yml    ← triggers Portainer webhook to redeploy a stack
│
├── infra/                     ← one subdirectory per infrastructure service
│   ├── traefik/
│   │   ├── docker-compose.yml      ← runs Traefik container
│   │   ├── traefik.yml             ← static config: entrypoints, Docker provider, TLS
│   │   └── dynamic/
│   │       ├── tls.yml             ← TLS cert paths (hot-reloaded)
│   │       └── certs/              ← wildcard.crt + wildcard.key (generated by mkcert)
│   │
│   ├── portainer/
│   │   └── docker-compose.yml
│   │
│   ├── secrets/
│   │   ├── docker-compose.yml      ← Infisical + its PostgreSQL + Redis
│   │   └── .env.example            ← template: copy to .env and fill values
│   │
│   ├── logging/
│   │   ├── docker-compose.yml      ← Loki + Promtail
│   │   ├── loki-config.yml         ← storage, retention, schema
│   │   └── promtail-config.yml     ← Docker autodiscovery, label extraction
│   │
│   ├── monitoring/
│   │   ├── docker-compose.yml      ← Prometheus + Grafana + cAdvisor + Alertmanager
│   │   ├── prometheus.yml          ← scrape targets (cAdvisor, Traefik, app metrics)
│   │   ├── alerts.yml              ← alerting rules (container down, high memory, etc.)
│   │   ├── alertmanager.yml        ← notification channels (Slack, email, webhook)
│   │   ├── .env.example            ← template: Grafana admin password
│   │   └── grafana/
│   │       └── provisioning/
│   │           ├── datasources/    ← auto-configures Prometheus + Loki datasources
│   │           └── dashboards/     ← auto-loads dashboard JSON files on startup
│   │
│   ├── registry/
│   │   ├── docker-compose.yml      ← Verdaccio npm registry
│   │   └── verdaccio-config.yml    ← scopes, auth, upstream proxy config
│   │
│   └── networks/
│       └── create-networks.sh      ← creates platform_proxy + monitoring_internal (run once)
│
├── scripts/
│   ├── bootstrap.sh           ← installs Docker, creates networks, starts all infra (run once)
│   ├── deploy-app.sh          ← deploys/updates one app: fetches secrets + pulls + restarts
│   ├── update-all.sh          ← runs deploy-app.sh for every app in ~/apps/
│   ├── backup.sh              ← dumps all PostgreSQL DBs + backs up volumes, syncs offsite
│   └── logs.sh                ← tails logs for a named app stack
│
└── docs/
    ├── adding-new-app.md      ← complete checklist for onboarding any new app
    ├── local-dev.md           ← dev machine setup: DNS, TLS trust, Infisical CLI, npm registry
    └── decisions/             ← Architecture Decision Records (why each tool was chosen)
        ├── 001-traefik-over-nginx.md
        ├── 002-infisical-over-vault.md
        └── 003-loki-over-elk.md
```

---

## 7. Quick Start — Homelab

This runs everything on a single machine on your local network. All services are accessible via `*.homelab.local` URLs from any device on your Wi-Fi.

### Prerequisites

- Any machine with Docker installed (Linux, Mac, Windows with WSL2)
- `mkcert` for TLS certificates

### Step 1 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker   # apply group change without logging out
```

### Step 2 — Clone this repo

```bash
git clone https://github.com/adarshraj/platform ~/platform
cd ~/platform
```

### Step 3 — Fill in the .env files

**Infisical secrets** (`infra/secrets/.env`):
```bash
cp infra/secrets/.env.example infra/secrets/.env
```
Edit the file and fill in:
```bash
# Generate with: openssl rand -hex 16
INFISICAL_ENCRYPTION_KEY=paste_generated_value_here

# Generate with: openssl rand -base64 32
INFISICAL_AUTH_SECRET=paste_generated_value_here

# Pick any strong password
INFISICAL_DB_PASSWORD=choose_a_password
```

**Grafana** (`infra/monitoring/.env`):
```bash
cp infra/monitoring/.env.example infra/monitoring/.env
```
Edit and set `GRAFANA_ADMIN_PASSWORD=choose_a_password`.

### Step 4 — Generate TLS certificate

```bash
# Install mkcert (adds a local CA to your OS + browser trust store)
sudo apt install mkcert       # Ubuntu/Debian
# brew install mkcert         # macOS

mkcert -install               # installs the CA — run once per machine

# Generate wildcard cert for *.homelab.local
mkcert "*.homelab.local" homelab.local

# Move to the location Traefik reads from
mkdir -p infra/traefik/dynamic/certs
mv "_wildcard.homelab.local+1.pem"     infra/traefik/dynamic/certs/wildcard.crt
mv "_wildcard.homelab.local+1-key.pem" infra/traefik/dynamic/certs/wildcard.key
```

On other devices (phone, laptop) that need to access the homelab: copy the mkcert CA certificate (`~/.local/share/mkcert/rootCA.pem` on Linux, `~/Library/Application Support/mkcert/rootCA.pem` on Mac) and install it in the device's trust store.

### Step 5 — Configure DNS

Every machine that needs to access the homelab must resolve `*.homelab.local` to the homelab machine's IP.

**Option A — /etc/hosts** (simplest, manual per machine):
```bash
# Use 127.0.0.1 if running on the same machine, or the LAN IP (e.g. 192.168.1.50) for other devices
sudo tee -a /etc/hosts <<EOF
127.0.0.1  traefik.homelab.local
127.0.0.1  portainer.homelab.local
127.0.0.1  monitoring.homelab.local
127.0.0.1  secrets.homelab.local
127.0.0.1  npm.homelab.local
EOF
```
Add more lines as you deploy apps (e.g. `127.0.0.1 bookshelf.homelab.local`).

**Option B — Pi-hole** (recommended if you have it):
In Pi-hole admin → Local DNS → DNS Records, add:
- Domain: `homelab.local` → IP: `192.168.1.x` (your homelab machine's LAN IP)

This single wildcard entry covers all subdomains automatically. Every device using Pi-hole as its DNS resolver will resolve `*.homelab.local` correctly.

### Step 6 — Bootstrap

```bash
./scripts/bootstrap.sh
```

This script:
1. Checks Docker is installed
2. Creates the shared Docker networks (`platform_proxy`, `monitoring_internal`)
3. Starts Traefik, Portainer, Infisical, Loki, Promtail, Prometheus, Grafana, cAdvisor, Verdaccio
4. Sets up a daily cron job for database backups at 2am

### Step 7 — Verify

Open these URLs in your browser:

| URL | Expected |
|---|---|
| https://traefik.homelab.local | Traefik dashboard showing registered routes |
| https://portainer.homelab.local | Portainer setup screen (create admin account on first visit) |
| https://monitoring.homelab.local | Grafana login (user: admin, password: what you set) |
| https://secrets.homelab.local | Infisical setup screen (create account on first visit) |
| https://npm.homelab.local | Verdaccio package registry UI |

---

## 8. Quick Start — VPS (Production)

When you're ready to move from homelab to a real server, the process is identical with three small changes.

### Differences from Homelab

**1. Real domain instead of homelab.local**

Buy a domain (e.g. `yourdomain.com`) and create a wildcard DNS A record:
```
*.yourdomain.com  →  your VPS IP
```

Update all `homelab.local` references in your app `docker-compose.yml` labels to use `yourdomain.com`.

**2. Let's Encrypt instead of mkcert**

In `infra/traefik/traefik.yml`, uncomment the certificate resolver section:
```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: your@email.com
      storage: /letsencrypt/acme.json
      tlsChallenge: {}
```

And in each app's Traefik labels, add:
```yaml
- "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
```

Remove `infra/traefik/dynamic/tls.yml` — it's no longer needed.

**3. No /etc/hosts needed**

Public DNS resolves your domain automatically for all devices.

### Everything else is identical

Same `bootstrap.sh`, same stacks, same scripts, same Portainer, same Infisical. Run:
```bash
git clone https://github.com/adarshraj/platform ~/platform
cd ~/platform
# fill .env files (same as homelab)
./scripts/bootstrap.sh
```

---

## 9. CI/CD — Reusable Workflows

Every app repo uses the workflows in `.github/workflows/` instead of duplicating CI logic. This means a bug fix or improvement to the build process applies to all apps at once.

### How Reusable Workflows Work

GitHub Actions supports `workflow_call` — a workflow in one repo can be called from another repo using `uses:`. The calling repo passes inputs (like image name) and secrets (like API keys). The called workflow does the actual work.

### Available Workflows

#### `docker-build-push.yml` — For all frontends (SvelteKit, React, Node.js)

What it does:
1. Checks out the code
2. Optionally fetches secrets from Infisical and exposes them as env vars for the build
3. Sets up Docker Buildx (for efficient multi-platform builds)
4. Logs into GitHub Container Registry (`ghcr.io`) using the automatic `GITHUB_TOKEN`
5. Builds the Docker image with layer caching (dramatically speeds up repeat builds)
6. Pushes two tags: `latest` and `sha-<commit-hash>`

```yaml
# In your app repo: .github/workflows/deploy.yml
jobs:
  build-frontend:
    uses: adarshraj/platform/.github/workflows/docker-build-push.yml@main
    with:
      image-name: bookshelf-haven-frontend   # becomes ghcr.io/adarshraj/bookshelf-haven-frontend
      dockerfile: frontend/Dockerfile        # optional, defaults to ./Dockerfile
      context: frontend                      # optional, defaults to .
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

#### `quarkus-build.yml` — For all Kotlin/Quarkus backends

What it does:
1. Checks out the code
2. Sets up JDK 21 with Maven dependency caching
3. Optionally fetches secrets from Infisical
4. Runs `./mvnw test` — fails the build if tests fail
5. Runs `./mvnw package -DskipTests` — produces the JAR
6. Builds and pushes the Docker image to `ghcr.io`

```yaml
jobs:
  build-backend:
    uses: adarshraj/platform/.github/workflows/quarkus-build.yml@main
    with:
      image-name: bookshelf-haven-backend
      working-directory: backend   # optional, defaults to .
      java-version: "21"           # optional, defaults to 21
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

#### `deploy-portainer.yml` — Triggers redeployment

What it does: Sends a POST request to a Portainer stack webhook URL. Portainer receives this, pulls the latest image from `ghcr.io`, and restarts the stack.

```yaml
jobs:
  deploy:
    needs: [build-frontend, build-backend]   # waits for both builds to succeed
    uses: adarshraj/platform/.github/workflows/deploy-portainer.yml@main
    with:
      stack-name: bookshelf-haven   # just for logging, Portainer uses the webhook URL
    secrets:
      PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL_BOOKSHELF }}
```

### Full Example — App With Frontend + Backend

Create `.github/workflows/deploy.yml` in your app repo:

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]   # runs on every push to main

jobs:
  build-frontend:
    uses: adarshraj/platform/.github/workflows/docker-build-push.yml@main
    with:
      image-name: bookshelf-haven-frontend
      context: frontend
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}

  build-backend:
    uses: adarshraj/platform/.github/workflows/quarkus-build.yml@main
    with:
      image-name: bookshelf-haven-backend
      working-directory: backend
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}

  deploy:
    needs: [build-frontend, build-backend]
    uses: adarshraj/platform/.github/workflows/deploy-portainer.yml@main
    with:
      stack-name: bookshelf-haven
    secrets:
      PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL_BOOKSHELF }}
```

### Required GitHub Secrets

Set these at the **organization level** (GitHub → Settings → Secrets → Actions) so every repo inherits them without repeating the setup:

| Secret | How to get it |
|---|---|
| `INFISICAL_CLIENT_ID` | Infisical UI → your project → Access → Machine Identities → Create |
| `INFISICAL_CLIENT_SECRET` | Same screen as above |
| `PORTAINER_WEBHOOK_URL_<APPNAME>` | Portainer UI → Stacks → your stack → Webhooks → copy URL (one per app) |

`GITHUB_TOKEN` is injected automatically by GitHub — no setup needed.

---

## 10. Adding a New App

See **[docs/adding-new-app.md](docs/adding-new-app.md)** for the complete step-by-step checklist with code snippets.

Summary:
1. Register the app in `SERVICE_CATALOG.md` — pick a subdomain and internal ports
2. Add Traefik labels + `platform_proxy` network to the app's `docker-compose.yml`, remove `ports:`
3. Create a project in Infisical, migrate secrets from `.env` files
4. Replace the app's GitHub Actions workflow with the reusable workflow pattern above
5. Clone the app to `~/apps/<app-name>/` on the server
6. Register and deploy the stack in Portainer, copy the webhook URL to GitHub secrets

---

## 11. Security Model

### Network Security

- Only Traefik has ports `80` and `443` open to the host network
- All app containers use `expose:` (Docker internal only) instead of `ports:`
- Containers without `traefik.enable=true` label are unreachable from outside — not just unauthenticated, no network path exists at all
- Databases (PostgreSQL) are on isolated internal Docker networks, never reachable from outside

### TLS

- All traffic is HTTPS — Traefik redirects HTTP to HTTPS automatically
- Homelab: wildcard cert via `mkcert` (trusted by machines where you run `mkcert -install`)
- Production: Let's Encrypt via Traefik ACME (auto-renews before expiry)
- Traffic between Traefik and containers is plain HTTP inside Docker networks — acceptable because it never leaves the host machine

### Access Control

Three layers of protection are available via Traefik middlewares:

**IP allowlist** — restricts a route to specific IP ranges. Applied to all internal tools (Portainer, Grafana, Infisical) by default:
```yaml
- "traefik.http.routers.portainer.middlewares=internal-only@docker"
# Defined in infra/traefik/docker-compose.yml:
# sourcerange=127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

**Rate limiting** — limits requests per second per IP. Apply to any public-facing app:
```yaml
- "traefik.http.routers.myapp.middlewares=ratelimit@docker"
```

**ForwardAuth** — delegates authentication to your `auth-service`. Traefik calls `/verify` on auth-service before forwarding any request. If auth-service returns 401, Traefik blocks the request. This enables SSO across all apps using your existing auth-service:
```yaml
- "traefik.http.middlewares.app-auth.forwardauth.address=http://auth-service:8703/verify"
- "traefik.http.routers.myapp.middlewares=app-auth"
```

### Secrets Security

- No `.env` files on disk (they get migrated to Infisical)
- Secrets are never stored in git
- The deploy script fetches secrets into a temp file, passes it to docker compose, then immediately deletes it
- Infisical encrypts all secrets at rest using the `INFISICAL_ENCRYPTION_KEY` you generate

---

## 12. Backup & Recovery

### What Gets Backed Up

The `scripts/backup.sh` script (runs daily at 2am via cron) backs up:
- All PostgreSQL databases — one `.sql.gz` dump per database
- Infisical's PostgreSQL data volume (contains all your secrets)
- Loki's data volume (contains your logs)

Backups are stored in `/var/backups/platform/YYYY-MM-DD_HHMMSS/` and kept for 7 days (configurable via `RETENTION_DAYS` in the script).

### Syncing Offsite (Optional but Recommended)

If you have `rclone` configured with a remote named `backup:`, the script automatically syncs to it:
```bash
# Configure rclone to point to any S3-compatible storage (Cloudflare R2, Backblaze B2, MinIO, etc.)
rclone config
# Name the remote "backup"

# Test it
rclone ls backup:
```

### Manual Backup

```bash
./scripts/backup.sh
```

### Recovery

To restore a PostgreSQL database from a backup:
```bash
# Find the backup
ls /var/backups/platform/

# Restore
gunzip -c /var/backups/platform/2024-01-15_020000/bookshelf-db-bookshelf.sql.gz \
  | docker exec -i bookshelf-db psql -U bookshelf bookshelf
```

---

## 13. Troubleshooting

### A service URL returns "404 page not found" from Traefik

The container is running but Traefik can't find a matching route. Check:
1. The container has `traefik.enable=true` label
2. The container is on the `platform_proxy` network
3. The `Host()` rule in the label matches the URL you're visiting exactly
4. Check the Traefik dashboard at `https://traefik.homelab.local` — the route should appear there

### A service URL returns "Gateway Timeout"

Traefik found the route but couldn't reach the container. Check:
1. The container is actually running: `docker ps | grep <name>`
2. The port in `traefik.http.services.<name>.loadbalancer.server.port` matches the port the app listens on inside the container
3. The container is healthy: `docker inspect <name> | grep Health`

### Can't reach homelab.local URLs at all

DNS is not resolving. Check:
1. The entry exists in `/etc/hosts` (or Pi-hole)
2. The IP is correct — `ping traefik.homelab.local` should return the right IP
3. Traefik is running: `docker ps | grep traefik`

### Grafana shows no data

1. Check Promtail is running: `docker ps | grep promtail`
2. Check Loki is healthy: `docker logs loki`
3. In Grafana → Explore → select Loki datasource → run `{job="docker"}` — if no results, Promtail isn't shipping logs
4. Check Promtail has permission to read Docker logs: it needs to run as root or with the docker group

### Infisical CLI can't connect

```bash
infisical login --domain=https://secrets.homelab.local
```
If it fails, check:
1. Infisical container is running: `docker ps | grep infisical`
2. The URL resolves: `curl https://secrets.homelab.local`
3. TLS cert is trusted: no certificate error in browser at `https://secrets.homelab.local`

### GitHub Actions workflow fails on `uses: adarshraj/platform/...`

The `platform` repo is private. GitHub Actions in other repos can call reusable workflows from private repos only if:
1. Both repos are in the same GitHub organization/account — ✓ (you own both)
2. The calling repo has access — this is automatic for repos under the same account

If it still fails, check the workflow file path is exactly correct (case-sensitive).

### Running out of disk space

```bash
# Check what's using space
docker system df

# Clean up unused images (safe to run)
docker image prune -a

# Check log volume size
docker system df -v | grep loki

# Reduce log retention: edit infra/logging/loki-config.yml
# Change: retention_period: 30d  →  retention_period: 7d
# Then restart: cd infra/logging && docker compose restart loki
```
