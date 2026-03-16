#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "[ERROR] Failed at line %s: %s\n" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

# One-shot MTProto (Fake TLS) deploy script.
# Preconfigured for:
#   server-host: vpn.helitop.ru
#   port: 7777
#   server-ip: 185.68.184.144
# Run with no args for fast deploy, override via flags if needed.
#
# One-liner install from GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/HeliTop1337/Proxy/main/deploy-mtproto.sh)

CONTAINER_NAME="mtproto-proxy"
PORT="7777"
DNS_RESOLVER="1.1.1.1"
MASK_DOMAIN="1c.ru"
SECRET=""
MTG_IMAGE="nineseconds/mtg:2"
ENV_FILE=".mtproxy.env"
SERVER_IP="185.68.184.144"
SERVER_HOST="vpn.helitop.ru"
LAST_TG_LINK=""
SETUP_NGINX="${SETUP_NGINX:-1}"
SETUP_PM2="${SETUP_PM2:-1}"
WEB_ROOT="/var/www/heliproxy"
MONITOR_DIR="/opt/heliproxy"

usage() {
  cat <<'EOF'
Usage:
  bash deploy-mtproto.sh [options]

Optional:
  --domain <domain>          Domain for Fake TLS SNI masking (default: 1c.ru)
  --port <port>              Listen port (default: 7777)
  --dns <ip>                 DNS resolver for mtg (default: 1.1.1.1)
  --container <name>         Docker container name (default: mtproto-proxy)
  --secret <hex_secret>      Reuse existing secret instead of generating one
  --server-ip <ip>           IP for tg:// link (default: 185.68.184.144)
  --server-host <host>       Host for tg:// link (default: vpn.helitop.ru)
  --no-nginx                 Skip Nginx setup
  --no-pm2                   Skip PM2/monitor setup
  --help                     Show this help

Example:
  bash deploy-mtproto.sh
  bash deploy-mtproto.sh --domain google.com --port 443
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*"
}

error() {
  printf '[ERROR] %s\n' "$*" >&2
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "${pkg}" >/dev/null 2>&1; then
    return
  fi

  log "Installing missing package: ${pkg}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null 2>&1 || true
}

ensure_base_tools() {
  if has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    apt_install_if_missing ca-certificates
    apt_install_if_missing curl
    apt_install_if_missing iproute2
    apt_install_if_missing procps
    apt_install_if_missing dnsutils
    apt_install_if_missing nginx
    apt_install_if_missing nodejs
    apt_install_if_missing npm
    apt_install_if_missing certbot
    apt_install_if_missing python3-certbot-nginx
  else
    warn "apt-get is not available. Ensure curl/ss/getent/nginx are installed."
  fi

  if ! has_cmd curl; then
    error "curl is required. Install it and rerun."
    exit 1
  fi

  if ! has_cmd ss; then
    error "ss command is required (iproute2 package). Install it and rerun."
    exit 1
  fi

  if ! has_cmd getent; then
    error "getent command is required. Install libc-bin and rerun."
    exit 1
  fi
}

require_value() {
  local key="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]] || [[ "${value}" == --* ]]; then
    error "${key} requires a value"
    usage
    exit 1
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Run as root (sudo -i)."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        require_value "$1" "${2:-}"
        MASK_DOMAIN="${2:-}"
        shift 2
        ;;
      --port)
        require_value "$1" "${2:-}"
        PORT="${2:-}"
        shift 2
        ;;
      --dns)
        require_value "$1" "${2:-}"
        DNS_RESOLVER="${2:-}"
        shift 2
        ;;
      --container)
        require_value "$1" "${2:-}"
        CONTAINER_NAME="${2:-}"
        shift 2
        ;;
      --secret)
        require_value "$1" "${2:-}"
        SECRET="${2:-}"
        shift 2
        ;;
      --server-ip)
        require_value "$1" "${2:-}"
        SERVER_IP="${2:-}"
        shift 2
        ;;
      --server-host)
        require_value "$1" "${2:-}"
        SERVER_HOST="${2:-}"
        shift 2
        ;;
      --no-nginx)
        SETUP_NGINX=0
        shift
        ;;
      --no-pm2)
        SETUP_PM2=0
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    error "Invalid --port value: ${PORT}"
    exit 1
  fi

  if [[ -n "${SECRET}" ]] && ! [[ "${SECRET}" =~ ^[0-9a-fA-F]{32,128}$ ]]; then
    error "Invalid --secret format. Expected hex string."
    exit 1
  fi
}

