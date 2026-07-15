// pm2_exporter.js — Prometheus exporter for PM2 process metrics
// Exposes pm2_process_up, pm2_process_restarts_total, pm2_process_memory_bytes,
// pm2_process_cpu_percent for each PM2-managed process.
//
// Design constraints:
//   - exec timeout 5s: prevents hanging if PM2 daemon is stalled
//   - /health endpoint: liveness probe for Docker healthcheck and monitoring
//   - No external dependencies beyond Node.js built-ins + pm2 CLI

const http = require("http");
const { exec } = require("child_process");

const PORT = process.env.PORT || 9209;

// Timeout de 5s: evita que o request fique pendurado se o daemon PM2 travar
function getPm2Metrics(callback) {
  exec("pm2 jlist", { timeout: 5_000 }, (err, stdout) => {
    if (err) {
      return callback(err, null);
    }
    try {
      const processes = JSON.parse(stdout);
      callback(null, processes);
    } catch (parseErr) {
      callback(parseErr, null);
    }
  });
}

function formatMetrics(processes) {
  const lines = [];

  lines.push("# HELP pm2_process_up Whether the PM2 process is running (1=up, 0=down)");
  lines.push("# TYPE pm2_process_up gauge");

  lines.push("# HELP pm2_process_restarts_total Total number of PM2 process restarts");
  lines.push("# TYPE pm2_process_restarts_total counter");

  lines.push("# HELP pm2_process_memory_bytes Memory used by the process in bytes");
  lines.push("# TYPE pm2_process_memory_bytes gauge");

  lines.push("# HELP pm2_process_cpu_percent CPU usage percentage of the process");
  lines.push("# TYPE pm2_process_cpu_percent gauge");

  for (const proc of processes) {
    const name = proc.name;
    const status = proc.pm2_env?.status === "online" ? 1 : 0;
    const restarts = proc.pm2_env?.restart_time ?? 0;
    const memory = proc.monit?.memory ?? 0;
    const cpu = proc.monit?.cpu ?? 0;

    const label = `process_name="${name}"`;

    lines.push(`pm2_process_up{${label}} ${status}`);
    lines.push(`pm2_process_restarts_total{${label}} ${restarts}`);
    lines.push(`pm2_process_memory_bytes{${label}} ${memory}`);
    lines.push(`pm2_process_cpu_percent{${label}} ${cpu}`);
  }

  return lines.join("\n") + "\n";
}

const server = http.createServer((req, res) => {
  // /health — liveness probe para Docker healthcheck e monitoramento externo
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    return res.end("ok");
  }

  if (req.url !== "/metrics") {
    res.writeHead(404);
    return res.end("Not found");
  }

  getPm2Metrics((err, processes) => {
    if (err) {
      res.writeHead(500, { "Content-Type": "text/plain" });
      return res.end(`# ERROR: ${err.message}\n`);
    }

    const output = formatMetrics(processes);
    res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4; charset=utf-8" });
    res.end(output);
  });
});

server.listen(PORT, () => {
  console.log(`[pm2_exporter] Listening on :${PORT}/metrics`);
});
