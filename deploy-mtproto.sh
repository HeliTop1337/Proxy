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
REPO_URL="https://github.com/HeliTop1337/Proxy.git"
REPO_DIR="/opt/heliproxy-repo"

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

# ── Colors & UI ──────────────────────────────────────────────────────────────
_R='\033[0;31m' _G='\033[0;32m' _Y='\033[0;33m'
_B='\033[0;34m' _C='\033[0;36m' _W='\033[1;37m'
_DIM='\033[2m'  _BOLD='\033[1m' _RST='\033[0m'

_STEP=0
_TOTAL=12

log()  { printf "${_DIM}[${_C}INFO${_RST}${_DIM}]${_RST} %s\n" "$*"; }
warn() { printf "${_DIM}[${_Y}WARN${_RST}${_DIM}]${_RST} %s\n" "$*"; }
error(){ printf "${_DIM}[${_R}ERR ${_RST}${_DIM}]${_RST} %s\n" "$*" >&2; }

step_start() {
  (( _STEP++ )) || true
  local pct=$(( _STEP * 100 / _TOTAL ))
  local filled=$(( pct * 28 / 100 ))
  local bar=""
  local i=0
  while (( i < filled ));    do bar+="█"; (( i++ )) || true; done
  while (( i < 28 ));        do bar+="░"; (( i++ )) || true; done
  printf "\n${_BOLD}${_B}[%2d/%d]${_RST} ${_W}%s${_RST}\n" "${_STEP}" "${_TOTAL}" "$*"
  printf "       ${_C}%s${_RST} ${_DIM}%3d%%${_RST}\n" "${bar}" "${pct}"
}

spin_run() {
  local label="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  "$@" &
  local pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    printf "\r       ${_C}%s${_RST} ${_DIM}%s...${_RST}  " "${frames[$((i % 10))]}" "${label}"
    (( i++ )) || true
    sleep 0.12
  done
  wait "${pid}"
  local rc=$?
  if (( rc == 0 )); then
    printf "\r       ${_G}✔${_RST} %-40s\n" "${label}"
  else
    printf "\r       ${_R}✘${_RST} %-40s\n" "${label}"
    return "${rc}"
  fi
}

banner() {
  printf "\n"
  printf "${_B}╔══════════════════════════════════════════╗${_RST}\n"
  printf "${_B}║${_RST}  ${_BOLD}${_W}HeliProxy${_RST} ${_C}by Klieer${_RST}  ${_DIM}— MTProto Deploy${_RST}    ${_B}║${_RST}\n"
  printf "${_B}╚══════════════════════════════════════════╝${_RST}\n\n"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "${pkg}" >/dev/null 2>&1; then
    return
  fi
  log "Installing: ${_W}${pkg}${_RST}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null 2>&1 || true
}

ensure_base_tools() {
  step_start "Installing system packages"
  if has_cmd apt-get; then
    spin_run "apt-get update" bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1"
    for pkg in ca-certificates curl git iproute2 procps dnsutils nginx nodejs npm certbot python3-certbot-nginx; do
      apt_install_if_missing "${pkg}"
    done
  else
    warn "apt-get is not available. Ensure curl/ss/getent/nginx are installed."
  fi

  if ! has_cmd curl;   then error "curl is required. Install it and rerun.";   exit 1; fi
  if ! has_cmd ss;     then error "ss is required (iproute2). Install it and rerun."; exit 1; fi
  if ! has_cmd getent; then error "getent is required. Install libc-bin and rerun."; exit 1; fi
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
  step_start "Validating Fake TLS domain"
  log "Checking: ${_W}${MASK_DOMAIN}${_RST}"

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
  if [[ -z "${SERVER_HOST}" ]]; then return; fi

  local dns_ip
  dns_ip="$(timeout 5 getent ahostsv4 "${SERVER_HOST}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"

  if [[ -z "${dns_ip}" ]]; then
    warn "Could not resolve ${SERVER_HOST} from this VPS."
    return
  fi

  if [[ -n "${SERVER_IP}" ]] && [[ "${dns_ip}" != "${SERVER_IP}" ]]; then
    warn "DNS mismatch: ${SERVER_HOST} → ${dns_ip}, expected ${SERVER_IP}."
  else
    log "DNS ${_W}${SERVER_HOST}${_RST} → ${_G}${dns_ip}${_RST}"
  fi
}

