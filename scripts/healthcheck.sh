#!/usr/bin/env bash
# scripts/healthcheck.sh
# Full operational health check for the Dive Realities observability stack.
# Checks: container status, endpoint liveness, Prometheus target health, disk space.
# Exit code: 0 if all checks pass, 1 if any fail (usable in CI/CD pipelines).

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[ OK ]${NC} $*"; }
err()  { echo -e "  ${RED}[ERR]${NC} $*"; FAILED=1; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

FAILED=0

# ── 1. Container Health ───────────────────────────────────────────────────────
echo ""
echo "═══ Container Health ═══"

CONTAINERS=(
  "dive-prometheus"
  "dive-alertmanager"
  "dive-grafana"
  "dive-loki"
  "dive-promtail"
  "dive-node-exporter"
  "dive-cadvisor"
  "dive-caddy"
  "dive-discord-prod-critical"
  "dive-discord-prod-warning"
  "dive-discord-dev"
)

for container in "${CONTAINERS[@]}"; do
  status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' "$container" 2>/dev/null || echo "not_found")

  if [[ "$status" == "running" && ("$health" == "healthy" || "$health" == "no_healthcheck") ]]; then
    ok "$container  ($status / $health)"
  elif [[ "$status" == "not_found" ]]; then
    err "$container  (not found — is the stack up?)"
  else
    err "$container  ($status / $health)"
  fi
done

# ── 2. Endpoint Probes ────────────────────────────────────────────────────────
echo ""
echo "═══ Endpoint Probes ═══"

probe() {
  local name="$1" url="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "$name  (HTTP $code)  → $url"
  else
    err "$name  (HTTP $code)  → $url"
  fi
}

probe "Prometheus " "http://localhost:9090/-/healthy"
probe "Alertmanager" "http://localhost:9093/-/healthy"
probe "Grafana    " "http://localhost:3000/api/health"
probe "Loki       " "http://localhost:3100/ready"

# ── 3. Prometheus Targets ─────────────────────────────────────────────────────
echo ""
echo "═══ Prometheus Targets ═══"

targets_down=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
down = [t['labels'].get('job','?') for t in data.get('data',{}).get('activeTargets',[]) if t['health'] != 'up']
print(len(down))
if down: print('  Down:', ', '.join(down))
" 2>/dev/null || echo "ERROR")

if [[ "$targets_down" == "0" ]]; then
  total=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('activeTargets',[])))" 2>/dev/null)
  ok "All Prometheus targets are UP  (0/${total:-?} targets down)"
elif [[ "$targets_down" == "ERROR" ]]; then
  warn "Could not reach Prometheus API — is Prometheus healthy?"
else
  err "Some targets are DOWN"
  echo "$targets_down"
fi

# ── 4. Disk Space ─────────────────────────────────────────────────────────────
echo ""
echo "═══ Disk Space ═══"

usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if (( usage < 80 )); then
  ok "Disk usage OK  (${usage}% used)"
elif (( usage < 90 )); then
  warn "Disk usage at ${usage}% — consider cleaning old data"
else
  err "Disk usage CRITICAL at ${usage}%"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${NC}"
  exit 0
else
  echo -e "${RED}Some checks FAILED — review the errors above.${NC}"
  exit 1
fi
