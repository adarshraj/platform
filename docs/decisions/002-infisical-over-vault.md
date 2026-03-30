# ADR 002: Infisical over HashiCorp Vault for Secrets Management

**Status**: Accepted

## Context
We needed centralized secrets management to replace scattered `.env` files across 19 repos.

## Decision
Use Infisical (self-hosted, open-source).

## Reasons
- Mirrors the `.env` mental model — easy migration from existing `.env` files
- First-class GitHub Actions integration (`Infisical/secrets-action`)
- CLI works as a drop-in replacement: `infisical run -- npm run dev`
- Per-project, per-environment secret scoping matches our repo structure
- Web UI is approachable without DevOps expertise

## Rejected Alternatives
- **HashiCorp Vault**: Excellent but operationally complex (unsealing, token renewal, policies). Overkill for a single-person team
- **Doppler**: Cloud-only, not self-hostable
- **Git-crypt**: Encrypts secrets in repo — still scatters them across 19 repos, doesn't solve the management problem
