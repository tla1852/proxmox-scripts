#!/usr/bin/env bash
#
# install.sh — installe le poller calendrier (CalDAV Proton -> L5) DANS le LXC proton-caldav.
#
# À lancer EN ROOT dans le container ferroxide (pas sur l'hôte Proxmox), après
# `ferroxide auth` + service ferroxide-caldav démarré (CalDAV up sur 127.0.0.1:8081).
#
# Usage :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/cal-poller/install.sh)

set -euo pipefail

APP="/opt/cal-poller"
RAW="https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/cal-poller"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "À lancer en root DANS le LXC proton-caldav."
command -v pct >/dev/null 2>&1 && err "On dirait l'hôte Proxmox : ce script tourne DANS le container ferroxide."

info "Dépendances (python venv + curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-venv curl

info "Récupération du poller..."
mkdir -p "$APP"
curl -fsSL "$RAW/poller.py" -o "$APP/poller.py"

info "Environnement virtuel + dépendances Python..."
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" -q install --upgrade pip
"$APP/venv/bin/pip" -q install caldav icalendar requests

# ----- Secrets / config -----
echo
read -rp "Adresse Proton (= user CalDAV) : " CU
[[ -n "$CU" ]] || err "Adresse Proton requise."
read -rsp "Bridge password ferroxide (sortie de 'ferroxide auth') : " CP; echo
[[ -n "$CP" ]] || err "Bridge password requis."
read -rp "URL webhook L5 [http://192.168.1.43:3000/webhooks/calendrier] : " LU
LU="${LU:-http://192.168.1.43:3000/webhooks/calendrier}"
read -rsp "N8N_WEBHOOK_SECRET (dans /opt/l5/.env du LXC L5) : " NS; echo
[[ -n "$NS" ]] || err "N8N_WEBHOOK_SECRET requis."

cat > /etc/cal-poller.env <<EOF
CALDAV_URL=http://127.0.0.1:8081/
CALDAV_USER=${CU}
CALDAV_PASS=${CP}
L5_WEBHOOK_URL=${LU}
N8N_WEBHOOK_SECRET=${NS}
WINDOW_PAST_DAYS=7
WINDOW_FUTURE_DAYS=90
EOF
chmod 600 /etc/cal-poller.env
unset CP NS

# ----- Service + timer (sync 3 min) -----
info "Service + timer systemd (sync 3 min)..."
cat > /etc/systemd/system/cal-poller.service <<EOF
[Unit]
Description=Poller calendrier Proton (CalDAV) -> L5
After=network-online.target ferroxide-caldav.service
Wants=ferroxide-caldav.service

[Service]
Type=oneshot
EnvironmentFile=/etc/cal-poller.env
ExecStart=${APP}/venv/bin/python ${APP}/poller.py
EOF

cat > /etc/systemd/system/cal-poller.timer <<EOF
[Unit]
Description=Sync calendrier Proton -> L5 toutes les 3 min

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# ----- Test immédiat -----
info "Test de synchro (one-shot)..."
set +e
systemctl start cal-poller.service
journalctl -u cal-poller.service -n 15 --no-pager
set -e

systemctl enable --now cal-poller.timer
echo
info "Terminé. Timer actif :"
systemctl list-timers cal-poller.timer --no-pager || true
echo
info "Logs en continu :  journalctl -u cal-poller.service -f"
info "Modifier la config : /etc/cal-poller.env  (puis : systemctl start cal-poller.service)"
