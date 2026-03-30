# Adding a New Application

Checklist for onboarding any new app or library into the platform. Follow in order.

---

## 1. Register in SERVICE_CATALOG.md

Add a row to the appropriate section in `SERVICE_CATALOG.md`:
- Pick a subdomain (e.g. `myapp.homelab.local`)
- Pick internal container ports (frontend: 3000, Quarkus backend: 8080)
- Set status to `pending`

---

## 2. Update the App's docker-compose.yml

### Add Traefik labels to each public-facing service

```yaml
services:
  frontend:
    # ... existing config ...
    networks:
      - platform_proxy          # ADD
    labels:                     # ADD
      - "traefik.enable=true"
      - "traefik.http.routers.<app-name>.rule=Host(`<app-name>.homelab.local`)"
      - "traefik.http.routers.<app-name>.entrypoints=websecure"
      - "traefik.http.routers.<app-name>.tls=true"
      - "traefik.http.services.<app-name>.loadbalancer.server.port=3000"
      # Optional: attach security middlewares
      # - "traefik.http.routers.<app-name>.middlewares=ratelimit@docker,secure-headers@docker"

  backend:
    # ... existing config ...
    networks:
      - platform_proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<app-name>-api.rule=Host(`<app-name>.homelab.local`) && PathPrefix(`/api`)"
      - "traefik.http.routers.<app-name>-api.entrypoints=websecure"
      - "traefik.http.routers.<app-name>-api.tls=true"
      - "traefik.http.services.<app-name>-api.loadbalancer.server.port=8080"
```

### Add the external network at the bottom

```yaml
networks:
  platform_proxy:
    external: true
  # keep any existing internal networks
```

### Remove exposed ports

Change `ports:` to `expose:` on all services (except databases which should have neither):
```yaml
# BEFORE
ports:
  - "3000:3000"

# AFTER
expose:
  - "3000"
```

### Optional: opt-in to Prometheus metrics scraping (Quarkus backends)

```yaml
labels:
  # ... traefik labels ...
  - "prometheus.scrape=true"
  - "prometheus.port=8080"
  - "prometheus.path=/q/metrics"
```

---

## 3. Migrate Secrets to Infisical

1. Log in to Infisical at `https://secrets.homelab.local`
2. Create a new Project named exactly as the app (e.g. `bookshelf-haven`)
3. Import secrets from the app's `.env.example` (fill in real values for `dev` and `production` environments):
   ```bash
   infisical login
   # For each env:
   infisical secrets push --env=dev --projectName=<app-name> < .env.local
   infisical secrets push --env=production --projectName=<app-name> < .env.production
   ```
4. Delete `.env` and `.env.local` from the working directory (they should never be committed)
5. Verify `.env*` is in `.gitignore`

---

## 4. Update GitHub Actions

Replace the app's existing CI workflow with the shared workflow pattern:

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [main]

jobs:
  build-frontend:
    uses: adarshraj/platform/.github/workflows/docker-build-push.yml@main
    with:
      image-name: <app-name>-frontend
      dockerfile: frontend/Dockerfile
      context: frontend
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}

  build-backend:
    uses: adarshraj/platform/.github/workflows/quarkus-build.yml@main
    with:
      image-name: <app-name>-backend
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}

  deploy:
    needs: [build-frontend, build-backend]
    uses: adarshraj/platform/.github/workflows/deploy-portainer.yml@main
    with:
      stack-name: <app-name>
    secrets:
      PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL_APP_NAME }}
```

Add the Portainer webhook URL as a GitHub secret (`PORTAINER_WEBHOOK_URL_APP_NAME`) — get it from Portainer UI → Stacks → your stack → Webhooks.

---

## 5. Register Stack in Portainer

1. Clone the app repo to `~/apps/<app-name>/` on the VPS
2. In Portainer UI: Stacks → Add Stack → Upload → select the app's `docker-compose.yml`
3. Name the stack `<app-name>`
4. Enable webhook (copy URL → add to GitHub secrets in step 4)
5. Deploy

---

## 6. Verify

- [ ] `https://<app-name>.homelab.local` loads the frontend
- [ ] API calls work (no CORS, no port in URL)
- [ ] Grafana → Explore → Loki → query `{stack="<app-name>"}` shows logs
- [ ] Grafana → Dashboards → cAdvisor shows the new container
- [ ] Infisical project exists with all secrets
- [ ] GitHub Actions: push to main triggers build + deploy
- [ ] Update `SERVICE_CATALOG.md` status to `active`

---

## For Libraries (npm)

1. Set up `package.json` with `"name": "@yourorg/<lib-name>"`
2. Add `.npmrc` to the library repo:
   ```
   @yourorg:registry=https://npm.homelab.local
   ```
3. Add publish workflow:
   ```yaml
   # .github/workflows/publish.yml
   on:
     push:
       tags: ['v*']
   jobs:
     publish:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-node@v4
           with:
             node-version: 20
             registry-url: https://npm.homelab.local
         - run: npm ci && npm run build
         - run: npm publish
           env:
             NODE_AUTH_TOKEN: ${{ secrets.VERDACCIO_TOKEN }}
   ```
4. Consumers add `.npmrc` with the registry URL and `npm install @yourorg/<lib-name>`
