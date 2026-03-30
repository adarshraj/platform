# App Resilience Guide

Patterns every app in this platform should implement. The platform handles infrastructure resilience (container restarts, health checks, routing); this guide covers what your application code must do.

---

## 1. Startup Resilience — Wait for Dependencies

Your app will start before its dependencies are ready. Don't crash — retry.

### Quarkus (database)

Quarkus + Hibernate handles this automatically if you set a retry in `application.properties`:

```properties
# application.properties
quarkus.datasource.jdbc.acquisition-timeout=30
quarkus.datasource.jdbc.initial-size=1

# Retry the initial connection attempts
%prod.quarkus.datasource.jdbc.url=jdbc:postgresql://db:5432/mydb
```

For external HTTP services, use MicroProfile Fault Tolerance:

```xml
<!-- pom.xml -->
<dependency>
  <groupId>io.quarkus</groupId>
  <artifactId>quarkus-smallrye-fault-tolerance</artifactId>
</dependency>
```

```java
import org.eclipse.microprofile.faulttolerance.Retry;
import java.time.temporal.ChronoUnit;

@ApplicationScoped
public class AuthClient {

    @Retry(maxRetries = 5, delay = 2, delayUnit = ChronoUnit.SECONDS,
           jitter = 500, jitterDelayUnit = ChronoUnit.MILLIS)
    public TokenResponse validateToken(String token) {
        // HTTP call to auth-service
    }
}
```

### Node.js (database)

```js
// db.js — PostgreSQL with pg
import pg from 'pg';

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// Retry loop at startup
async function waitForDb(retries = 10, delayMs = 3000) {
  for (let i = 0; i < retries; i++) {
    try {
      const client = await pool.connect();
      client.release();
      console.log('Database connected');
      return;
    } catch (err) {
      console.warn(`DB not ready (attempt ${i + 1}/${retries}): ${err.message}`);
      await new Promise(r => setTimeout(r, delayMs));
    }
  }
  throw new Error('Could not connect to database after retries');
}

// Call before starting the server
await waitForDb();
```

---

## 2. Runtime Resilience — Circuit Breaker + Fallback

If a dependency goes down while your app is running, fail fast and return a safe fallback.

### Quarkus

```java
import org.eclipse.microprofile.faulttolerance.CircuitBreaker;
import org.eclipse.microprofile.faulttolerance.Fallback;
import org.eclipse.microprofile.faulttolerance.Timeout;
import java.time.temporal.ChronoUnit;

@ApplicationScoped
public class AiWrapClient {

    @Timeout(value = 30, unit = ChronoUnit.SECONDS)
    @Retry(maxRetries = 2)
    @CircuitBreaker(
        requestVolumeThreshold = 5,
        failureRatio = 0.6,
        delay = 30,
        delayUnit = ChronoUnit.SECONDS
    )
    @Fallback(fallbackMethod = "aiUnavailableFallback")
    public String getSuggestion(String prompt) {
        // HTTP call to ai-wrap
    }

    private String aiUnavailableFallback(String prompt) {
        return "AI suggestions are temporarily unavailable.";
    }
}
```

### Node.js

```js
// Simple in-memory circuit breaker
class CircuitBreaker {
  constructor({ threshold = 5, timeout = 30000 } = {}) {
    this.failures = 0;
    this.threshold = threshold;
    this.timeout = timeout;
    this.state = 'CLOSED'; // CLOSED | OPEN | HALF_OPEN
    this.nextAttempt = Date.now();
  }

  async call(fn, fallback) {
    if (this.state === 'OPEN') {
      if (Date.now() < this.nextAttempt) {
        return fallback ? fallback() : Promise.reject(new Error('Circuit open'));
      }
      this.state = 'HALF_OPEN';
    }

    try {
      const result = await fn();
      this.onSuccess();
      return result;
    } catch (err) {
      this.onFailure();
      if (fallback) return fallback();
      throw err;
    }
  }

  onSuccess() { this.failures = 0; this.state = 'CLOSED'; }
  onFailure() {
    this.failures++;
    if (this.failures >= this.threshold) {
      this.state = 'OPEN';
      this.nextAttempt = Date.now() + this.timeout;
    }
  }
}

// Usage
const aiBreaker = new CircuitBreaker({ threshold: 5, timeout: 30_000 });

async function getSuggestion(prompt) {
  return aiBreaker.call(
    () => callAiWrap(prompt),
    () => 'AI suggestions are temporarily unavailable.'
  );
}
```

---

## 3. Health Checks

Every app must expose a health endpoint and declare it in `docker-compose.yml`.

### Quarkus

Add SmallRye Health (included by default with `quarkus-smallrye-health`):

```properties
# application.properties
quarkus.smallrye-health.ui.enable=false   # optional, disables the UI
```

Endpoints are automatically available:
- `GET /q/health/live` — liveness (is the process running?)
- `GET /q/health/ready` — readiness (is it ready to serve traffic?)

Declare them in `docker-compose.yml`:

```yaml
services:
  backend:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/q/health/ready"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s   # Quarkus cold start can be slow
```

### Node.js / SvelteKit

Add a `/health` route:

```js
// Express / Fastify
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});
```

```yaml
# docker-compose.yml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s
```

---

## 4. Graceful Shutdown

Handle SIGTERM so in-flight requests complete before the container stops.

### Quarkus

