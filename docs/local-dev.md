# Local Development Setup

How to set up your dev machine to work with the platform (TLS certs, DNS, Infisical CLI).

---

## 1. DNS — Resolve *.homelab.local

### Option A: /etc/hosts (simplest, manual)
Add entries for each service you use:
```
<VPS_IP>  traefik.homelab.local portainer.homelab.local monitoring.homelab.local
<VPS_IP>  secrets.homelab.local npm.homelab.local
<VPS_IP>  bookshelf.homelab.local auth.homelab.local
# ... add more as needed
```

### Option B: Pi-hole or local DNS resolver (recommended for many services)
Add a wildcard DNS entry: `*.homelab.local → <VPS_IP>`

On Pi-hole: Local DNS → DNS Records → add `homelab.local` pointing to VPS IP.
On dnsmasq: add `address=/homelab.local/<VPS_IP>` to your config.

---

## 2. TLS — Trust the Wildcard Certificate

The platform uses a self-signed wildcard cert for `*.homelab.local`.
You need to trust the CA on your dev machine to avoid browser warnings.

### Generate with mkcert (recommended)

```bash
# Install mkcert
brew install mkcert        # macOS
sudo apt install mkcert    # Ubuntu/Debian

# Install the local CA (run once per machine)
mkcert -install

# Generate wildcard cert (run on the server or copy CAROOT to server)
mkcert "*.homelab.local" homelab.local

# Output: _wildcard.homelab.local+1.pem and _wildcard.homelab.local+1-key.pem
# Rename and place in: platform/infra/traefik/dynamic/certs/
mv "_wildcard.homelab.local+1.pem" wildcard.crt
mv "_wildcard.homelab.local+1-key.pem" wildcard.key
```

Copy `wildcard.crt` and `wildcard.key` to `platform/infra/traefik/dynamic/certs/` on the VPS.

On each dev machine that needs to trust the cert: run `mkcert -install` (this installs the CA into the system trust store and browsers automatically trust it).

---

## 3. Infisical CLI

Install once per dev machine:
```bash
# macOS
brew install infisical/get-cli/infisical

# Linux
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo bash
sudo apt install infisical

# Windows
scoop install infisical
```

Login and set default org:
```bash
infisical login --domain=https://secrets.homelab.local
```

### Using secrets in local dev

Instead of sourcing a `.env` file, prefix your dev command with `infisical run`:
```bash
# Before
npm run dev

# After
infisical run --env=dev --projectName=bookshelf-haven -- npm run dev

# Or for Quarkus
infisical run --env=dev --projectName=bookshelf-haven -- ./mvnw quarkus:dev
```

---

## 4. npm Registry (for shared TS libraries)

Add to `~/.npmrc` (global, once):
```
@yourorg:registry=https://npm.homelab.local
```

Or per-project in `.npmrc` at repo root:
```
@yourorg:registry=https://npm.homelab.local
```

Login to Verdaccio (once):
```bash
npm login --registry=https://npm.homelab.local
```