validate_mask_domain() {
  log "Validating mask domain for Fake TLS: ${MASK_DOMAIN}"

  if ! timeout 5 getent ahostsv4 "${MASK_DOMAIN}" >/dev/null 2>&1; then
    warn "Domain ${MASK_DOMAIN} has no visible IPv4 DNS record from this VPS."
  fi

  if ! curl -fsSIL --max-time 8 "https://${MASK_DOMAIN}" >/dev/null 2>&1; then
    warn "HTTPS check for ${MASK_DOMAIN} failed. Fake TLS may be less reliable."
  else
    log "Domain HTTPS check passed."
  fi
}

validate_server_host_mapping() {
  if [[ -z "${SERVER_HOST}" ]]; then
    return
  fi

  local dns_ip
  dns_ip="$(timeout 5 getent ahostsv4 "${SERVER_HOST}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"

  if [[ -z "${dns_ip}" ]]; then
    warn "Could not resolve ${SERVER_HOST} from this VPS."
    return
  fi

  if [[ -n "${SERVER_IP}" ]] && [[ "${dns_ip}" != "${SERVER_IP}" ]]; then
    warn "DNS A record mismatch: ${SERVER_HOST} -> ${dns_ip}, expected ${SERVER_IP}."
  else
    log "DNS for ${SERVER_HOST} resolves to ${dns_ip}."
  fi
}

apply_network_tuning() {
  local sysctl_file="/etc/sysctl.d/99-mtproto-tuning.conf"

  cat > "${sysctl_file}" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  if sysctl --system >/dev/null 2>&1; then
    log "Applied network tuning (fq + BBR)."
  else
    warn "Could not apply sysctl tuning now. Reboot may be required."
  fi
}

open_firewall_port_if_possible() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
      log "Firewall rule ensured via ufw: ${PORT}/tcp"
      return
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      log "Firewall rule ensured via firewalld: ${PORT}/tcp"
      return
    fi
  fi

  warn "No active ufw/firewalld detected. Ensure provider security group allows TCP ${PORT}."
}

install_docker_if_missing() {
  if has_cmd docker; then
    log "Docker already installed: $(docker --version)"
    return
  fi

  log "Docker not found. Installing..."
  curl -fsSL --max-time 60 https://get.docker.com | timeout 300 sh
  systemctl enable docker --now >/dev/null 2>&1 || true
  log "Docker installed."
}

pull_mtg_image() {
  log "Pulling image ${MTG_IMAGE}"
  local attempt=1
  while (( attempt <= 3 )); do
    if timeout 120 docker pull "${MTG_IMAGE}" >/dev/null 2>&1; then
      log "Image pulled successfully."
      return
    fi
    warn "Pull attempt ${attempt} failed, retrying in 3s..."
    sleep 3
    (( attempt++ ))
  done
  error "Failed to pull ${MTG_IMAGE} after 3 attempts."
  exit 1
}

stop_common_web_services() {
  local busy
  busy="$(ss -tulpn 2>/dev/null | grep -E ":${PORT}\\b" || true)"
  if [[ -z "${busy}" ]]; then
    log "Port ${PORT} is free."
    return
  fi

  warn "Port ${PORT} appears busy:"
  printf '%s\n' "${busy}"

  for svc in nginx apache2 httpd caddy; do
    if systemctl is-active --quiet "${svc}"; then
      warn "Stopping service ${svc} to free port ${PORT}..."
      systemctl stop "${svc}" || true
    fi
  done

  busy="$(ss -tulpn 2>/dev/null | grep -E ":${PORT}\\b" || true)"
  if [[ -n "${busy}" ]]; then
    error "Port ${PORT} is still busy. Free it manually and rerun."
    exit 1
  fi

  log "Port ${PORT} is free now."
}

generate_secret_if_needed() {
  if [[ -n "${SECRET}" ]]; then
    log "Using provided secret."
    return
  fi

  log "Generating Fake TLS secret for domain: ${MASK_DOMAIN}"
  SECRET="$(timeout 30 docker run --rm "${MTG_IMAGE}" generate-secret --hex "${MASK_DOMAIN}" | tr -d '\r\n')"

  if [[ -z "${SECRET}" ]]; then
    error "Failed to generate secret."
    exit 1
  fi

  log "Secret generated."
}

save_env_file() {
  cat > "${ENV_FILE}" <<EOF
CONTAINER_NAME=${CONTAINER_NAME}
PORT=${PORT}
DNS_RESOLVER=${DNS_RESOLVER}
MASK_DOMAIN=${MASK_DOMAIN}
SECRET=${SECRET}
MTG_IMAGE=${MTG_IMAGE}
SERVER_IP=${SERVER_IP}
SERVER_HOST=${SERVER_HOST}
EOF
  chmod 600 "${ENV_FILE}" 2>/dev/null || true
  log "Saved settings to ${ENV_FILE}"
}

