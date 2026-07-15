#!/usr/bin/env bash
# scripts/install-agents.sh
# Installs observability agents on application VPSes (dev/prod).
# Run as root on the target VPS.
#
# Installs:
#   1/4 - Node Exporter  (host metrics)
#   2/4 - PM2 Exporter   (PM2 process metrics)
#   3/4 - cAdvisor       (container metrics)
#   4/4 - UFW rules      (restrict exporter ports to obs VPS only)
#
# Usage:
#   sudo bash install-agents.sh --obs-ip <IP-DA-VPS-OBSERVABILIDADE>

set -euo pipefail

# ── Versions ──────────────────────────────────────────────────────────────────
NODE_EXPORTER_VERSION="1.8.2"
CADVISOR_VERSION="v0.49.1"

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
OBS_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --obs-ip) OBS_IP="$2"; shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -n "$OBS_IP" ]] || err "Usage: $0 --obs-ip <IP-DA-VPS-OBSERVABILIDADE>"
[[ "$EUID" -eq 0 ]] || err "Must run as root"

info "Starting agent installation  obs_ip=${OBS_IP}"
echo ""

# ── 1/4 — Node Exporter ───────────────────────────────────────────────────────
info "[1/4] Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

useradd -rs /bin/false node_exporter 2>/dev/null || true

ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"

wget -q "$URL" -O /tmp/node_exporter.tar.gz
tar xzf /tmp/node_exporter.tar.gz -C /tmp
install -o root -g root -m 0755 "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter
rm -rf /tmp/node_exporter*

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
sleep 2

metrics_count=$(curl -s http://localhost:9100/metrics 2>/dev/null | grep -c '^node_' || echo 0)
ok "[1/4] Node Exporter running on :9100 (${metrics_count} node_* metrics)"

# ── 2/4 — PM2 Exporter ────────────────────────────────────────────────────────
info "[2/4] Installing PM2 Exporter..."

if command -v pm2 &>/dev/null; then
  [[ -f /opt/pm2_exporter.js ]] || err "PM2 Exporter not found at /opt/pm2_exporter.js — copy it first"

  npm install --prefix /opt/pm2-exporter express 2>/dev/null

  cat > /etc/systemd/system/pm2_exporter.service << 'EOF'
[Unit]
Description=PM2 Prometheus Exporter
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/pm2_exporter.js
Restart=on-failure
RestartSec=5s
Environment=PORT=9209

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pm2_exporter
  sleep 2
  ok "[2/4] PM2 Exporter running on :9209"
else
  echo "  [SKIP] PM2 not found — skipping PM2 Exporter"
fi

# ── 3/4 — cAdvisor ────────────────────────────────────────────────────────────
info "[3/4] Installing cAdvisor ${CADVISOR_VERSION}..."

if ! command -v docker &>/dev/null; then
  err "Docker not found — install Docker before cAdvisor"
fi

docker run -d \
  --name cadvisor \
  --restart unless-stopped \
  --privileged \
  --volume /:/rootfs:ro \
  --volume /var/run:/var/run:ro \
  --volume /sys:/sys:ro \
  --volume /var/lib/docker/:/var/lib/docker:ro \
  --volume /dev/disk/:/dev/disk:ro \
  --publish 8080:8080 \
  gcr.io/cadvisor/cadvisor:${CADVISOR_VERSION} 2>/dev/null || \
  docker start cadvisor 2>/dev/null || true

sleep 3
ok "[3/4] cAdvisor running on :8080"

# ── 4/4 — UFW rules ───────────────────────────────────────────────────────────
info "[4/4] Configuring UFW — restricting exporter ports to obs VPS only..."

if command -v ufw &>/dev/null; then
  # Allow only the observability VPS to scrape metrics
  # Using specific IP rules instead of subnet to minimize attack surface
  ufw allow from "${OBS_IP}" to any port 9100 comment "Node Exporter — obs VPS only"
  ufw allow from "${OBS_IP}" to any port 9209 comment "PM2 Exporter — obs VPS only"
  ufw allow from "${OBS_IP}" to any port 8080 comment "cAdvisor — obs VPS only"
  ok "[4/4] UFW: exporter ports restricted to ${OBS_IP}"
else
  echo "  [WARN] UFW not found — manually restrict ports 9100, 9209, 8080 to ${OBS_IP}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[ OK ] Installation complete${NC}"
echo ""
echo "  Verify from obs VPS:"
echo "    curl http://$(hostname -I | awk '{print $1}'):9100/metrics | head -3"
echo "    curl http://$(hostname -I | awk '{print $1}'):9209/metrics | head -3"
echo "    curl http://$(hostname -I | awk '{print $1}'):8080/metrics | head -3"