Automatic. Quarkus listens for SIGTERM and finishes active requests (default 10s drain). You can adjust:

```properties
quarkus.shutdown.timeout=15S
```

### Node.js

```js
const server = app.listen(3000, '0.0.0.0');

function shutdown(signal) {
  console.log(`Received ${signal}, shutting down gracefully`);
  server.close(() => {
    console.log('HTTP server closed');
    pool.end(() => process.exit(0));   // close DB pool
  });

  // Force exit if shutdown takes too long
  setTimeout(() => {
    console.error('Forced shutdown after timeout');
    process.exit(1);
  }, 10_000);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
```

---

## 5. Timeouts on All External Calls

Every HTTP call to another service must have a timeout. No exceptions.

### Quarkus — MicroProfile REST Client

```properties
# application.properties
# Global timeout for all REST clients (ms)
quarkus.rest-client.read-timeout=10000
quarkus.rest-client.connect-timeout=5000
```

Or per-client:

```java
@RegisterRestClient(configKey = "auth-service")
@ClientHeaderParam(name = "Content-Type", value = "application/json")
public interface AuthServiceClient {
    @GET @Path("/validate")
    TokenInfo validate(@QueryParam("token") String token);
}
```

```properties
quarkus.rest-client.auth-service.url=http://auth-service:8703
quarkus.rest-client.auth-service.read-timeout=5000
```

### Node.js — fetch with AbortSignal

```js
async function callAuthService(token) {
  const response = await fetch(`http://auth-service:8703/validate?token=${token}`, {
    signal: AbortSignal.timeout(5000),   // 5 second timeout
  });

  if (!response.ok) {
    throw new Error(`Auth service returned ${response.status}`);
  }
  return response.json();
}
```

---

## 6. Database Connection Pool Sizing

Don't use defaults. Set explicit limits that match your container's resources.

### Quarkus

```properties
# application.properties
quarkus.datasource.jdbc.min-size=2
quarkus.datasource.jdbc.max-size=10
quarkus.datasource.jdbc.acquisition-timeout=30     # seconds to wait for a connection
quarkus.datasource.jdbc.leak-detection-interval=2M  # warn on unreturned connections
```

### Node.js (pg)

```js
const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  min: 2,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

// Log pool errors — these are silent by default
pool.on('error', (err) => {
  console.error('Unexpected pool error', err);
});
```

---

## 7. Environment Variable Validation — Fail Fast

If a required env var is missing, crash immediately on startup with a clear message. Failing silently produces impossible-to-debug runtime errors.

### Quarkus

```java
// src/main/java/config/AppConfig.java
@ApplicationScoped
public class AppConfig {

    @ConfigProperty(name = "auth.service.url")
    String authServiceUrl;

    @ConfigProperty(name = "database.url")
    String databaseUrl;

    // Quarkus will throw a deployment exception if these are missing.
    // No extra code needed — @ConfigProperty with no defaultValue is required by default.
}
```

### Node.js

```js
// config.js — run before anything else
const REQUIRED = [
  'DATABASE_URL',
  'AUTH_SERVICE_URL',
  'SESSION_SECRET',
];

const missing = REQUIRED.filter(k => !process.env[k]);

if (missing.length > 0) {
  console.error(`Missing required environment variables: ${missing.join(', ')}`);
  process.exit(1);
}

export const config = {
  databaseUrl:    process.env.DATABASE_URL,
  authServiceUrl: process.env.AUTH_SERVICE_URL,
  sessionSecret:  process.env.SESSION_SECRET,
  port:           parseInt(process.env.PORT ?? '3000', 10),
};
```

Import `config.js` before any other module in your entry point.

---

## 8. Structured Logging

Logs must be JSON so Loki can query them. Plain text logs are unsearchable.

### Quarkus

```properties
# application.properties
quarkus.log.console.json=true
quarkus.log.console.json.pretty-print=false   # must be false in production
```

Logs automatically include: timestamp, level, logger name, message, thread, traceId (if OpenTelemetry is present).

### Node.js — Pino

```bash
npm install pino pino-pretty
```

```js
// logger.js
import pino from 'pino';

export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  // In production: plain JSON to stdout
  // In dev: use pino-pretty (add to dev start script: | pino-pretty)
});
```

```js
// Usage
import { logger } from './logger.js';

logger.info({ userId, action: 'login' }, 'User logged in');
logger.error({ err, requestId }, 'Failed to fetch AI suggestion');
```

---

## Summary — What to Add to Every App

| Area | Quarkus | Node.js |
|---|---|---|
| Startup retry | `@Retry` on external calls | `waitForDb()` loop |
| Circuit breaker | `@CircuitBreaker` + `@Fallback` | `CircuitBreaker` class |
| Health check | `/q/health/ready` (built-in) | `GET /health` route |
| docker-compose healthcheck | `curl /q/health/ready` | `curl /health` |
| Graceful shutdown | Automatic (SIGTERM) | `process.on('SIGTERM', ...)` |
| DB pool limits | `jdbc.max-size=10` | `pg.Pool({ max: 10 })` |
| Timeouts | `rest-client.read-timeout=10000` | `AbortSignal.timeout(5000)` |
| Env var validation | `@ConfigProperty` (built-in) | explicit check + `process.exit(1)` |
| Structured logs | `quarkus.log.console.json=true` | Pino |
