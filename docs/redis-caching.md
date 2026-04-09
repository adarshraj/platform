# Enabling Redis Caching in Your App

This guide covers how to add Redis caching to your application. Redis is a shared platform service — your app opts in by adding a client library and cache logic. Apps that don't use Redis are completely unaffected.

> **Prerequisite**: Redis must be running on the platform (`infra/redis`). If Redis is down, your app should still work — just slower (see [Handling Redis Downtime](#handling-redis-downtime)).

---

## Table of Contents

1. [Add Redis Password to Infisical](#1-add-redis-password-to-infisical)
2. [Add Environment Variable to docker-compose.yml](#2-add-environment-variable-to-docker-composeyml)
3. [Framework-Specific Setup](#3-framework-specific-setup)
   - [Kotlin / Spring Boot](#kotlin--spring-boot)
   - [Kotlin / Quarkus](#kotlin--quarkus)
   - [Node.js / SvelteKit](#nodejs--sveltekit)
   - [Python](#python)
4. [Handling Redis Downtime](#4-handling-redis-downtime)
5. [What to Cache (and What Not To)](#5-what-to-cache-and-what-not-to)
6. [Verifying It Works](#6-verifying-it-works)

---

## 1. Add Redis Password to Infisical

Add `REDIS_PASSWORD` to your app's Infisical project (both `dev` and `production` environments). Use the same password you set in `infra/redis/.env`.

```bash
infisical secrets set REDIS_PASSWORD=your-redis-password --env=dev --projectName=my-app
infisical secrets set REDIS_PASSWORD=your-redis-password --env=production --projectName=my-app
```

---

## 2. Add Environment Variable to docker-compose.yml

In your app's `docker-compose.yml`, add `REDIS_PASSWORD` to the backend/app service:

```yaml
services:
  backend:
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD}
```

No other docker-compose changes needed — your app is already on `platform_proxy` and can reach `redis:6379`.

---

## 3. Framework-Specific Setup

### Kotlin / Spring Boot

**Step 1 — Add dependency** (`build.gradle.kts`):

```kotlin
implementation("org.springframework.boot:spring-boot-starter-data-redis")
```

**Step 2 — Configure** (`application.yml`):

```yaml
spring:
  data:
    redis:
      host: redis
      port: 6379
      password: ${REDIS_PASSWORD}
      timeout: 2000ms
  cache:
    type: redis
    redis:
      time-to-live: 60000   # default TTL: 60 seconds
```

**Step 3 — Enable caching** (main application class):

```kotlin
@SpringBootApplication
@EnableCaching
class MyApplication
```

**Step 4 — Cache methods**:

```kotlin
@Service
class StatsService(private val repository: StatsRepository) {

    @Cacheable("stats", key = "#userId")
    fun getStats(userId: Long): StatsDto {
        // This only runs on cache miss
        return repository.findExpensiveStats(userId)
    }

    @CacheEvict("stats", key = "#userId")
    fun updateStats(userId: Long, stats: StatsDto) {
        // Evicts the cache when data changes
        repository.save(stats)
    }
}
```

**Graceful fallback** — add to `application.yml`:

```yaml
spring:
  cache:
    redis:
      enable-statistics: true
    # Silently skip cache on Redis failure
    type: redis
  data:
    redis:
      connect-timeout: 2000ms
```

Add a custom error handler:

```kotlin
@Configuration
class CacheConfig : CachingConfigurerSupport() {
    override fun errorHandler(): CacheErrorHandler {
        return object : SimpleCacheErrorHandler() {
            override fun handleCacheGetError(exception: RuntimeException, cache: Cache, key: Any) {
                // Log and skip — app continues without cache
                logger.warn("Cache get failed for key {}: {}", key, exception.message)
            }
            override fun handleCachePutError(exception: RuntimeException, cache: Cache, key: Any, value: Any?) {
                logger.warn("Cache put failed for key {}: {}", key, exception.message)
            }
        }
    }
}
```

---

### Kotlin / Quarkus

**Step 1 — Add dependency** (`pom.xml`):

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-redis-client</artifactId>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-cache</artifactId>
</dependency>
```

**Step 2 — Configure** (`application.properties`):

```properties
quarkus.redis.hosts=redis://redis:6379
quarkus.redis.password=${REDIS_PASSWORD}
quarkus.redis.timeout=2s
```

**Step 3 — Cache methods**:

```kotlin
@ApplicationScoped
class StatsService(private val repository: StatsRepository) {

    @CacheResult(cacheName = "stats")
    fun getStats(@CacheKey userId: Long): StatsDto {
        return repository.findExpensiveStats(userId)
    }

    @CacheInvalidate(cacheName = "stats")
    fun updateStats(@CacheKey userId: Long, stats: StatsDto) {
        repository.save(stats)
    }
}
```

**Step 4 — Direct Redis client** (for advanced use cases):

```kotlin
@ApplicationScoped
class CacheService(@Inject val redis: ReactiveRedisClient) {

    fun get(key: String): String? {
        return try {
            redis.get(key).await().indefinitely()?.toString()
        } catch (e: Exception) {
            null  // Redis down — skip cache
        }
    }

    fun set(key: String, value: String, ttlSeconds: Long = 60) {
        try {
            redis.setex(key, ttlSeconds.toString(), value).await().indefinitely()
        } catch (e: Exception) {
            // Redis down — skip silently
        }
    }
}
```

---

### Node.js / SvelteKit

**Step 1 — Install**:

```bash
npm install ioredis
```

**Step 2 — Create a cache utility** (`src/lib/server/cache.ts`):

```typescript
import Redis from 'ioredis'

const redis = new Redis({
  host: 'redis',
  port: 6379,
  password: process.env.REDIS_PASSWORD,
  connectTimeout: 2000,
  maxRetriesPerRequest: 1,
  // Don't crash if Redis is down
  lazyConnect: true,
  retryStrategy(times) {
    if (times > 3) return null  // stop retrying
    return Math.min(times * 200, 1000)
  }
})

redis.on('error', (err) => {
  console.warn('Redis connection error (cache will be skipped):', err.message)
})

/**
 * Get a cached value, or compute and cache it.
 * If Redis is down, the fallback function runs every time (no cache).
 */
export async function cached<T>(
  key: string,
  ttlSeconds: number,
  fn: () => Promise<T>
): Promise<T> {
  try {
    const hit = await redis.get(key)
    if (hit) return JSON.parse(hit)
  } catch {
    // Redis down — fall through to fn()
  }

  const result = await fn()

  try {
    await redis.setex(key, ttlSeconds, JSON.stringify(result))
  } catch {
    // Redis down — skip caching
  }

  return result
}

/**
 * Invalidate a cache key when data changes.
 */
export async function invalidate(key: string): Promise<void> {
  try {
    await redis.del(key)
  } catch {
    // Redis down — skip
  }
}
```

**Step 3 — Use in your routes** (`src/routes/api/stats/+server.ts`):

```typescript
import { cached } from '$lib/server/cache'
import { db } from '$lib/server/db'

export async function GET({ params }) {
  const stats = await cached(`stats:${params.userId}`, 60, async () => {
    // This only runs on cache miss
    return db.query('SELECT ... expensive join ...')
  })

  return Response.json(stats)
}
```

---

### Python

**Step 1 — Install**:

```bash
pip install redis
```

**Step 2 — Create a cache utility** (`cache.py`):

```python
import json
import os
import redis

_client = None

def _get_client():
    global _client
    if _client is None:
        _client = redis.Redis(
            host='redis',
            port=6379,
            password=os.environ.get('REDIS_PASSWORD'),
            socket_connect_timeout=2,
            socket_timeout=2,
            decode_responses=True,
        )
    return _client

def cached(key: str, ttl_seconds: int, fn):
    """Get from cache or compute and store."""
    try:
        hit = _get_client().get(key)
        if hit:
            return json.loads(hit)
    except redis.ConnectionError:
        pass  # Redis down — skip cache

    result = fn()

    try:
        _get_client().setex(key, ttl_seconds, json.dumps(result))
    except redis.ConnectionError:
        pass  # Redis down — skip

    return result

def invalidate(key: str):
    """Remove a key from cache."""
    try:
        _get_client().delete(key)
    except redis.ConnectionError:
        pass
```

**Step 3 — Use it**:

```python
from cache import cached, invalidate

def get_stats(user_id):
    return cached(
        f"stats:{user_id}",
        60,
        lambda: db.query("SELECT ... expensive join ...")
    )

def update_stats(user_id, data):
    db.save(data)
    invalidate(f"stats:{user_id}")
```

---

## 4. Handling Redis Downtime

All the examples above handle Redis failures gracefully. The pattern is always the same:

1. Try to read from cache
2. If Redis is down or key doesn't exist → run the actual query
3. Try to store the result in cache
4. If Redis is down → skip silently

**Your app must never crash because Redis is unavailable.** Cache is an optimization, not a requirement.

---

## 5. What to Cache (and What Not To)

### Good candidates for caching

| What | Why | Suggested TTL |
|---|---|---|
| Expensive database queries | Avoid repeated slow joins/aggregations | 30-120 seconds |
| External API responses | Reduce latency and API rate limit usage | 60-300 seconds |
| Computed dashboards/stats | Same data shown to many users | 30-60 seconds |
| User session data | Fast auth checks | Match session expiry |
| Configuration / feature flags | Rarely changes | 300-600 seconds |

### Bad candidates for caching

| What | Why |
|---|---|
| Data that changes every request | Cache will always be stale |
| Security-sensitive data (passwords, tokens) | Risk of leaking via cache |
| Large blobs (files, images) | Redis is in-memory — use object storage instead |
| Data that must be real-time accurate | Even 1 second of staleness is unacceptable |

### Cache key naming convention

Use a consistent prefix pattern: `{app}:{entity}:{id}`

```
bookshelf:stats:user:42
vahan:vehicle:KA01AB1234
finance:monthly-summary:2024-03
```

---

## 6. Verifying It Works

### Check Redis is running

```bash
docker exec redis redis-cli -a "$REDIS_PASSWORD" ping
# Expected: PONG
```

### Check your app is writing to Redis

```bash
# List all keys (don't use in production with many keys)
docker exec redis redis-cli -a "$REDIS_PASSWORD" keys '*'

# Check a specific key
docker exec redis redis-cli -a "$REDIS_PASSWORD" get "stats:user:42"

# Monitor commands in real time
docker exec redis redis-cli -a "$REDIS_PASSWORD" monitor
```

### Check memory usage

```bash
docker exec redis redis-cli -a "$REDIS_PASSWORD" info memory
# Look for: used_memory_human, maxmemory_human
```