apply_network_tuning() {
  step_start "Applying network tuning (BBR + fq)"
  local sysctl_file="/etc/sysctl.d/99-mtproto-tuning.conf"
  cat > "${sysctl_file}" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  if sysctl --system >/dev/null 2>&1; then
    log "Applied: ${_G}fq + BBR${_RST}"
  else
    warn "Could not apply sysctl tuning now. Reboot may be required."
  fi
}

open_firewall_port_if_possible() {
  step_start "Opening firewall port ${PORT}/tcp"
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
  step_start "Installing Docker"
  if has_cmd docker; then
    log "Docker already installed: $(docker --version)"
    return
  fi

  spin_run "Downloading Docker installer" bash -c "curl -fsSL --max-time 60 https://get.docker.com -o /tmp/get-docker.sh"
  spin_run "Installing Docker" bash -c "timeout 300 sh /tmp/get-docker.sh >/dev/null 2>&1"
  systemctl enable docker --now >/dev/null 2>&1 || true
  log "Docker installed."
}

pull_mtg_image() {
  step_start "Pulling MTG image"
  local attempt=1
  while (( attempt <= 3 )); do
    if spin_run "docker pull ${MTG_IMAGE} (attempt ${attempt})" bash -c "timeout 120 docker pull '${MTG_IMAGE}' >/dev/null 2>&1"; then
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
  step_start "Checking port ${PORT} availability"
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
  step_start "Generating MTProto secret"
  if [[ -n "${SECRET}" ]]; then
    log "Using provided secret."
    return
  fi

  log "Fake TLS mask: ${_W}${MASK_DOMAIN}${_RST}"
  SECRET="$(timeout 30 docker run --rm "${MTG_IMAGE}" generate-secret --hex "${MASK_DOMAIN}" | tr -d '\r\n')"

  if [[ -z "${SECRET}" ]]; then
    error "Failed to generate secret."
    exit 1
  fi
  log "Secret generated: ${_DIM}${SECRET:0:16}…${_RST}"
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
  step_start "Starting MTProto container"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    log "Removing existing container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  spin_run "Launching ${CONTAINER_NAME}" bash -c "
    docker run -d \
      --name '${CONTAINER_NAME}' \
      --restart unless-stopped \
      --health-cmd 'pgrep mtg || exit 1' \
      --health-interval 30s \
      --health-retries 3 \
      --health-timeout 5s \
      -p '${PORT}:${PORT}' \
      '${MTG_IMAGE}' \
      simple-run -n '${DNS_RESOLVER}' -i prefer-ipv4 '0.0.0.0:${PORT}' '${SECRET}' >/dev/null
  "

  local attempts=0 status=""
  while (( attempts < 10 )); do
    sleep 2
    status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    [[ "${status}" == "running" ]] && { log "Container ${_G}running${_RST}."; return; }
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

  printf "       ${_G}✔${_RST} Self-check passed — port ${_W}${PORT}${_RST} is listening\n"
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
    server_addr="<YOUR_SERVER_IP_OR_HOST>"
  fi

  tg_link="tg://proxy?server=${server_addr}&port=${PORT}&secret=${SECRET}"
  LAST_TG_LINK="${tg_link}"

  printf "\n"
  printf "${_G}╔══════════════════════════════════════════╗${_RST}\n"
  printf "${_G}║${_RST}  ${_BOLD}${_W}HeliProxy by Klieer${_RST} ${_G}— Proxy is LIVE${_RST}     ${_G}║${_RST}\n"
  printf "${_G}╠══════════════════════════════════════════╣${_RST}\n"
  printf "${_G}║${_RST}  ${_DIM}Container${_RST}  ${_W}%-30s${_RST}  ${_G}║${_RST}\n" "${CONTAINER_NAME}"
  printf "${_G}║${_RST}  ${_DIM}Port     ${_RST}  ${_W}%-30s${_RST}  ${_G}║${_RST}\n" "${PORT}"
  printf "${_G}║${_RST}  ${_DIM}Domain   ${_RST}  ${_W}%-30s${_RST}  ${_G}║${_RST}\n" "${MASK_DOMAIN}"
  printf "${_G}║${_RST}  ${_DIM}Secret   ${_RST}  ${_C}%-30s${_RST}  ${_G}║${_RST}\n" "${SECRET:0:16}…"
  printf "${_G}╠══════════════════════════════════════════╣${_RST}\n"
  printf "${_G}║${_RST}  ${_DIM}Web      ${_RST}  ${_B}https://%-24s${_RST}  ${_G}║${_RST}\n" "${SERVER_HOST}"
  printf "${_G}║${_RST}  ${_DIM}Health   ${_RST}  ${_B}%-30s${_RST}  ${_G}║${_RST}\n" "http://127.0.0.1:3000/health"
  printf "${_G}║${_RST}  ${_DIM}Channel  ${_RST}  ${_B}%-30s${_RST}  ${_G}║${_RST}\n" "https://t.me/helitop1337"
  printf "${_G}╠══════════════════════════════════════════╣${_RST}\n"
  printf "${_G}║${_RST}  ${_Y}Telegram link:${_RST}                          ${_G}║${_RST}\n"
  printf "${_G}║${_RST}  ${_C}%s${_RST}\n" "${tg_link}"
  printf "${_G}╚══════════════════════════════════════════╝${_RST}\n\n"
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

clone_repo() {
  step_start "Syncing repo from GitHub"
  if [[ -d "${REPO_DIR}/.git" ]]; then
    spin_run "git pull HeliTop1337/Proxy" bash -c "git -C '${REPO_DIR}' pull --ff-only >/dev/null 2>&1"
  else
    spin_run "git clone HeliTop1337/Proxy" bash -c "rm -rf '${REPO_DIR}' && git clone --depth 1 '${REPO_URL}' '${REPO_DIR}' >/dev/null 2>&1"
  fi

  if [[ ! -d "${REPO_DIR}" ]]; then
    error "Failed to clone repo."
    exit 1
  fi
  log "Repo ready at ${_W}${REPO_DIR}${_RST}."
}

setup_web_landing() {
  step_start "Deploying landing page"
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
  if [[ "${SETUP_NGINX}" != "1" ]]; then return; fi
  step_start "Configuring Nginx"

  if ! has_cmd nginx; then
    warn "Nginx not found, skipping Nginx setup."
    return
  fi

  local nginx_conf="/etc/nginx/sites-available/heliproxy"
  cp "${REPO_DIR}/nginx.conf" "${nginx_conf}"

  # Patch server_name and root to match current settings
  sed -i "s|server_name .*;|server_name ${SERVER_HOST};|g" "${nginx_conf}"
  sed -i "s|root .*;|root ${WEB_ROOT};|g" "${nginx_conf}"

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
  if [[ "${SETUP_PM2}" != "1" ]]; then return; fi
  step_start "Setting up PM2 watchdog"

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

  # Copy files from cloned repo
  cp "${REPO_DIR}/monitor.js"          "${MONITOR_DIR}/monitor.js"
  cp "${REPO_DIR}/ecosystem.config.js" "${MONITOR_DIR}/ecosystem.config.js"

  # Patch container name into ecosystem config
  sed -i "s|'mtproto-proxy'|'${CONTAINER_NAME}'|g" "${MONITOR_DIR}/ecosystem.config.js"
  sed -i "s|/opt/heliproxy/monitor.js|${MONITOR_DIR}/monitor.js|g" "${MONITOR_DIR}/ecosystem.config.js"

  pm2 delete heliproxy-monitor 2>/dev/null || true
  pm2 start "${MONITOR_DIR}/ecosystem.config.js"
  pm2 save
  pm2 startup systemd -u root --hp /root 2>/dev/null | tail -n 1 | bash 2>/dev/null || true

  log "PM2 monitor started and saved."
}

main() {
  banner
  require_root
  parse_args "$@"
  ensure_base_tools
  install_docker_if_missing
  clone_repo
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
