# HeliProxy by Klieer — MTProto One-Script Deploy

Fast deploy for MTProto Proxy with Fake TLS (Docker + mtg) + Nginx + PM2 watchdog.

Preconfigured for your server:

- Host: vpn.helitop.ru
- IP: 185.68.184.144
- Port: 7777
- Default Fake TLS mask-domain: 1c.ru

## 1) Run on VPS (Ubuntu/Debian)

```bash
chmod +x deploy-mtproto.sh
sudo ./deploy-mtproto.sh
```

Script will:
- Install Docker, Nginx, Node.js, PM2 (if missing)
- Validate mask domain, enable BBR, open firewall port
- Start MTProto proxy container (with Docker health check + auto-restart)
- Deploy landing page `HeliProxy by Klieer` at `https://vpn.helitop.ru`
- Attempt SSL cert via certbot
- Start PM2 health monitor that auto-restarts Docker container if it goes down
- Print Telegram link

## 2) Optional flags

```bash
sudo ./deploy-mtproto.sh --domain 1c.ru --port 7777 --dns 1.1.1.1
sudo ./deploy-mtproto.sh --no-nginx     # skip Nginx setup
sudo ./deploy-mtproto.sh --no-pm2      # skip PM2/monitor setup
```

## 3) Reuse your own secret

```bash
sudo ./deploy-mtproto.sh --secret YOUR_HEX_SECRET
```

## 4) Useful checks

```bash
docker ps
docker logs mtproto-proxy --tail 30
pm2 status
pm2 logs heliproxy-monitor
systemctl status nginx
curl http://127.0.0.1:3000/health
```

## 5) Files

| File | Purpose |
|---|---|
| `deploy-mtproto.sh` | Full deploy script |
| `nginx.conf` | Nginx site config (reference) |
| `ecosystem.config.js` | PM2 app config |
| `monitor.js` | Docker watchdog + `/health` endpoint |

Sponsor channel: https://t.me/helitop1337

