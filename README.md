# Dive Realities — Observability Core

Stack completa de observabilidade para os ambientes **dev e prod** da Dive Realities,
rodando em VPS Linux na Hostinger. Cobre os três pilares: **métricas + logs + alertas**.

---

## Índice

1. [Arquitetura](#arquitetura)
2. [Ferramentas e versões](#ferramentas-e-versões)
3. [Pré-requisitos](#pré-requisitos)
4. [Configuração passo a passo](#configuração-passo-a-passo)
5. [Operação diária](#operação-diária)
6. [Segurança](#segurança)
7. [Troubleshooting](#troubleshooting)

---

## Arquitetura

```
┌──────────────────────────────────────────────────────────┐
│  VPS Observabilidade                                     │
│                                                          │
│  make up                                                 │
│    ├─ config-renderer  → configs_rendered (volume)       │
│    ├─ Prometheus       ← configs_rendered/prometheus.yml │
│    ├─ Alertmanager     ← configs_rendered/alertmanager   │
│    ├─ Loki             (porta 3100, UFW→Tailscale only)  │
│    ├─ Promtail         (coleta logs da VPS obs)          │
│    ├─ Grafana          (sem porta direta no host)        │
│    ├─ Caddy            → HTTPS → Grafana                 │
│    ├─ node-exporter + cAdvisor                           │
│    └─ 3× Discord bridges                                 │
│                                                          │
│  Internet → 443 → Caddy → Grafana (HTTPS automático)    │
│  Internet → 80  → Caddy → redirect HTTPS                 │
└────────────────┬─────────────────────────────────────────┘
                 │  Tailscale VPN (WireGuard — criptografado)
     ┌───────────┴────────────┐
     │                        │
┌────▼─────┐           ┌──────▼──┐
│ VPS dev  │           │VPS prod │
│ :9100    │           │  :9100  │  ← node-exporter   (métricas de host)
│ :9209    │           │  :9209  │  ← pm2-exporter    (métricas PM2)
│ :8080    │           │  :8080  │  ← cAdvisor        (métricas container)
│ Promtail │           │Promtail │  → Loki :3100      (logs)
└──────────┘           └─────────┘
```

Acesso ao Grafana: **https://grafana.diverealities.com.br**

---

## Ferramentas e versões

### Stack na VPS de observabilidade (Docker Compose)

| Ferramenta | Versão | Função |
|---|---|---|
| [Prometheus](https://prometheus.io) | `v2.55.1` | Coleta e armazena métricas (TSDB) |
| [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) | `v0.27.0` | Deduplica, agrupa e roteia alertas → Discord |
| [Grafana](https://grafana.com) | `11.3.1` | Dashboards unificados de métricas + logs |
| [Loki](https://grafana.com/oss/loki/) | `3.2.1` | Armazena e indexa logs |
| [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) | `3.2.1` | Coleta e envia logs ao Loki |
| [Caddy](https://caddyserver.com) | `2.9-alpine` | Proxy reverso com TLS automático (Let's Encrypt) |
| [node-exporter](https://github.com/prometheus/node_exporter) | `v1.8.2` | Métricas de host da VPS obs (CPU, RAM, disco) |
| [cAdvisor](https://github.com/google/cadvisor) | `v0.49.1` | Métricas de containers Docker |
| [alertmanager-discord](https://github.com/benjojo/alertmanager-discord) | `latest` | Bridge Alertmanager → Discord (3 instâncias) |
| Alpine | `3.21` | Config renderer (envsubst) — container init |

### Agentes nas VPSes de aplicação (systemd)

| Ferramenta | Versão | Função |
|---|---|---|
| [node-exporter](https://github.com/prometheus/node_exporter) | `v1.8.2` | Métricas de host (CPU, RAM, disco, rede) |
| [pm2-exporter](./pm2-exporter/pm2_exporter.js) | custom (Node.js) | Métricas de processos PM2 |
| [cAdvisor](https://github.com/google/cadvisor) | `v0.49.1` | Métricas de containers (via Docker) |
| [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) | `v3.2.1` | Coleta logs e envia ao Loki central |
| [Tailscale](https://tailscale.com) | latest | VPN WireGuard — toda comunicação criptografada |

### Alertas configurados (9 regras)

| Alerta | Severidade | Condição |
|---|---|---|
| `ServidorIndisponivel` | critical | target fora por > 1 min |
| `CPUAltaHost` | warning | CPU > 80% por 5 min |
| `MemoriaAltaHost` | warning | RAM > 90% por 5 min |
| `DiscoQuaseCheio` | critical | disco < 15% livre por 5 min |
| `PM2RestartLoop` | critical | > 5 restarts em 10 min |
| `PM2MemoriaAlta` | warning | processo PM2 > 1.5 GB por 5 min |
| `ContainerOOMKilled` | critical | container morto por OOM |
| `ContainerCPUAlta` | warning | container > 80% do CPU limit por 5 min |
| `ContainerMemoriaAlta` | warning | container > 90% do memory limit por 5 min |

---

## Pré-requisitos

### O que ter em mãos

| Item | Onde obter |
|---|---|
| VPS de observabilidade (KVM 2 — 2 vCPU / 8 GB / 100 GB) | Hostinger |
| IPs das VPSes de aplicação (dev e prod) | Painel Hostinger |
| Domínio apontando para a VPS obs (`grafana.diverealities.com.br`) | Painel DNS |
| Conta Tailscale (gratuita) e auth key | tailscale.com |
| Servidor Discord com permissão de criar webhooks | — |

### Softwares necessários na VPS de observabilidade

```bash
apt-get install -y docker.io docker-compose-plugin make git ufw
```

> **Não instale Nginx nem Certbot** — o Caddy cuida do HTTPS dentro do Docker.

---

## Configuração passo a passo

### Passo 1 — Tailscale em todas as VPSes

Execute em **cada VPS** (observabilidade, dev e prod):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=<SUA_TAILSCALE_AUTH_KEY> --hostname=dive-<nome>
```

Após o join, anote o IP privado de cada VPS:

```bash
tailscale ip -4
# Exemplo: 100.64.0.1
```

> O Tailscale cria uma VPN WireGuard entre os servidores. Todo tráfego de métricas e logs passa por ela — nenhum dado cruza a internet em texto limpo.

---

### Passo 2 — Configurar Discord (3 webhooks)

Em cada canal abaixo: **Editar canal → Integrações → Webhooks → Novo Webhook → Copiar URL**

| Canal | Webhook |
|---|---|
| `#alertas-prod-critico` | `DISCORD_WEBHOOK_PROD_CRITICAL` |
| `#alertas-prod-atencao` | `DISCORD_WEBHOOK_PROD_WARNING` |
| `#alertas-dev` | `DISCORD_WEBHOOK_DEV` |

---

### Passo 3 — Clonar o repositório na VPS de observabilidade

```bash
ssh root@<IP-VPS-OBS>

cd /opt
git clone <URL-DO-REPOSITORIO> observability-stack
cd observability-stack/observability-core
```

---

### Passo 4 — Preencher o `.env`

```bash
cp .env.example .env
nano .env
```

| Variável | Como obter |
|---|---|
| `OBS_TAILSCALE_IP` | `tailscale ip -4` na VPS obs |
| `DEV_TAILSCALE_IP` | `tailscale ip -4` na VPS dev |
| `PROD_TAILSCALE_IP` | `tailscale ip -4` na VPS prod |
| `GRAFANA_ADMIN_PASSWORD` | `openssl rand -base64 32` |
| `DISCORD_WEBHOOK_*` | Webhooks do Passo 2 |
| `GRAFANA_DOMAIN` | `grafana.diverealities.com.br` (ou seu domínio) |

---

### Passo 5 — Configurar firewall (UFW)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment "SSH"
ufw allow 80/tcp   comment "HTTP — ACME challenge Caddy"
ufw allow 443/tcp  comment "HTTPS — Grafana via Caddy"

# Loki: acessível apenas pela subnet Tailscale
ufw allow from 100.64.0.0/10 to any port 3100 comment "Loki — Tailscale only"

ufw enable
ufw status verbose
```

---

### Passo 6 — Subir a stack

```bash
make up
```

O comando executa em sequência:
1. `docker compose run --rm config-renderer` — Alpine com envsubst renderiza `prometheus.yml` e `alertmanager.yml`
2. `docker compose up -d --remove-orphans` — sobe os 11 containers

```bash
# Verificar saúde
make health

# Ver status dos containers
make ps
```

**Saída esperada do `make ps`:**

```
NAME                          STATUS
dive-config-renderer          Exited (0)      ← normal, é one-shot
dive-prometheus               Up (healthy)
dive-alertmanager             Up (healthy)
dive-grafana                  Up (healthy)
dive-loki                     Up (healthy)
dive-promtail                 Up (healthy)
dive-node-exporter            Up (healthy)
dive-cadvisor                 Up (healthy)
dive-caddy                    Up (healthy)
dive-discord-prod-critical    Up (healthy)
dive-discord-prod-warning     Up (healthy)
dive-discord-dev              Up (healthy)
```

---

### Passo 7 — Instalar agentes nas VPSes de aplicação

Execute em **cada VPS de aplicação** (dev e prod):

```bash
# Copiar o pm2-exporter
scp /opt/observability-stack/observability-core/pm2-exporter/pm2_exporter.js \
  root@<IP-VPS-APP>:/opt/pm2_exporter.js

# Conectar e instalar
ssh root@<IP-VPS-APP>

sudo bash /opt/observability-stack/observability-core/scripts/install-agents.sh \
  --obs-ip <OBS_TAILSCALE_IP>
```

Aguarda saída:
```
[ OK ] [1/4] Node Exporter running on :9100
[ OK ] [2/4] PM2 Exporter running on :9209
[ OK ] [3/4] cAdvisor running on :8080
[ OK ] [4/4] UFW: exporter ports restricted to 100.x.x.x
```

---

### Passo 8 — Validar coleta de métricas

```bash
# Da VPS de observabilidade — via Tailscale
curl http://<DEV_TAILSCALE_IP>:9100/metrics | grep node_cpu | head -3
curl http://<PROD_TAILSCALE_IP>:9209/metrics | grep pm2_process_up

# Prometheus targets — todos devem estar UP
curl -s http://localhost:9090/api/v1/targets \
  | python3 -m json.tool | grep '"health"'
```

---

### Passo 9 — Instalar Promtail nas VPSes de aplicação

```bash
ssh root@<IP-VPS-APP>

# Download do binário
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
wget -q https://github.com/grafana/loki/releases/download/v3.2.1/promtail-linux-${ARCH}.zip
unzip promtail-linux-${ARCH}.zip
install -o root -g root -m 0755 promtail-linux-${ARCH} /usr/local/bin/promtail

# Criar configuração
cat > /etc/promtail-config.yml << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://<OBS_TAILSCALE_IP>:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker-containers
    static_configs:
      - targets: [localhost]
        labels:
          job: docker
          environment: <dev|prod>
          __path__: /var/lib/docker/containers/*/*.log
    pipeline_stages:
      - json:
          expressions: {output: log, stream: stream, time: time}
      - labels: {stream:}
      - timestamp: {source: time, format: RFC3339Nano}
      - output: {source: output}
      - drop:
          expression: '(GET /(health|ready|metrics) HTTP)|\b(DEBUG|debug)\b|^\s*$'

  - job_name: pm2-out
    static_configs:
      - targets: [localhost]
        labels:
          job: pm2
          stream: stdout
          environment: <dev|prod>
          __path__: /root/.pm2/logs/*-out-*.log
    pipeline_stages:
      - match:
          selector: '{job="pm2"}'
          stages:
            - regex:
                source: filename
                expression: '/.*\/(?P<process_name>[^/]+)-out-\d+\.log$'
            - labels: {process_name:}

  - job_name: pm2-error
    static_configs:
      - targets: [localhost]
        labels:
          job: pm2
          stream: stderr
          environment: <dev|prod>
          __path__: /root/.pm2/logs/*-error-*.log
    pipeline_stages:
      - match:
          selector: '{job="pm2"}'
          stages:
            - regex:
                source: filename
                expression: '/.*\/(?P<process_name>[^/]+)-error-\d+\.log$'
            - labels: {process_name:}
EOF

mkdir -p /var/lib/promtail

# Criar serviço systemd
cat > /etc/systemd/system/promtail.service << 'UNIT'
[Unit]
Description=Promtail log shipper
After=network.target

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail-config.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now promtail
```

---

### Passo 10 — Validação final

```bash
# Na VPS de observabilidade
make health
make test-alert    # verifica se Discord recebe
```

No Grafana (https://grafana.diverealities.com.br):
- **Explore → Prometheus → query:** `up` → todos devem retornar `1`
- **Explore → Loki → query:** `{job="pm2", environment="prod"}` → logs das apps

---

## Operação diária

```bash
make up           # subir (ou re-renderizar + reiniciar)
make down         # parar tudo (dados preservados)
make ps           # status dos containers
make health       # diagnóstico completo
make logs         # tail de todos os logs (Ctrl+C para sair)
make reload       # re-renderizar configs + reload sem restart
make restart s=grafana   # reiniciar um serviço específico
make test-alert   # enviar alerta de teste ao Discord
make clean        # ⚠️ DESTRUTIVO — apaga containers + volumes
```

---

## Segurança

### Superfície de rede exposta

| Porta | Exposta | Restrita a |
|---|---|---|
| `80` | ✅ público | Caddy (redirect HTTPS) |
| `443` | ✅ público | Caddy (Grafana via HTTPS) |
| `3100` | ✅ host | Tailscale subnet `100.64.0.0/10` via UFW |
| `9090` | ❌ interno | Rede Docker `dive-observability` |
| `9093` | ❌ interno | Rede Docker `dive-observability` |
| `3000` | ❌ interno | Rede Docker `dive-observability` |
| `9100` (app VPS) | ✅ host | IP obs VPS via UFW |
| `9209` (app VPS) | ✅ host | IP obs VPS via UFW |
| `8080` (app VPS) | ✅ host | IP obs VPS via UFW |

### Decisões de segurança documentadas

- **Tailscale obrigatório**: todo tráfego de métricas e logs usa WireGuard (criptografia de ponta a ponta)
- **Grafana sem porta direta**: acessível apenas via Caddy (HTTPS). Porta `3000` não exposta no host
- **Prometheus/Alertmanager sem porta externa**: acessíveis apenas internamente na rede Docker
- **`--web.enable-lifecycle`**: permite reload de config via POST sem restart. Aceitável pois as portas não estão expostas externamente
- **`privileged: true` no cAdvisor**: necessário para acessar subsistemas cgroup/perf_event — documentado intencionalmente
- **`network_mode: host` no node-exporter**: necessário para ler métricas reais do host (não do container)
- **Grafana**: signup desabilitado (`GF_USERS_ALLOW_SIGN_UP=false`), telemetria desabilitada
- **Secrets exclusivamente no `.env`**: nenhuma senha ou webhook no código. `.env` no `.gitignore`
- **TLS automático via Caddy**: certificados Let's Encrypt gerenciados automaticamente, renovação automática antes do vencimento

### Hardening recomendado na VPS (pós-deploy)

```bash
# Desabilitar login por senha no SSH (usar apenas chave)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload sshd

# fail2ban — bane IPs após 5 tentativas de SSH falhas
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
maxretry = 5
bantime  = 3600
findtime = 600
EOF
systemctl enable --now fail2ban

# Auto-start da stack após reboot
cat > /etc/systemd/system/observability-stack.service << 'EOF'
[Unit]
Description=Dive Realities Observability Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/observability-stack/observability-core
ExecStart=/usr/bin/make up
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable observability-stack
```

---

## Troubleshooting

### Container não sobe / unhealthy

```bash
docker compose logs --tail=100 dive-<nome>
docker inspect --format='{{json .State}}' dive-<nome> | python3 -m json.tool
```

### Prometheus target DOWN

```bash
# Testar conectividade via Tailscale da VPS obs
curl -v http://<DEV_TAILSCALE_IP>:9100/metrics

# Verificar UFW na VPS de aplicação
ssh root@<VPS-APP> "ufw status verbose | grep 9100"
```

### Discord não recebe alertas

```bash
# Testar webhook diretamente
curl -X POST <DISCORD_WEBHOOK_PROD_CRITICAL> \
  -H "Content-Type: application/json" \
  -d '{"content": "teste direto"}'

# Log do bridge
docker compose logs --tail=50 dive-discord-prod-critical
```

### Loki não recebe logs das VPSes de aplicação

```bash
# Verificar se o Promtail da VPS app consegue alcançar o Loki
ssh root@<VPS-APP> "curl -s http://<OBS_TAILSCALE_IP>:3100/ready"

# Verificar UFW no obs VPS
ufw status verbose | grep 3100
```

### Configs não foram aplicadas após `make up`

```bash
# Forçar re-renderização e restart completo
make down
make up
make health
```

### Certificado TLS não emitido pelo Caddy

```bash
# Verificar se o DNS propagou
nslookup grafana.diverealities.com.br

# Log do Caddy
docker compose logs --tail=50 dive-caddy
```

---

## Estrutura do repositório

```
observability-core/
├── .env.example                # Template de variáveis — copie para .env
├── .gitignore
├── docker-compose.yml          # Orquestração principal (11 containers)
├── Makefile                    # Interface de operação (make up, make health, ...)
│
├── alertmanager/
│   └── alertmanager.yml        # Roteamento de alertas por ambiente e severidade
│
├── caddy/
│   └── Caddyfile               # Proxy reverso + TLS automático para o Grafana
│
├── grafana/
│   ├── dashboards/             # Dashboards JSON (provisionados automaticamente)
│   └── provisioning/
│       ├── dashboards/         # Config de provisionamento de dashboards
│       └── datasources/        # Config de datasources (Prometheus + Loki)
│
├── loki/
│   └── loki-config.yml         # Config do Loki (retenção, compactor, schema)
│
├── pm2-exporter/
│   └── pm2_exporter.js         # Exporter Node.js para métricas PM2
│
├── prometheus/
│   ├── alert.rules.yml         # 9 regras de alerta (host, PM2, containers)
│   └── prometheus.yml          # Targets de scrape (dev + prod via Tailscale)
│
├── promtail/
│   └── promtail-config.yml     # Coleta de logs com filtros de ruído
│
└── scripts/
    ├── healthcheck.sh          # Diagnóstico completo da stack
    └── install-agents.sh       # Instala agentes nas VPSes de aplicação
```
