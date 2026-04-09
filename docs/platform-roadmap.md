# Platform Roadmap

Enhancements identified for the platform, grouped by priority. Items marked **done** have been implemented.

## Done

- **Blackbox exporter** — HTTP probe monitoring for all endpoints via Prometheus. Alerts on downtime, slow responses, and expiring SSL certs. Config: `infra/monitoring/blackbox.yml`, targets in `prometheus.yml`.
- **Platform CI validation** — GitHub Actions workflow (`.github/workflows/validate-platform.yml`) runs yamllint, shellcheck, docker compose config, and services.yaml structure validation on PRs.
- **lint-platform.sh** — Local version of CI checks (`scripts/lint-platform.sh`). Run before committing.
- **Backup verification** — `scripts/verify-backup.sh` validates pg_dump integrity, tar archive integrity, generates SHA256 checksums. Runs daily at 2:30am via cron.
- **CrowdSec + Traefik bouncer** — Automated threat detection and IP blocking. CrowdSec parses Traefik access logs + community threat feeds. Bouncer plugin blocks flagged IPs at the entrypoint level (all HTTPS traffic). Config: `infra/traefik/crowdsec/`, `infra/traefik/dynamic/crowdsec.yml`. Setup: copy `.env.example` to `.env`, run `docker exec crowdsec cscli bouncers add traefik-bouncer`, paste key.
- **ForwardAuth SSO for admin UIs** — Unified login across Portainer, Grafana, Infisical, and Verdaccio using the existing auth-service. Added `/auth/verify` endpoint + `platform_session` cookie to auth-service. Traefik ForwardAuth middleware (`admin-auth@file`) chains IP allowlist + SSO. Config: `infra/traefik/dynamic/forwardauth.yml`. Auth-service needs `AUTH_SESSION_COOKIE_DOMAIN=.homelab.local` env var.
- **Uptime Kuma** — Public status page at `status.homelab.local`. Shows service availability for non-engineers. Config: `infra/uptime-kuma/docker-compose.yml`. Built-in admin login (set on first visit).
- **Redis** — Shared cache service for all platform apps (opt-in per app). 128MB LRU, password-protected, append-only persistence. Config: `infra/redis/docker-compose.yml`. Per-app integration guide: `docs/redis-caching.md`.
- **Garage (S3 Object Storage)** — Self-hosted S3-compatible storage via Garage. Primary use case: storage backend for DocBucket. Accessible at `s3.homelab.local` or `garage:3900` from Docker network. Config: `infra/garage/docker-compose.yml` + `garage.toml`.

### Signed images (cosign)
**Priority: Medium | Effort: Low (CI) / Medium (deploy verify)**

Sign container images after push in CI using keyless cosign (Sigstore/Fulcio).
- Add `sigstore/cosign-installer` step to `docker-build-push.yml` and `quarkus-build.yml`
- After `docker/build-push-action`, run `cosign sign --yes <image>@<digest>`
- Uses GitHub OIDC for keyless signing — no key management needed
- Optional: add `cosign verify` to `deploy-app.sh` before `docker compose pull`

---

## Observability

### Tempo + Distributed Tracing
**Priority: Medium | Effort: High (per-app instrumentation)**

Add Grafana Tempo for distributed trace storage alongside Loki logs.
- Add `grafana/tempo:latest` to monitoring stack on `monitoring_internal`
- Configure as Grafana datasource (like Loki)
- **Per-app work required:**
  - Quarkus apps: add `quarkus-opentelemetry` extension, configure OTLP exporter to Tempo
  - Node/SvelteKit apps: add `@opentelemetry/sdk-node` + `@opentelemetry/auto-instrumentations-node`
- Once tracing exists, configure Loki↔Tempo correlation via `trace_id` derived fields in Grafana

### Structured Log / Trace Correlation
**Priority: Low | Effort: Low (docs) / Medium (per-app)**

Depends on Tempo. Define a convention:
- Apps emit `trace_id` field in structured JSON logs
- Add Promtail pipeline stage to extract `trace_id` as a label
- Configure Grafana derived fields on Loki datasource to link `trace_id` → Tempo

---

## Platform DX

### services.yaml Generator / Scaffolding
**Priority: Medium | Effort: Medium**

Script that reads `services.yaml` and generates:
- Skeleton `docker-compose.yml` with correct Traefik labels, network attachments, Prometheus scrape labels, resource limits
- Matching entry in `services.yaml` for new apps
- Reduces copy-paste errors when onboarding new apps
- Pattern already exists: `deploy-app.sh` and `bootstrap.sh` parse `services.yaml` via yq

---

## Data & Backups

### Object-Store Lifecycle Documentation
**Priority: Low | Effort: Low**

Document S3/R2 versioning and retention policies for rclone backup targets:
- Bucket versioning settings
- Lifecycle rules (e.g., move to infrequent access after 30d, delete after 90d)
- Example rclone config for Cloudflare R2 or AWS S3

---

## Networking

### Tailscale / VPN Admin Access Guide
**Priority: Low | Effort: Low**

Consolidate remote admin access patterns:
- Add `100.64.0.0/10` to `internal-only` middleware sourcerange for Tailscale
- Document admin-only subnet routing
- Optional: Tailscale ACL tags for platform admin vs app developer access
- Reference: existing comment in `infra/traefik/docker-compose.yml` line 35

---

## Nice-to-Have (Future)

### Self-Hosted GitHub Actions Runners
Useful at larger scale or when CI needs access to internal services (Verdaccio, Infisical). Use `myoung34/github-runner` or official `actions/runner`. Switch workflows to `runs-on: self-hosted`.

### ~~Garage (S3-Compatible Object Storage)~~ → Done
Moved to Done. Implemented in `infra/garage/`.

### Woodpecker / Drone (LAN-only CI)
Redundant with GitHub Actions unless air-gapped CI is required. Defer indefinitely.
