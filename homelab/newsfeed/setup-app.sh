#!/usr/bin/env bash
#
# setup-app.sh — couche applicative newsfeed (agrégateur de veille tech &
# science), appliquée à un CT existant (créé par create-lxc-newsfeed.sh, qui
# appelle ce script). Relançable tel quel si le run précédent a échoué :
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/newsfeed/setup-app.sh) <VMID>
#
# - Node 22 (NodeSource) dans le CT
# - clone de tla1852/newsfeed (repo privé : PAT GitHub demandé, mémorisé dans
#   le credential store git de l'utilisateur thibault pour les mises à jour)
# - npm install + build, service systemd newsfeed (port 3000)
#
# Après coup : entrée Caddy interne veille.ts.tlagrange.pro → <ip-ct>:3000
# (tailnet only, cf. homelab-secu).

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-app.sh <VMID> (CT créé par create-lxc-newsfeed.sh)"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté (pct status ${VMID})."
pct exec "$VMID" -- id thibault >/dev/null 2>&1 || err "Utilisateur thibault absent dans le CT ${VMID} : socle incomplet."

REPO="tla1852/newsfeed"
APP_DIR="/home/thibault/newsfeed"
APP_PORT="3000"

info "Configuration de newsfeed (CT ${VMID})..."

read -rsp "PAT GitHub (accès lecture au repo privé ${REPO}) : " GH_PAT; echo
[[ -n "$GH_PAT" ]] || err "PAT requis pour cloner ${REPO} (repo privé)."

# ----- Node 22 (NodeSource) -----
if pct exec "$VMID" -- bash -c "command -v node && node -v | grep -q '^v22'" >/dev/null 2>&1; then
    info "Node 22 déjà présent."
else
    info "Installation de Node 22 (NodeSource)..."
    pct exec "$VMID" -- bash -c "export DEBIAN_FRONTEND=noninteractive
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
        apt-get -y -qq install nodejs"
fi
info "Node : $(pct exec "$VMID" -- node -v)"

# ----- Clone / mise à jour du repo (en thibault, PAT dans le credential store) -----
info "Clone de ${REPO}..."
pct exec "$VMID" -- su - thibault -c "
    set -euo pipefail
    git config --global credential.helper store
    printf 'https://tla1852:%s@github.com\n' '${GH_PAT}' > ~/.git-credentials
    chmod 600 ~/.git-credentials
    if [[ -d '${APP_DIR}/.git' ]]; then
        git -C '${APP_DIR}' pull --ff-only
    else
        git clone 'https://github.com/${REPO}.git' '${APP_DIR}'
    fi
"
unset GH_PAT

# ----- Build -----
info "npm install + build..."
pct exec "$VMID" -- su - thibault -c "cd '${APP_DIR}' && npm install --no-audit --no-fund && npm run build"

# ----- Service systemd -----
info "Installation du service systemd..."
pct exec "$VMID" -- bash -c "cp '${APP_DIR}/deploy/newsfeed.service' /etc/systemd/system/newsfeed.service
    systemctl daemon-reload
    systemctl enable newsfeed
    systemctl restart newsfeed"

# ----- Vérification -----
sleep 3
if pct exec "$VMID" -- curl -fsS -m5 "http://localhost:${APP_PORT}/healthz" | grep -q '"ok":true'; then
    CT_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
    echo
    info "newsfeed opérationnel !"
    info "  Pages   : http://${CT_IP}:${APP_PORT}/tech  et  /science  (/sources pour gérer)"
    info "  Suite   : entrée Caddy interne  veille.ts.tlagrange.pro → ${CT_IP}:${APP_PORT}"
    info "  Service : pct exec ${VMID} -- systemctl status newsfeed"
else
    err "Le service ne répond pas sur /healthz : pct exec ${VMID} -- journalctl -u newsfeed -n 30"
fi
