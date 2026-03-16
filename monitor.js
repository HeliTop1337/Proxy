'use strict';
const http = require('http');
const { execSync } = require('child_process');

const CONTAINER = process.env.CONTAINER_NAME || 'mtproto-proxy';
const PORT      = parseInt(process.env.MONITOR_PORT || '3000', 10);
const INTERVAL  = parseInt(process.env.CHECK_INTERVAL_MS || '30000', 10);

let lastCheck = { time: null, status: 'unknown', uptime: null };

function isContainerRunning() {
  try {
    const out = execSync(
      `docker inspect -f '{{.State.Running}}' ${CONTAINER}`,
      { timeout: 8000, encoding: 'utf8' }
    ).trim();
    return out === 'true';
  } catch (_) {
    return false;
  }
}

function restartContainer() {
  try {
    execSync(`docker start ${CONTAINER}`, { timeout: 15000 });
    console.log(`[${new Date().toISOString()}] [RECOVER] Container ${CONTAINER} restarted.`);
  } catch (err) {
    console.error(`[${new Date().toISOString()}] [ERROR] Failed to restart container: ${err.message}`);
  }
}

function containerUptime() {
  try {
    return execSync(
      `docker inspect -f '{{.State.StartedAt}}' ${CONTAINER}`,
      { timeout: 5000, encoding: 'utf8' }
    ).trim();
  } catch (_) {
    return null;
  }
}

function runCheck() {
  const running = isContainerRunning();
  lastCheck = {
    time:   new Date().toISOString(),
    status: running ? 'running' : 'down',
    uptime: running ? containerUptime() : null,
  };

  if (!running) {
    console.warn(`[${lastCheck.time}] [WARN] Container ${CONTAINER} is down — restarting...`);
    restartContainer();
  } else {
    console.log(`[${lastCheck.time}] [OK] Container ${CONTAINER} is running.`);
  }
}

const server = http.createServer((req, res) => {
  if (req.url === '/health' || req.url === '/') {
    const ok = lastCheck.status === 'running';
    res.writeHead(ok ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ...lastCheck, container: CONTAINER }));
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[INFO] Health monitor listening on 127.0.0.1:${PORT}`);
});

runCheck();
setInterval(runCheck, INTERVAL);
