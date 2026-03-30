# Troubleshooting — New App Onboarding

Common errors when adding a new app to the platform and how to fix them.

---

## Traefik Issues

### "404 page not found" when visiting the app's URL

Traefik is running but has no matching route for this URL.

**Check 1 — Container is actually running:**
```bash
docker ps | grep my-app
```

**Check 2 — Labels are correct:**
```bash
docker inspect my-app-frontend-1 | grep -A2 "traefik"
```
The `traefik.enable=true` label must be present and the `Host()` rule must exactly match the URL you're visiting (case-sensitive).

**Check 3 — Container is on platform_proxy network:**
```bash
docker network inspect platform_proxy | grep my-app
```
If the container isn't listed, it hasn't joined the network. Make sure `platform_proxy` is in the service's `networks:` section AND in the top-level `networks:` block as `external: true`.

**Check 4 — Traefik dashboard:**
Visit `https://traefik.homelab.local` → **HTTP** → **Routers**. Your app's router should appear. If it doesn't, Traefik didn't pick up the labels — restart the container.

---

### "Gateway Timeout" (502/504) when visiting the app's URL

Traefik found the route but can't reach the container.

**Check 1 — Container port matches the label:**
The port in `traefik.http.services.my-app.loadbalancer.server.port` must match what the app actually listens on *inside* the container, not the host.

**Check 2 — App is listening on 0.0.0.0, not 127.0.0.1:**
Some apps default to `localhost` which is not reachable from other containers. Check your app's startup config:
```bash
# Quarkus — application.properties
quarkus.http.host=0.0.0.0

# Node.js — make sure listen binds to 0.0.0.0, not localhost
server.listen(3000, '0.0.0.0')
```

**Check 3 — App crashed on startup:**
```bash
docker logs my-app-backend-1 --tail=50
```
A missing environment variable or failed database connection at startup will cause the container to exit immediately, making it unreachable.

---

### Certificate warning in browser

The wildcard TLS cert is not trusted by your machine.

```bash
# Run mkcert -install on this machine — this trusts the local CA
mkcert -install
```

If this is a device other than the homelab machine (phone, second laptop), copy the CA certificate from the homelab machine and install it manually on that device:
- **File location**: `~/.local/share/mkcert/rootCA.pem` (Linux) or `~/Library/Application Support/mkcert/rootCA.pem` (Mac)
- **iOS**: AirDrop the file to your phone → Settings → Profile Downloaded → Install
- **Android**: Settings → Security → Install from storage

---

### App URL can't be resolved at all (DNS error)

The hostname `my-app.homelab.local` isn't resolving to an IP.

```bash
# Test DNS resolution
ping my-app.homelab.local
```

If it fails, add the entry to `/etc/hosts`:
```
127.0.0.1  my-app.homelab.local
```

Or if using Pi-hole, verify the wildcard `*.homelab.local` entry points to the correct IP.

---

## Portainer Issues

### Stack deployed but containers aren't starting

```bash
# Check stack events in Portainer UI: Stacks → your stack → Events tab
# Or via CLI:
docker compose -f ~/apps/my-app/docker-compose.yml logs
```

Common cause: missing environment variables. The deploy script fetches from Infisical — if the Infisical project doesn't exist or credentials are wrong, secrets are empty and the app fails.

---

### Webhook doesn't trigger a redeploy

**Check 1 — Webhook URL is correct:**
In Portainer → Stacks → your stack → Webhooks — copy the URL fresh and update the GitHub secret.

**Check 2 — GitHub Actions `deploy` job ran:**
Check the Actions tab in your repo — did the `deploy` job run and complete successfully?

**Check 3 — Portainer can reach ghcr.io:**
The webhook triggers a `docker pull`. If the homelab machine has no internet access or ghcr.io is blocked, the pull fails silently. Check:
```bash
docker pull ghcr.io/adarshraj/my-app:latest
```

---

## Infisical Issues

### App starts but environment variables are empty

**Check 1 — Project name matches exactly:**
```bash
infisical secrets get --env=production --projectName=my-app
```
If this returns nothing or an error, the project doesn't exist or is named differently. Project names are case-sensitive.

**Check 2 — Machine Identity has access:**
In Infisical → your project → Access Control → Machine Identities — `github-actions-ci` must be listed with at minimum `reader` role on the `production` environment.

