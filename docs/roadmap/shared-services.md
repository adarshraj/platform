# Future Shared Services — Notes to Self

> Captured: 2026-04-14 after consolidating 25 apps into `~/Projects/` and noticing
> several cross-cutting patterns worth extracting. This file is a working doc, not
> a roadmap — edit it as your situation changes.

## Why this file exists

Every time you build a new `*-wrap` gateway (ai-wrap, email-service), you copy-paste
the same ~500 lines of infrastructure code. You also have several apps with
uncoordinated cron/scheduling logic, and a notification story that's already visible
on the horizon. Before you build the next new gateway, decide whether to fix these
three things first.

This doc ranks the extractions by **(a)** real observed pain, **(b)** how many apps
benefit, and **(c)** how much it shortens the "build a new gateway" loop.

---

## How to use this file

1. When a new app idea pops up and it "needs to send notifications / run scheduled
   jobs / expose a JWT-gated API", **read this file first** before writing the first
   line of code. The extraction may already be more valuable than the app.
2. When an existing gateway hits a cross-cutting bug (new security header, new
   rate-limit behavior, tighter audit format), note it here as evidence that the
   commons extraction is overdue.
3. When you're about to build a *third* instance of something, that's the "rule of
   three" trigger — do the extraction first, then build the new thing on top.
4. **Don't pre-build**. Every entry below has a "when to actually start" line. If
   the trigger hasn't fired, leave it alone.

---

## Ranking

| Rank | Item | Why now | Why later |
|------|------|---------|-----------|
| **1** | `platform-commons` Kotlin library | Highest leverage, zero risk, unlocks fast new-gateway shipping. Rule-of-three has fired. | — |
| **2** | `scheduler-service` | You already pay for EasyCron. Real existing pain, not speculative. | Quarkus in-process scheduler works until you have multi-replica jobs. |
| **3** | `notification-service` | Email alone doesn't justify it; push/SMS/webhook needs are coming. | Wait for **two** concrete consumers with real push/SMS/webhook needs. |
| **4** | `platform-svelte-commons` shared UI kit | Would cut ~30% of new frontend boilerplate. | Existing Svelte apps are in painful-to-migrate variants. Only helps new apps. |
| **5** | `file-upload-service` | Upload → process → store → URL is a missing middle. | Skip unless you build more upload-heavy apps. |
| **6** | `pdf-wrap` | Two apps already generate PDFs. | Wait for a third. |

Everything below rank 6 is **do not build** — existing platform infrastructure
already covers it.

---

## 1. `platform-commons` — shared Kotlin library

### The pain

While building `email-service`, I copied from `ai-wrap`:

- `filter/RequestLoggingFilter.kt` — request ID → MDC
- `filter/ResponseLoggingFilter.kt` — `X-Request-Id` response header
- `filter/SecurityHeadersFilter.kt` — OWASP headers
- `filter/MethodFilter.kt` — 405 allowlist
- `service/AuditService.kt` — JSON audit log with rotation config
- `service/RateLimiter.kt` + `service/ratelimit/{RateLimiterBackend, InMemory, Redis}.kt` — pluggable counter backend
- `health/ProviderHealthCheck.kt` — readiness base pattern
- `application.properties` %prod profile block — JSON logs, OTLP, `service.name`, Redis devservices disabled, audit log handler

That's ~500 lines of near-identical Kotlin per service. When a cross-cutting concern
changes — say you want to add `Strict-Transport-Security` to OWASP headers, or switch
the rate-limit key format from `rl:min:<user>:<bucket>` to something else — you have
to touch every service.

### The shape

A Maven module `com.adars:platform-commons` published to your Verdaccio registry
(which already runs on the platform). Consumed via:

```xml
<dependency>
  <groupId>com.adars</groupId>
  <artifactId>platform-commons</artifactId>
  <version>0.1.0</version>
</dependency>
```

Submodules:

```
platform-commons/
├── platform-commons-filter/       # 4 filters + request-id regex
├── platform-commons-ratelimit/    # interface + memory + redis impls
├── platform-commons-audit/        # AuditService base + JSON serializer
├── platform-commons-health/       # readiness check base class
└── platform-commons-bom/          # import-able BOM for version alignment
```

The config fragment (`application.properties` prod profile) lives in
`src/main/resources/application-platform-commons.properties` and is loaded via
Quarkus's `@ConfigMapping` or `quarkus.application.properties-file` mechanism.

### What each service still writes itself