start_proxy_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    log "Removing existing container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  log "Starting MTProto container..."
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --health-cmd "pgrep mtg || exit 1" \
    --health-interval 30s \
    --health-retries 3 \
    --health-timeout 5s \
    -p "${PORT}:${PORT}" \
    "${MTG_IMAGE}" \
    simple-run -n "${DNS_RESOLVER}" -i prefer-ipv4 "0.0.0.0:${PORT}" "${SECRET}" >/dev/null

  local attempts=0
  local status=""
  while (( attempts < 10 )); do
    sleep 2
    status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    if [[ "${status}" == "running" ]]; then
      log "Container is running."
      return
    fi
    (( attempts++ ))
  done

  error "Container failed to start (status: ${status}). Logs:"
  docker logs "${CONTAINER_NAME}" 2>&1 || true
  exit 1
}

get_public_ip() {
  local ip=""

  ip="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -fsS --max-time 5 ipinfo.io/ip 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -fsS --max-time 5 api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]] && command -v dig >/dev/null 2>&1; then
    ip="$(timeout 5 dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  printf '%s' "${ip}"
}

post_start_self_check() {
  local listen_count
  listen_count="$(ss -tuln 2>/dev/null | grep -E ":${PORT}\\b" | wc -l | tr -d ' ')"

  if [[ "${listen_count}" == "0" ]]; then
    error "Port ${PORT} is not listening after start."
    docker logs "${CONTAINER_NAME}" --tail 80 2>&1 || true
    exit 1
  fi

  log "Self-check passed: port ${PORT} is listening."
}

print_result() {
  local server_addr tg_link
  if [[ -n "${SERVER_HOST}" ]]; then
    server_addr="${SERVER_HOST}"
  elif [[ -n "${SERVER_IP}" ]]; then
    server_addr="${SERVER_IP}"
  else
    server_addr="$(get_public_ip)"
  fi

  if [[ -z "${server_addr}" ]]; then
    warn "Could not detect public IP automatically."
    warn "Use your VPS public IP in link manually."
    server_addr="<YOUR_SERVER_IP_OR_HOST>"
  fi

  tg_link="tg://proxy?server=${server_addr}&port=${PORT}&secret=${SECRET}"
  LAST_TG_LINK="${tg_link}"

  cat <<EOF

========================================
  HeliProxy by Klieer — MTProto ready.

Container: ${CONTAINER_NAME}
Port:      ${PORT}
Domain:    ${MASK_DOMAIN}
Secret:    ${SECRET}

Telegram link:
${tg_link}

Web:   https://${SERVER_HOST}
Monitor: http://127.0.0.1:3000/health

Sponsor channel:
https://t.me/helitop1337

Quick checks:
  docker ps
  docker logs ${CONTAINER_NAME} --tail 20
  pm2 status
  pm2 logs heliproxy-monitor
========================================
EOF
}

print_next_steps() {
  cat <<EOF

Next steps:
1) Open this link on device with Telegram:
  ${LAST_TG_LINK}
2) Verify DNS from your PC:
  nslookup ${SERVER_HOST}
3) Check container anytime:
  docker ps ; docker logs ${CONTAINER_NAME} --tail 30
4) PM2 status:
  pm2 status ; pm2 logs heliproxy-monitor
5) Nginx status:
  systemctl status nginx
EOF
}

