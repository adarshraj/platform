# ADR 003: Loki + Promtail over ELK Stack for Centralized Logging

**Status**: Accepted

## Context
We needed centralized log aggregation across 19 Docker-based services.

## Decision
Use Grafana Loki + Promtail for log collection, with Grafana as the query UI.

## Reasons
- Loki indexes only labels (container name, stack, service), not full log content — dramatically lower memory and storage than Elasticsearch
- Promtail auto-discovers all Docker containers via Docker socket and socket-mounted log files — zero configuration per app
- Grafana is already the metrics UI (Prometheus datasource), so logs and metrics are in one place
- Same query language (LogQL) is consistent with PromQL for metrics

## Rejected Alternatives
- **ELK (Elasticsearch + Logstash + Kibana)**: Full-text indexing requires significant RAM (2GB+ for Elasticsearch alone). Too heavy for a single VPS running 19 apps
- **Graylog**: Better than ELK for this use case but still heavier than Loki; separate UI from Grafana
