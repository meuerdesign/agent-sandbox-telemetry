# telemetry

Persistent OpenTelemetry stack for the agent sandboxes. The disposable cc-boxes
**push** metrics and events here over HTTPS; this box stores and visualizes them.

Keep this **out of the public `infra/` repo** and in a **separate Hetzner
project** from the cc-boxes (token isolation: a leaked cc-box token must not be
able to reach this pet).

## Stack

```
boxes ──OTLP/https──> Caddy (TLS, telemetry.example.com)
                        ├─ /v1/*  ─> otel-collector ─┬─> Prometheus  (metrics)
                        │                            └─> Loki        (events)
                        └─ /*     ─> Grafana <───────── Prometheus + Loki
```

Only Caddy is exposed (80/443). Collector, Prometheus, Loki, Grafana are
internal to the Docker network. Ingest is gated by a bearer token.

## Files

| File | Role |
|------|------|
| `docker-compose.yml` | the whole stack. |
| `Caddyfile` | TLS + path routing (`/v1/*` ingest, `/*` Grafana). |
| `otel-collector-config.yaml` | OTLP in (token-gated) -> Prometheus + Loki. |
| `prometheus.yml` / `loki-config.yaml` | storage backends. |
| `grafana/provisioning/` | auto-wires Prometheus + Loki as datasources. |
| `provision-vps.sh` + `cloud-init-collector.yaml` | create the VPS. |
| `.env` | secrets (token, Grafana pw). **gitignored.** |
| `agent-otel.env` | the file to inject into the boxes. **gitignored.** |

## Deploy

1. **Create the VPS** (hcloud pointed at a *separate* project):
   ```bash
   SSH_KEYS="<your-key-name>" ./provision-vps.sh telemetry
   ```
2. **DNS:** point `telemetry.example.com` A-record at the printed IP.
3. **Copy + start:**
   ```bash
   rsync -av --exclude '.git' --exclude 'caddy_data' ./ root@<ip>:/opt/telemetry/
   ssh root@<ip> 'cd /opt/telemetry && docker compose up -d'
   ```
4. Once DNS resolves, Caddy gets a Let's Encrypt cert automatically.
   Open `https://telemetry.example.com` -> Grafana (user `admin`, pw in `.env`).

## Point the boxes at it

`agent-otel.env` already contains the endpoint + token. Install it on a box as
`/opt/agent/secrets/otel.env` (or bake it into the golden via the `otel.env`
template in `infra/cloud-init.yaml`). `run-agent.sh` detects it and turns
telemetry on. Rebuild the golden to make it stick across spawns.

Verify end to end: spawn a box, run a Claude session, then in Grafana query
`claude_code.cost.usage` (Prometheus) or browse `{service_name="agent-sandbox"}`
(Loki).

## Rotate the ingest token

Change `INGEST_TOKEN` in `.env` **and** the `Authorization` line in
`agent-otel.env` (they must match), then `docker compose up -d` here and
re-inject on the boxes.

## Notes

- Versions are pinned in `docker-compose.yml`; bump deliberately.
- Prometheus retention 90d, Loki ~31d - tune in compose / `loki-config.yaml`.
- Tighten firewall port 22 to your own IP if you can (`provision-vps.sh`).