setup_web_landing() {
  mkdir -p "${WEB_ROOT}"
  cat > "${WEB_ROOT}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>HeliProxy by Klieer</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #0a0a0f;
      font-family: 'Segoe UI', system-ui, sans-serif;
      color: #e0e0ff;
    }
    .card {
      text-align: center;
      padding: 3rem 4rem;
      border: 1px solid #2a2a4a;
      border-radius: 16px;
      background: #10101a;
      box-shadow: 0 0 60px rgba(80,80,255,0.08);
    }
    h1 { font-size: 2.4rem; letter-spacing: 0.04em; color: #a0a0ff; }
    .by { font-size: 1rem; margin-top: 0.5rem; color: #5555aa; letter-spacing: 0.12em; text-transform: uppercase; }
    .dot { display: inline-block; width: 8px; height: 8px; background: #44ff88; border-radius: 50%; margin-right: 6px; animation: pulse 2s infinite; }
    .status { margin-top: 2rem; font-size: 0.85rem; color: #666699; }
    @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.3} }
  </style>
</head>
<body>
  <div class="card">
    <h1>HeliProxy</h1>
    <div class="by">by Klieer</div>
    <div class="status"><span class="dot"></span>Proxy is running</div>
  </div>
</body>
</html>
HTMLEOF
  log "Landing page deployed to ${WEB_ROOT}."
}

setup_nginx() {
  if [[ "${SETUP_NGINX}" != "1" ]]; then
    return
  fi

  if ! has_cmd nginx; then
    warn "Nginx not found, skipping Nginx setup."
    return
  fi

  local nginx_conf="/etc/nginx/sites-available/heliproxy"

  cat > "${nginx_conf}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_HOST};

    root ${WEB_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /health {
        proxy_pass         http://127.0.0.1:3000/health;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_connect_timeout 3s;
        proxy_read_timeout    5s;
    }

    location /status {
        stub_status on;
        access_log  off;
        allow       127.0.0.1;
        deny        all;
    }
}
EOF

  ln -sf "${nginx_conf}" /etc/nginx/sites-enabled/heliproxy
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t 2>&1 && systemctl reload nginx && log "Nginx configured and reloaded."

  if has_cmd certbot && [[ -n "${SERVER_HOST}" ]]; then
    log "Attempting SSL certificate via certbot..."
    certbot --nginx -d "${SERVER_HOST}" --non-interactive --agree-tos \
      --email "admin@${SERVER_HOST}" --redirect >/dev/null 2>&1 \
      && log "SSL certificate issued." \
      || warn "Certbot failed — run manually: certbot --nginx -d ${SERVER_HOST}"
  fi
}

setup_monitor() {
  if [[ "${SETUP_PM2}" != "1" ]]; then
    return
  fi

  if ! has_cmd npm; then
    warn "npm not found, skipping PM2/monitor setup."
    return
  fi

  npm install -g pm2 --silent >/dev/null 2>&1 || true

  if ! has_cmd pm2; then
    warn "pm2 install failed, skipping monitor setup."
    return
  fi

  mkdir -p "${MONITOR_DIR}"

  cat > "${MONITOR_DIR}/monitor.js" <<JSEOF
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
      \`docker inspect -f '{{.State.Running}}' \${CONTAINER}\`,
      { timeout: 8000, encoding: 'utf8' }
    ).trim();
    return out === 'true';
  } catch (_) {
    return false;
  }
}

function restartContainer() {
  try {
    execSync(\`docker start \${CONTAINER}\`, { timeout: 15000 });
    console.log(\`[\${new Date().toISOString()}] [RECOVER] Container \${CONTAINER} restarted.\`);
  } catch (err) {
    console.error(\`[\${new Date().toISOString()}] [ERROR] Failed to restart container: \${err.message}\`);
  }
}

function containerUptime() {
  try {
    return execSync(
      \`docker inspect -f '{{.State.StartedAt}}' \${CONTAINER}\`,
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
    console.warn(\`[\${lastCheck.time}] [WARN] Container \${CONTAINER} is down — restarting...\`);
    restartContainer();
  } else {
    console.log(\`[\${lastCheck.time}] [OK] Container \${CONTAINER} is running.\`);
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
  console.log(\`[INFO] Health monitor listening on 127.0.0.1:\${PORT}\`);
});

runCheck();
setInterval(runCheck, INTERVAL);
JSEOF

  cat > "${MONITOR_DIR}/ecosystem.config.js" <<ECOEOF
'use strict';

module.exports = {
  apps: [
    {
      name:             'heliproxy-monitor',
      script:           '${MONITOR_DIR}/monitor.js',
      instances:        1,
      autorestart:      true,
      watch:            false,
      max_restarts:     20,
      restart_delay:    5000,
      exp_backoff_restart_delay: 100,
      max_memory_restart: '128M',
      env: {
        NODE_ENV:          'production',
        CONTAINER_NAME:    '${CONTAINER_NAME}',
        MONITOR_PORT:      '3000',
        CHECK_INTERVAL_MS: '30000',
      },
      error_file:  '/var/log/heliproxy-monitor-err.log',
      out_file:    '/var/log/heliproxy-monitor-out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
    },
  ],
};
ECOEOF

  pm2 delete heliproxy-monitor 2>/dev/null || true
  pm2 start "${MONITOR_DIR}/ecosystem.config.js"
  pm2 save
  pm2 startup systemd -u root --hp /root 2>/dev/null | tail -n 1 | bash 2>/dev/null || true

  log "PM2 monitor started and saved."
}

main() {
  require_root
  parse_args "$@"
  ensure_base_tools
  install_docker_if_missing
  pull_mtg_image
  validate_mask_domain
  validate_server_host_mapping
  apply_network_tuning
  open_firewall_port_if_possible
  stop_common_web_services
  generate_secret_if_needed
  save_env_file
  start_proxy_container
  post_start_self_check
  setup_web_landing
  setup_nginx
  setup_monitor
  print_result
  print_next_steps
}

main "$@"
