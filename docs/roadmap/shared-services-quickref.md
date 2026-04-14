# Shared Services — Quick Reference

> One-page cheat sheet. Full rationale in [`shared-services.md`](./shared-services.md).
> Read this first when starting any new backend.

## Before writing any new gateway — check this

1. Does the **platform already do it**? → use that, don't build. (see table below)
2. Is the pattern in **≥2 existing apps**? → rule of three fires at the third.
3. Is **`platform-commons` built yet**? → if not, build that before the new gateway.
4. Can you describe the endpoint in **<20 lines of JSON**? → if not, scope is too big.
5. Is there **actual pain** (not just "feels like good architecture")? → if not, wait.

If any answer is "no / not yet", stop and reconsider.

---

## Build priority (read top-down)

| # | Item | Trigger | Effort |
|---|------|---------|--------|
| 1 | **`platform-commons`** Kotlin library | Next time you start a Kotlin+Quarkus gateway | ~1 day |
| 2 | **`scheduler-service`** | When EasyCron annoys you OR auth-service key rotation becomes concrete OR a 3rd app needs scheduled work | ~2 days |
| 3 | **`notification-service`** | Two concrete apps need push/SMS/webhook (NOT just email) | ~2 days |
| 4 | `platform-svelte-commons` | When you start a new frontend app | ~1 day |
| 5 | `file-upload-service` | Second upload-heavy app after activity-generator | ~2 days |
| 6 | `pdf-wrap` | Third app needs PDF output | ~2 days |

---

## `platform-commons` — what gets extracted

From ai-wrap + email-service (already duplicated), pull into a Maven module:

- `filter/RequestLoggingFilter` (request ID → MDC)
- `filter/ResponseLoggingFilter` (`X-Request-Id` echo)
- `filter/SecurityHeadersFilter` (OWASP headers)
- `filter/MethodFilter` (405 allowlist)
- `service/AuditService` (JSON audit log with rotation)
- `service/RateLimiter` + `ratelimit/{Backend, InMemory, Redis}`
- `health/ProviderHealthCheck` base pattern
- `application.properties` %prod profile block (JSON logs, OTLP, service.name)

Publish to Verdaccio. Consumed as:

```xml
<dependency>
  <groupId>com.adars</groupId>
  <artifactId>platform-commons</artifactId>
  <version>0.1.0</version>
</dependency>
```

Rule: if a filter needs to vary per service, it stays in the service. Library is
for identical code only.

---

## `scheduler-service` — shape

```
POST   /schedules                 register
GET    /schedules                 list
GET    /schedules/{id}            details + recent fires
PATCH  /schedules/{id}            update
DELETE /schedules/{id}            unregister
POST   /schedules/{id}/trigger    fire now (test)
```

Registration payload: `{id, cron, target_url, target_method, target_headers, target_payload, retry_policy, timeout_seconds, enabled, owner_app}`

State: Quartz JDBC store (SQLite) + fire history table (rotate 30d).

Auth: JWT via auth-service JWKS. Target apps validate `X-Scheduler-Token`.

Single replica at first. Quartz cluster mode only if you ever scale horizontally.

**Replaces**: vuln-monitor's EasyCron integration, future auth-service key rotation,
future activity-generator Razorpay webhook retries.

---

## `notification-service` — shape

```
POST /notify/send
{
  "channel": "email|push|webhook|sms",
  "target": "...",
  "subject": "...",
  "body_text": "...",
  "body_html": "...",       // email only
  "data": {...},            // push only
  "tag": "...",
  "priority": "low|normal|high"
}
```

Channels:
- **email** → delegates to email-service (don't re-implement)
- **push** → FCM (free tier)
- **webhook** → direct POST
- **sms** → Fast2SMS or MSG91 (free tier for India)

User preference storage: small table `{user_id, channel, tag_pattern}` so the
caller can say "notify user X about Y" and let the service pick the channel.

**Scope discipline**: no templates (caller renders), no digest batching, no
preference UI (belongs in consumer apps).

---

## DO NOT build — the platform already covers it

| Don't build | Use |
|-------------|-----|
| metrics-aggregator | Prometheus |
| log-aggregator | Loki + Promtail |
| secrets-proxy | Infisical |
| blob-storage-service | Garage S3 |
| api-gateway / reverse proxy | Traefik |
| uptime monitor | Uptime Kuma |
| npm registry | Verdaccio |
| distributed tracing | Tempo + OTel Collector |
| workflow engine | n8n (self-host if ever needed) |

---

## The meta-rule

> **Build the shared gateway shape before the third gateway, not the sixth.**
> Every gateway you ship without extracting first costs another ~500 lines of
> copy-paste debt. Pay it down once, pay nothing thereafter.

Platform layer is mature (12+ services). Gateway layer is not. Invest there.

---

## Update this file when

- A new pain pattern emerges in ≥2 apps (add to the list)
- A trigger fires and you start building (remove from list, note in full doc's update log)
- An idea turns out to be wrong or unnecessary (strike it through, don't delete — keep the history)
