COMPOSE := docker compose

.DEFAULT_GOAL := help

# ── Targets ───────────────────────────────────────────────────────────────────

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Render configs + start all services in detached mode
	@echo "[INFO] Rendering configs via config-renderer..."
	@$(COMPOSE) run --rm config-renderer
	@echo "[INFO] Starting all services..."
	@$(COMPOSE) up -d --remove-orphans
	@echo "[ OK ] Stack is up — run 'make health' to verify"

down: ## Stop and remove all containers (data volumes are preserved)
	@$(COMPOSE) down

restart: ## Restart a specific service: make restart s=grafana
	@[[ -n "$(s)" ]] || (echo "Usage: make restart s=<service-name>" && exit 1)
	@$(COMPOSE) restart $(s)

reload: ## Re-render configs + reload Prometheus and Alertmanager without restart
	@echo "[INFO] Re-rendering configs..."
	@$(COMPOSE) run --rm config-renderer
	@echo "[INFO] Reloading Prometheus..."
	@curl -sf -X POST http://localhost:9090/-/reload \
		&& echo "[ OK ] Prometheus reloaded" \
		|| echo "[WARN] Prometheus reload failed (is it running?)"
	@echo "[INFO] Reloading Alertmanager..."
	@curl -sf -X POST http://localhost:9093/-/reload \
		&& echo "[ OK ] Alertmanager reloaded" \
		|| echo "[WARN] Alertmanager reload failed"
	@echo "[ OK ] Done"

health: ## Run full health check for all services and Prometheus targets
	@chmod +x scripts/healthcheck.sh
	@./scripts/healthcheck.sh

logs: ## Tail logs for all services (Ctrl+C to stop)
	@$(COMPOSE) logs -f --tail=100

ps: ## Show container status and health
	@$(COMPOSE) ps

clean: ## Remove all containers AND data volumes (DESTRUCTIVE — loses all metrics/logs)
	@echo ""
	@echo "⚠️  WARNING: This will delete ALL data volumes (metrics, logs, dashboards)."
	@echo "   Press Ctrl+C within 5 seconds to abort..."
	@sleep 5
	@$(COMPOSE) down -v
	@echo "[ OK ] All containers and volumes removed."

test-alert: ## Send a test alert to Alertmanager → Discord #alertas-prod-critico
	@curl -sf \
		-X POST http://localhost:9093/api/v2/alerts \
		-H "Content-Type: application/json" \
		-d '[{"labels":{"alertname":"TesteManual","severity":"critical","environment":"prod","server":"prod-vps"},"annotations":{"summary":"Alerta de teste manual via Makefile"}}]' \
		&& echo "[ OK ] Test alert sent — check #alertas-prod-critico on Discord" \
		|| echo "[ERR] Failed to reach Alertmanager on :9093"
