#!/usr/bin/env bash
# provision-vps.sh - create the persistent telemetry collector VPS.
#
# IMPORTANT: run this with hcloud pointed at a SEPARATE project from the agent
# sandboxes (token isolation - a leaked cc-box token must not reach this box).
#
# Usage:  SSH_KEYS="mykey" ./provision-vps.sh [name]
# Env:    TYPE, IMAGE, LOCATION, SSH_KEYS, FW
set -euo pipefail

NAME="${1:-telemetry}"
TYPE="${TYPE:-cx22}"
IMAGE="${IMAGE:-ubuntu-24.04}"
LOCATION="${LOCATION:-nbg1}"
SSH_KEYS="${SSH_KEYS:-}"
FW="${FW:-telemetry-fw}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Guard: refuse to run in the agent-sandbox project (keep pet and cattle apart).
ctx="$(hcloud context active 2>/dev/null || true)"
echo "[provision] hcloud context: ${ctx:-<none>}"
case "$ctx" in
  *agent*|*sandbox*)
    echo "[guard] active context '$ctx' looks like the agent project." >&2
    echo "        Switch to a SEPARATE project for the collector, then re-run." >&2
    exit 1 ;;
esac

[ -z "$SSH_KEYS" ] && { echo "[guard] set SSH_KEYS=<your uploaded key name(s)>" >&2; exit 2; }

# Firewall: SSH + HTTP + HTTPS inbound. (Tighten port 22 to your IP if you can.)
if ! hcloud firewall describe "$FW" >/dev/null 2>&1; then
  echo "[provision] creating firewall ${FW}..."
  hcloud firewall create --name "$FW" >/dev/null
  for p in 22 80 443; do
    hcloud firewall add-rule "$FW" --direction in --protocol tcp --port "$p" \
      --source-ips 0.0.0.0/0 --source-ips ::/0 >/dev/null
  done
fi

key_args=(); for k in $SSH_KEYS; do key_args+=(--ssh-key "$k"); done
echo "[provision] creating ${NAME} (${TYPE}, ${IMAGE}, ${LOCATION})..."
hcloud server create --name "$NAME" --type "$TYPE" --image "$IMAGE" \
  --location "$LOCATION" "${key_args[@]}" --firewall "$FW" \
  --user-data-from-file "$HERE/cloud-init-collector.yaml" >/dev/null

IP="$(hcloud server ip "$NAME")"
cat <<EOF

[provision] ${NAME} up at ${IP}

Next steps:
  1) DNS:   telemetry.example.com   A   ${IP}
  2) Wait for Docker (first boot ~1-2 min):
       ssh root@${IP} 'cloud-init status --wait && docker --version'
  3) Copy the stack up (from this telemetry/ dir):
       rsync -av --exclude '.git' --exclude 'caddy_data' ./ root@${IP}:/opt/telemetry/
  4) Bring it up:
       ssh root@${IP} 'cd /opt/telemetry && docker compose up -d'
  5) Once DNS resolves, Caddy gets a cert automatically. Then:
       https://telemetry.example.com   -> Grafana (admin / see telemetry/.env)
EOF