- The endpoint (`AiResource`, `MailResource`, etc.)
- The service (`AiService`, `MailService`, etc.)
- Provider integrations (`GeminiImageGenService`, `ResendMailProvider`, etc.)
- Service-specific config keys

Everything cross-cutting disappears from the service's own codebase.

### Effort estimate

- Extract + publish: **4 hours**
- Migrate ai-wrap to consume it: **1 hour** (mostly delete files)
- Migrate email-service to consume it: **1 hour** (same)
- Total: **~1 day** including tests

### When to actually start

**The next time you're about to build a new Kotlin+Quarkus gateway.** Do the
extraction *before* the new service, then build the new service on top. Rule of
three has already fired (ai-wrap, email-service, auth-service has partial overlap).

### Risks

- **Versioning discipline**: every commons change needs a version bump. Start at
  0.1.0, bump minor for additions, patch for fixes. Avoid 1.0.0 until you have 3+
  consumers that have survived a breaking change.
- **Over-abstraction**: resist the urge to make filters "configurable". If a
  filter needs to vary per service, leave it in the service. The library is for
  identical code, not for templates.
- **Verdaccio as single point of failure**: if Verdaccio is down, every service's
  build breaks. Mitigate by enabling Verdaccio's proxy mode so Maven falls back
  to Maven Central if the private registry is unreachable (commons artifacts
  aren't on central, but dependencies are).

---

## 2. `scheduler-service` — cron/trigger gateway

### The pain (observed, not speculative)

- **vuln-monitor** has `src/backend-api/CronScheduler.ts`, `SyncScanInterval.ts`,
  `server/controllers/scanIntervalController.ts` — a whole custom cron
  infrastructure with EasyCron webhooks. **You pay EasyCron for a job a small
  Quarkus service could do for free.**
- **finance-tracker** has its own cron secret + scheduled tasks
- **auth-service** has "JWT signing key rotation" on its roadmap — inherently
  scheduled
- **email-service** (future): bounce retries, batch sending windows
- **activity-generator** (future): Razorpay webhook retries, daily book-limit resets

Each has reinvented: cron parsing, schedule persistence, trigger firing,
retry-on-failure, per-job secrets. No central place to answer "what scheduled jobs
run on my platform".

### The shape

A Quarkus service that runs a persistent Quartz scheduler. Exposes:

```
POST /schedules                 — register a new scheduled job
GET  /schedules                 — list all
GET  /schedules/{id}            — details + recent fire history
PATCH /schedules/{id}           — update cron, target, payload
DELETE /schedules/{id}          — unregister
POST /schedules/{id}/trigger    — fire immediately (for testing)
```

Registration payload:

```json
{
  "id": "vuln-monitor-daily-scan",
  "cron": "0 3 * * *",
  "target_url": "https://vuln-monitor.homelab.local/api/scans/run",
  "target_method": "POST",
  "target_headers": {"X-Scheduler-Token": "..."},
  "target_payload": {"source": "scheduler"},
  "retry_policy": {"max_attempts": 3, "backoff_seconds": 300},
  "timeout_seconds": 600,
  "enabled": true,
  "owner_app": "vuln-monitor"
}
```

When the cron fires, scheduler-service POSTs to `target_url` with the configured
headers and payload. It retries on 5xx and network failures per `retry_policy`.
Every fire (success or failure) is recorded in a local SQLite or Postgres table
for audit.

Auth: registration is JWT-gated via auth-service JWKS (same scheme as all other
platform gateways). The fire itself carries a service token in a header the target
app validates.

### State

- Scheduler state: Quartz JDBC job store (SQLite or the platform's Postgres if
  available)
- Fire history: a small table with `{schedule_id, fired_at, status, http_code,
  attempt, duration_ms, error}` — rotate after 30 days
- No secrets stored beyond target headers (which may contain tokens)

### What each consumer app does

Expose a normal HTTP endpoint. Don't run its own cron. Validate the
`X-Scheduler-Token` header. Done. ~10 lines of code per app.

### Effort estimate

- Core scheduler + REST API + Quartz integration: **6 hours**
- Retry/backoff + audit log: **3 hours**
- Tests: **3 hours**
- Docs + docker-compose + platform registration: **2 hours**
- Migration of vuln-monitor from EasyCron to scheduler-service: **2 hours**
- Total: **~2 days**

### When to actually start

**When you've built `platform-commons`** (so scheduler-service inherits the
observability/auth/rate-limit plumbing for free) **AND** either:
- vuln-monitor's EasyCron bill annoys you, or
- auth-service's key rotation feature becomes concrete, or
- a third app needs scheduled work

### Risks

