# homelab/monitor — Surveillance interne → alertes L5

Scripts de la zone management (cf. [tla1852/homelab-secu](https://github.com/tla1852/homelab-secu), phase 6). Toute détection POST sur `L5 /webhooks/alerte` → page Supervision + cadre alerting de la home.

## nmap-watch.sh

Surveille l'exposition réseau (par défaut l'IP publique via le DDNS). Tout port ouvert hors `EXPECTED` (défaut `443`) → alerte **critique** dans L5 ; conforme → **résolue**. Dédup par `externe_id = nmap:exposure:<cible>`.

### Déploiement (sur un LXC management, ex. l5/superoutil — PAS la DMZ)

```bash
apt-get update -qq && apt-get install -y -qq nmap
mkdir -p /opt/monitor
curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/monitor/nmap-watch.sh -o /opt/monitor/nmap-watch.sh
chmod +x /opt/monitor/nmap-watch.sh

# secret webhook supervision (depuis le .env de L5, ou recopié)
echo "SUPERVISION_WEBHOOK_SECRET=$(grep -h '^SUPERVISION_WEBHOOK_SECRET=' /opt/l5/.env | cut -d= -f2)" > /opt/monitor/monitor.env
chmod 600 /opt/monitor/monitor.env

# test manuel
/opt/monitor/nmap-watch.sh

# cron horaire
( crontab -l 2>/dev/null; echo "7 * * * * /opt/monitor/nmap-watch.sh >> /var/log/nmap-watch.log 2>&1" ) | crontab -
```

Variables surchargeables (env ou `monitor.env`) : `TARGET`, `EXPECTED`, `PORTS`, `L5_URL`.
