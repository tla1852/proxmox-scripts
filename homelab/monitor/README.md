# homelab/monitor — Surveillance interne → alertes L5

Scripts de la zone management (cf. [tla1852/homelab-secu](https://github.com/tla1852/homelab-secu), phase 6). Toute détection POST sur `L5 /webhooks/alerte` → page Supervision + cadre alerting de la home.

## nmap-watch.sh

Découverte LAN + **ndiff** : scanne le sous-réseau (`SUBNET`, défaut `192.168.1.0/24`), compare au baseline précédent. Tout changement (nouvel hôte, nouveau port, disparition) → alerte **warning** dans L5, puis le baseline est mis à jour ; aucun changement → **résolue**. Dédup par `externe_id = nmap:lan-diff:<subnet>`.

> L'exposition **publique** ne se teste pas d'ici (la Bbox ne fait pas de hairpin NAT) → c'est le rôle du **scanner externe GCP** (phase 6, reporté).

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

Variables surchargeables (env ou `monitor.env`) : `SUBNET`, `PORTS`, `L5_URL`, `STATE_DIR`.