- **Replacing EasyCron is a real migration** — not risky, but not trivial. vuln-monitor
  has baked in EasyCron-specific retry semantics and signature verification. Read
  its code first.
- **Quartz JDBC job store + SQLite has known edge cases** with misfire handling.
  Either use Quartz in-memory (lose schedules on restart, OK if state is re-registered
  from a manifest file) or use Postgres.
- **Clock skew across replicas**: if you ever run multiple scheduler-service
  replicas, Quartz cluster mode is mandatory or jobs fire multiple times. Start
  with one replica and the platform's auto-restart.

### Alternative: don't build, use n8n

n8n is a self-hostable workflow engine with a real UI. It can schedule HTTP calls
out of the box. If you want a GUI more than you want code, use n8n. The downside is
n8n is a much larger piece of software than a focused scheduler, and you lose the
"same Kotlin+Quarkus patterns everywhere" consistency.

---

## 3. `notification-service` — multi-channel alerts

### The pain (speculative but near-term)

- **activity-generator**: "your PDF is ready" — email today, push if mobile ships
- **vuln-monitor**: CVE alerts — email works but Slack/Discord is more natural for ops
- **finance-tracker**: budget alerts, scheduled reports — email
- **family-health-tracker**: medication reminders — SMS or push is more reliable than email
- **auth-service**: security alerts (login from new device) — should be push or SMS
- **uptime-kuma**: already consumes notifications, but you have no platform-level
  abstraction for "who gets notified about what"

### The shape

Generalized `email-service`. Same JWT auth, same rate-limit pattern, same audit log,
but pluggable delivery channels:

```
POST /notify/send
{
  "channel": "email|push|webhook|sms",
  "target": "...",            # email address, device token, webhook URL, phone number
  "subject": "...",           # optional, ignored for webhook
  "body_text": "...",
  "body_html": "...",         # optional, email-only
  "data": {...},              # optional, push-only (deep link, action)
  "tag": "verify-email|low-balance|cve-critical|...",
  "priority": "low|normal|high"
}
```

### Channels

| Channel | Delivery | Provider |
|---------|----------|----------|
| `email` | `POST /mail/send` to email-service | **Delegates** — doesn't re-implement email |
| `push` | Firebase Cloud Messaging (free) or APNS | New integration |
| `webhook` | Direct `POST` to caller-supplied URL with payload | None |
| `sms` | Fast2SMS or MSG91 (both have free tiers for India) | New integration |

Email is a straight passthrough to email-service — no reason to duplicate.

### What each consumer app does

Stop choosing a channel. Let notification-service pick the best channel for a given
user based on preferences stored in a small user-preferences table keyed by user
ID. E.g. user A wants push for receipts, email for monthly summaries; user B wants
everything via email only.

### Effort estimate

- Core service + email passthrough: **3 hours**
- FCM integration: **4 hours**
- Fast2SMS integration: **3 hours** (simpler than FCM)
- Webhook channel: **1 hour**
- User preference storage: **3 hours**
- Tests + docs: **4 hours**
- Total: **~2 days**

### When to actually start

**Wait for two concrete consumers** that need push or SMS (not email, which
email-service already handles). Until then this is speculation. The trigger is:
"I'm writing a push notification in app #2 this week and I already wrote one in
app #1 last month."

### Risks

- **FCM/APNS device token management is its own problem** — tokens expire, need
  refresh, need to be tied to user IDs. That's a table and a sync flow. Non-trivial.
- **Indian SMS providers have flakey APIs** — Fast2SMS occasionally rate-limits
  legitimate traffic. Plan for fallback to email on SMS failure.