**Check 3 — docker-compose.yml references the variable:**
Even if Infisical has the secret, docker-compose must pass it to the container:
```yaml
environment:
  - MY_VAR=${MY_VAR}   # reads from env file injected by deploy script
```

---

### `infisical run` command fails locally

```bash
# Re-authenticate
infisical login --domain=https://secrets.homelab.local

# Test connection
infisical secrets get --env=dev --projectName=my-app
```

If Infisical is not reachable, check it's running:
```bash
docker ps | grep infisical
```

---

## GitHub Actions Issues

### Workflow fails with "not authorized" on `uses: adarshraj/platform/...`

The `platform` repo is private. GitHub allows calling reusable workflows from private repos in the same account/org — but only if the calling repo has the right access.

Go to: `platform` repo → Settings → Actions → General → scroll to **Access** → set to "Accessible from repositories in the 'adarshraj' organization/account".

---

### Workflow fails on Infisical secrets step

```
Error: Unable to authenticate with Infisical
```

**Check 1 — GitHub secrets are set:**
In your repo (or org) → Settings → Secrets → Actions — verify `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET` exist.

**Check 2 — Machine Identity credentials are correct:**
In Infisical → Organization → Access Control → Machine Identities → `github-actions-ci` → regenerate credentials if needed, update GitHub secrets.

**Check 3 — Infisical is accessible:**
The GitHub Actions runner (running on GitHub's servers) must be able to reach `https://secrets.homelab.local`. This only works if your homelab is publicly accessible. If it's not, the Infisical step will fail.

**Solution for private homelabs**: Skip Infisical in CI and use GitHub secrets directly for build-time vars. Only use Infisical for runtime secrets injected at deploy time via `scripts/deploy-app.sh`.

---

### `docker-build-push.yml` fails — image push permission denied

```
Error: denied: permission_level_insufficient
```

The workflow uses `GITHUB_TOKEN` to push to `ghcr.io`. Ensure the package visibility allows this:
- Go to `ghcr.io` → your package → **Package settings** → **Manage Actions access**
- Add the repo with **Write** role

Or set the package to public (fine for open-source apps).

---

## Logging Issues

### No logs appear in Grafana for my app

**Check 1 — Promtail is running:**
```bash
docker ps | grep promtail
docker logs promtail --tail=20
```

**Check 2 — App is logging to stdout:**
```bash
docker logs my-app-frontend-1 --tail=20
```
If there's no output, the app is not writing to stdout. See the logging guide in the main README.

**Check 3 — Query is correct in Grafana:**
The `stack` label matches the Docker Compose project name — this is the directory name where you ran `docker compose up`, or the stack name in Portainer. Try a broad query first:
```
{container=~"my-app.*"}
```

---

### Logs appear but have no structure (all in `message` field)

The app is logging plain text instead of JSON. Add structured logging as described in the main README — Quarkus: `quarkus.log.console.json=true` in `application.properties`; Node.js: use Pino.

---

## Metrics Issues

### App doesn't appear in Prometheus targets

Visit `http://localhost:9090/targets` — your app should be listed.

If missing:
- Verify the three `prometheus.*` labels are on the correct service in `docker-compose.yml`
- Verify the container is on the `platform_proxy` network (Prometheus needs to reach it)
- Restart the app container so Prometheus rediscovers it

---

### Prometheus scrape fails with "connection refused"

The app container is running but the metrics endpoint isn't responding.

For Quarkus: verify `quarkus-micrometer-registry-prometheus` is in `pom.xml` and the app built successfully.

For Node.js: verify the `/metrics` route is defined and the server is actually listening on the port in `prometheus.port` label.

---

## Verdaccio Issues

### `npm install @adarshraj/my-lib` returns "not found"

**Check 1 — .npmrc is configured:**
```bash
cat .npmrc   # should contain: @adarshraj:registry=https://npm.homelab.local
```

**Check 2 — Package was published:**
```bash
npm view @adarshraj/my-lib --registry https://npm.homelab.local
```

**Check 3 — Verdaccio is running:**
```bash
docker ps | grep verdaccio
curl https://npm.homelab.local
```

---

### `npm publish` fails with "403 Forbidden"

You need to be logged in to Verdaccio with publish rights:
```bash
npm login --registry https://npm.homelab.local
npm publish
```

If still failing: check `verdaccio-config.yml` — the `@adarshraj/*` scope must have `publish: $authenticated`.