- **Scope creep**: "notification service" is a magnet for "can it also do X". Say
  no to: templates (callers render their own bodies, same as email-service),
  digest batching (that's a separate scheduled-notification concept),
  preference UIs (belongs in the consumer app, not the gateway).

---

## 4. `platform-svelte-commons` — shared Svelte UI library

### The pain

Every app I've seen has its own:
- Settings page layout
- "Logged in as X" header with logout
- Toast/notification component
- Form field wrappers with validation
- Breadcrumb navigation
- Loading spinner
- Error boundary with friendly fallback

Most are reimplemented per-app because the apps started from different templates
(SvelteKit, Vite+Svelte, nut.new conversions).

### The shape

Publish a Svelte component library to Verdaccio as `@adars/platform-svelte-commons`.
Components:

```
<AppShell />              # header + sidebar + main + footer layout
<AuthStatus />            # current user + logout, reads from a pluggable auth store
<Toast />                 # imperative toast API: showToast("message")
<Field />                 # form field with label, error, dirty state
<Breadcrumb />            # auto-computed from route
<Loading />               # spinner + skeleton
<ErrorBoundary />         # catches child errors, shows fallback
```

Plus utility hooks for JWT fetching, debounced state, localStorage-backed stores.

### Why this is weaker

- The existing SvelteKit/Vite/nut.new variants don't share a build system, so
  integration is painful
- Tailwind CSS config drift across apps means the library either ships with its
  own styles (won't match) or requires consumers to install specific plugins
- Svelte 5 runes are rolling out and component APIs may churn
- It only helps **new** apps — migration of existing apps isn't worth it

### When to actually start

**When you start a new frontend app** and find yourself copying files from an
existing one. Build the commons library *first*, then use it for the new app.
Don't retrofit existing apps.

### Effort estimate

- ~1 day to extract and publish
- ~30 min per new app to consume

---

## 5. `file-upload-service`

### The observed pattern

- activity-generator needs to upload generated PDFs somewhere (Garage S3 today?)
- DocBucket already handles doc storage, but doesn't do thumbnailing/transforms
- HeicConvert is a specialized single-format converter
- Several apps want "upload this image, get back a public URL"

The missing middle is: upload → validate → process (resize, thumbnail, format
convert) → store (Garage) → return URL.

### The shape

`POST /upload` multipart endpoint:
- Validates MIME type and size against caller's config
- Optionally runs transforms (resize, HEIC→JPEG, PDF→preview image)
- Stores in Garage S3
- Returns `{url, mime_type, size_bytes, width, height}`

### Why delay

You haven't hit this pain yet. activity-generator is the first real test case.
If it ships and a second app needs the same thing, build this. Otherwise the
specific apps can talk to Garage directly.

---

## 6. `pdf-wrap`

### The observed pattern

- activity-generator: uses pdfkit (Node)
- HomeUtils: just added openhtmltopdf (Java) for the docconvert utility
- If a third app needs PDF (receipts, invoices, exports), three is the trigger

### The shape

`POST /pdf/render` — accepts HTML or Markdown, returns PDF bytes or a Garage URL.

### Why delay

Rule of three hasn't fired. Two apps that each chose different libraries for
one-off needs aren't pain yet. Revisit when app #3 needs PDF output.

---

## Do NOT build these — existing infrastructure covers it

| Don't build | Use instead |
|-------------|-------------|
| metrics-aggregator | Prometheus (already in platform) |
| log-aggregator | Loki + Promtail (already in platform) |
| secrets-proxy | Infisical (already in platform) |
| blob-storage-service | Garage S3 (already in platform) |
| api-gateway / reverse proxy | Traefik (already in platform) |
| uptime monitor | Uptime Kuma (already in platform) |
| npm registry | Verdaccio (already in platform) |
| distributed tracing | Tempo + OpenTelemetry Collector (already in platform) |
| workflow engine | Use n8n or a hosted alternative if you ever need it; don't build |

---

## The meta-lesson

You have a **mature platform layer** (12+ infra services) and an **immature
application-gateway layer** (3 gateways today, each slightly different because
you learned while building).

The right move is **not "build more gateways"** — it's **"extract the shared
gateway shape so the next gateway takes an hour, not a day."** That's what
`platform-commons` (item #1) buys you.

After that, specific gateways (notification, scheduler, pdf, upload, whatever)
become *tactical* decisions driven by app-level pain, not infrastructure hunches.

---

## Checklist for "should I build gateway X?"

Before starting any new gateway:

1. **Is it a gateway pattern or app logic?** If it's something one specific app
   uses, build it inside that app. Only extract when ≥2 apps need it.
2. **Has the rule-of-three fired?** Count how many places have the pattern today.
   If <3, note it here and wait.
3. **Is `platform-commons` built?** If not, build that first. Otherwise you're
   copy-pasting ~500 lines for the third time.
4. **Does the platform already do it?** Check the "Do NOT build" table above.
5. **Is it pain, or speculation?** If no existing app is hurting, don't build.
6. **Can you write the "why this exists" paragraph in two sentences?** If not,
   the idea isn't clear enough yet.
7. **Can you draw the endpoint contract in <20 lines of JSON?** If not, the scope
   is too big — cut it down.

If all seven pass, build it.

---

## Update log

- **2026-04-14** — Created. Captured after the cross-project session that
  consolidated 25 apps to `~/Projects/` and shipped email-service, auth-service
  email verification, ai-wrap image generation, and vuln-monitor cleanup.
